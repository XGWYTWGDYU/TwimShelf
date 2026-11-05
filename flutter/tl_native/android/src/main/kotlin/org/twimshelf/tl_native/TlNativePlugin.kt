package org.twimshelf.tl_native

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** `tl/native`: what Dart would do slowly. */
class TlNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: android.content.Context? = null
    /** Poster frames decode a few at a time (hardware decoders are few). */
    private val posters = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "tl/native").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "posterFrame" -> {
                val path = call.argument<String>("path")
                val out = call.argument<String>("out")
                val sides = call.argument<List<Int>>("sides")
                val at = call.argument<Int>("atMs") ?: 500
                if (path == null || out == null || sides.isNullOrEmpty()) return result.error("arguments", null, null)
                posters.execute {
                    val whole = call.argument<Boolean>("whole") == true
                    val ok = try { if (whole) wholeFrame(path, at, sides[0], out) else posterFrame(path, at, sides, out) } catch (_: Exception) { false }
                    main.post { result.success(ok) }
                }
            }
            // the app itself (存储空间): the APK and its splits, and the native libraries unpacked
            "appPaths" -> {
                val info = context?.applicationInfo ?: return result.success(emptyList<String>())
                result.success(listOfNotNull(info.sourceDir) + (info.splitSourceDirs?.toList() ?: emptyList()) + listOfNotNull(info.nativeLibraryDir))
            }
            // 检查更新: the downloaded APK (in cache/updates) to the system's installer; false when
            // this app may not install packages yet (the person allows it in the settings shown)
            "installApk" -> {
                val ctx = context ?: return result.success(false)
                val path = call.argument<String>("path") ?: return result.error("arguments", null, null)
                val file = File(path)
                if (file.parentFile?.canonicalPath != File(ctx.cacheDir, "updates").canonicalPath) return result.error("arguments", null, null)
                if (android.os.Build.VERSION.SDK_INT >= 26 && !ctx.packageManager.canRequestPackageInstalls()) {
                    ctx.startActivity(android.content.Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:" + ctx.packageName))
                        .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    return result.success(false)
                }
                val uri = androidx.core.content.FileProvider.getUriForFile(ctx, ctx.packageName + ".tlnative.updates", file)
                ctx.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(true)
            }
            "updatesDir" -> result.success(context?.let { File(it.cacheDir, "updates").also { d -> d.mkdirs() }.path })
            else -> result.notImplemented()
        }
    }

    /** One frame in the video's own shape (a card of 浏览 shows it until the video plays). */
    private fun wholeFrame(path: String, atMs: Int, longSide: Int, out: String): Boolean {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val length = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
            val at = if (length > 0) minOf(atMs.toLong(), length / 2) else 0
            val frame = retriever.getScaledFrameAtTime(at * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, longSide, longSide)
                ?: return false
            val target = File(out.replace("{side}", longSide.toString()))
            target.parentFile?.mkdirs()
            val partial = File(target.path + ".partial")
            partial.outputStream().use { frame.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            frame.recycle()
            if (!partial.renameTo(target)) { partial.delete(); return false }
            return true
        } finally {
            retriever.release()
        }
    }

    /** One frame decoded once by the platform decoder, cropped square, one JPEG per size. */
    private fun posterFrame(path: String, atMs: Int, sides: List<Int>, out: String): Boolean {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val length = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
            val at = if (length > 0) minOf(atMs.toLong(), length / 2) else 0
            val largest = sides.max()
            // the platform scales while decoding: ask for a frame whose short side covers the poster
            val frame = retriever.getScaledFrameAtTime(at * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, largest * 4, largest * 4)
                ?: retriever.getFrameAtTime(at * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return false
            val short = minOf(frame.width, frame.height)
            if (short <= 0) return false
            val crop = Rect((frame.width - short) / 2, (frame.height - short) / 2, (frame.width + short) / 2, (frame.height + short) / 2)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            for (side in sides) {
                val poster = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
                Canvas(poster).apply { drawColor(Color.WHITE); drawBitmap(frame, crop, Rect(0, 0, side, side), paint) }
                val target = File(out.replace("{side}", side.toString()))
                target.parentFile?.mkdirs()
                val partial = File(target.path + ".partial")
                partial.outputStream().use { poster.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                poster.recycle()
                if (!partial.renameTo(target)) { partial.delete(); return false }
            }
            frame.recycle()
            return true
        } finally {
            retriever.release()
        }
    }
}
