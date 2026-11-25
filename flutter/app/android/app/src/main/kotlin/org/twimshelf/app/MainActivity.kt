package org.twimshelf.app

import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.roundToInt

// a FragmentActivity: Android's biometric prompt (the app lock) needs one
class MainActivity : FlutterFragmentActivity() {
    private var pipChannel: MethodChannel? = null

    // The foreground download owner outlives the Activity. Reattach the same
    // engine on return, rather than opening a second process-wide core/library.
    // Made here, not by the framework: one it makes itself it destroys with the Activity, whatever
    // shouldDestroyEngineWithHost says, and the cache would then hand back a dead engine.
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineCache.getInstance().get("twimshelf.main")
            ?: FlutterEngine(context.applicationContext).also { FlutterEngineCache.getInstance().put("twimshelf.main", it) }
    override fun shouldDestroyEngineWithHost(): Boolean = false
    // The app lock: the library stays out of the picture the system keeps for its recent apps.
    override fun onPause() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val locks = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getBoolean("flutter.appLock.enabled", false)
            setRecentsScreenshotEnabled(!locks)
        }
        super.onPause()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    private fun isPipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enterPip(width: Int, height: Int): Boolean {
        if (!isPipSupported()) return false
        return try {
            val rawRatio = if (width > 0 && height > 0) width.toDouble() / height.toDouble() else 16.0 / 9.0
            // Android requires PiP aspect ratio within [1 / 2.39, 2.39].
            val clamped = rawRatio.coerceIn(0.42, 2.38)
            val rational = Rational((clamped * 1000.0).roundToInt(), 1000)
            val builder = PictureInPictureParams.Builder().setAspectRatio(rational)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setSeamlessResizeEnabled(true)
            }
            enterPictureInPictureMode(builder.build())
        } catch (_: Exception) {
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("twimshelf.main", flutterEngine)
        if (!flutterEngine.plugins.has(AndroidPlatformPlugin::class.java)) {
            flutterEngine.plugins.add(AndroidPlatformPlugin())
        }
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.twimshelf/pip").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPipSupported())
                    "enter" -> {
                        val w = (call.argument<Number>("width"))?.toInt() ?: 16
                        val h = (call.argument<Number>("height"))?.toInt() ?: 9
                        result.success(enterPip(w, h))
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.twimshelf/share_inbox")
            .setMethodCallHandler { call, result ->
                if (call.method == "getSharesRoot") {
                    result.success(File(filesDir, if (BuildConfig.DEBUG) "Shares-Debug" else "Shares").absolutePath)
                } else if (call.method == "copyFile") {
                    val file = File(call.arguments as String)
                    val uri = FileProvider.getUriForFile(this, "$packageName.tlfiles", file)
                    val clip = ClipData.newUri(contentResolver, file.name, uri)
                    (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                    result.success(null)
                } else result.notImplemented()
            }
    }
}

/// 拷贝 in the viewers: its own class, as a plugin declares the plain FileProvider too.
class TlFileProvider : FileProvider()
