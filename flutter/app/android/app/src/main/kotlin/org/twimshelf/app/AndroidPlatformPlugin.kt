package org.twimshelf.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class AndroidPlatformPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var permissionResult: MethodChannel.Result? = null
    private var multicast: WifiManager.MulticastLock? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.twimshelf/android_platform").also {
            it.setMethodCallHandler(::handle)
            AndroidBackgroundBridge.channel = it
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        releaseMulticast()
        context.stopService(Intent(context, DownloadForegroundService::class.java))
        DownloadForegroundService.started?.invoke(false); DownloadForegroundService.started = null
        permissionResult?.success(false); permissionResult = null
        channel?.setMethodCallHandler(null)
        if (AndroidBackgroundBridge.channel === channel) AndroidBackgroundBridge.channel = null
        channel = null
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "multicastAcquire" -> {
                    if (multicast?.isHeld != true) {
                        val manager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicast = manager.createMulticastLock("twimshelf:mdns").also {
                            it.setReferenceCounted(false); it.acquire()
                        }
                    }
                    result.success(null)
                }
                "multicastRelease" -> { releaseMulticast(); result.success(null) }
                "notificationPermission" -> requestPermission(result)
                "backgroundStart" -> {
                    val data = call.arguments as? Map<*, *> ?: error("android.arguments")
                    val intent = notificationIntent(data)
                    if (DownloadForegroundService.stopping) error("android.stopping")
                    if (DownloadForegroundService.active) {
                        DownloadForegroundService.update(data); result.success(null)
                    } else {
                        if (DownloadForegroundService.started != null) error("android.busy")
                        DownloadForegroundService.started = { ok ->
                            if (ok) result.success(null) else result.error("android.foregroundUnavailable", null, null)
                        }
                        try { context.startForegroundService(intent) }
                        catch (error: Exception) { DownloadForegroundService.started = null; throw error }
                    }
                }
                "backgroundUpdate" -> {
                    val data = call.arguments as? Map<*, *> ?: error("android.arguments")
                    // Updating an already-running service doesn't create a new
                    // background-start exemption or restart one after a timeout.
                    DownloadForegroundService.update(data)
                    result.success(null)
                }
                "backgroundStop" -> {
                    DownloadForegroundService.requestStop(context) { result.success(null) }
                }
                "platformStatus" -> result.success(mapOf(
                    "multicast" to (multicast?.isHeld == true),
                    "foreground" to DownloadForegroundService.active,
                    "notifications" to notificationsGranted()
                ))
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("android.platformUnavailable", null, null) }
    }
    private fun notificationIntent(data: Map<*, *>): Intent {
        val title = data["title"] as? String ?: error("android.arguments")
        val body = data["body"] as? String ?: error("android.arguments")
        val name = data["channelName"] as? String ?: error("android.arguments")
        return Intent(context, DownloadForegroundService::class.java)
            .putExtra("title", title).putExtra("body", body).putExtra("channelName", name)
            .putExtra("total", (data["total"] as? Number)?.toInt() ?: 0)
            .putExtra("done", (data["done"] as? Number)?.toInt() ?: 0)
    }
    private fun notificationsGranted(): Boolean = Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    private fun requestPermission(result: MethodChannel.Result) {
        if (notificationsGranted()) { result.success(true); return }
        val activity: Activity = binding?.activity ?: run { result.success(false); return }
        if (permissionResult != null) { result.success(false); return }
        permissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionResult?.success(notificationsGranted()); permissionResult = null
        return true
    }
    private fun releaseMulticast() {
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding; binding.addRequestPermissionsResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeRequestPermissionsResultListener(this); binding = null
    }
    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        permissionResult?.success(false); permissionResult = null
    }
    companion object { private const val PERMISSION_REQUEST = 8712 }
}

object AndroidBackgroundBridge {
    var channel: MethodChannel? = null
}
