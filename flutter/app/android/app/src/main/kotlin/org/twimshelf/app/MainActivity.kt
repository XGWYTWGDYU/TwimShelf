package org.twimshelf.app

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.ClipData
import android.content.ClipboardManager
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

// a FragmentActivity: Android's biometric prompt (the app lock) needs one
class MainActivity : FlutterFragmentActivity() {
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("twimshelf.main", flutterEngine)
        if (!flutterEngine.plugins.has(AndroidPlatformPlugin::class.java)) {
            flutterEngine.plugins.add(AndroidPlatformPlugin())
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
