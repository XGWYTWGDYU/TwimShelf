package org.twimshelf.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** A bounded-memory copy only. URI grants are used while this activity lives. */
class ShareActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        worker.execute {
            val id = runCatching { collect(intent) }.getOrNull()
            runOnUiThread {
                if (id == null) {
                    val message = runCatching { catalog("share.nothing") }.getOrNull()
                    if (!message.isNullOrBlank()) Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
                }
                // The share page stays over the app that shared, in its task: no NEW_TASK. What
                // was copied stays .partial until the page publishes it.
                if (id != null) startActivity(Intent(this, ShareSheetActivity::class.java)
                    .putExtra(ShareSheetActivity.EXTRA_ID, id)
                    .putExtra(ShareSheetActivity.EXTRA_ROOT, sharesRoot().path))
                finish()
            }
        }
    }

    private fun sharesRoot() = File(filesDir, if (BuildConfig.DEBUG) "Shares-Debug" else "Shares")

    /** The id of the batch, copied into `Inbox/<id>.partial`; null: nothing to offer. */
    @Suppress("DEPRECATION")
    private fun collect(source: Intent): String? {
        if (source.action != Intent.ACTION_SEND && source.action != Intent.ACTION_SEND_MULTIPLE) return null
        val type = source.type ?: return null
        if (type != "text/plain" && !type.startsWith("image/") && !type.startsWith("video/")) return null
        val inbox = File(sharesRoot(), "Inbox").apply { check(mkdirs() || isDirectory) }
        val id = "share-${System.currentTimeMillis()}-${UUID.randomUUID()}"
        val partial = File(inbox, "$id.partial").apply { check(mkdir()) }
        var offered = false
        try {
            val text = buildString {
                append(source.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty())
                source.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) {
                        clip.getItemAt(i).text?.let { append('\n'); append(it) }
                    }
                }
            }
            val links = postLinks(text)
            val uris = linkedSetOf<Uri>()
            // Chrome adds preview-image URIs to text shares. They are not shared
            // gallery attachments; only media MIME intents may copy streams.
            if (type != "text/plain") {
                if (source.action == Intent.ACTION_SEND_MULTIPLE) {
                    source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                } else {
                    source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
                }
                source.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
                }
            }
            var files = 0
            for (uri in uris) {
                if (uri.scheme != "content") continue
                val mime = contentResolver.getType(uri) ?: continue
                if (!mime.startsWith("image/") && !mime.startsWith("video/")) continue
                var name = ""
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0).orEmpty()
                }
                name = name.replace(Regex("[\\\\/:\\p{Cntrl}]"), "_").trim('.').take(120)
                if (name.isBlank()) name = "media"
                val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                if (!extension.isNullOrBlank() && !name.contains('.')) name += ".$extension"
                val destination = File(partial, "%04d-%s".format(files, name))
                contentResolver.openInputStream(uri).use { input ->
                    checkNotNull(input)
                    destination.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                }
                files++
            }
            if (links.isNotEmpty()) File(partial, "_links.json").writeText(JSONArray(links).toString())
            if (files == 0 && links.isEmpty()) return null
            offered = true
            return id
        } finally {
            if (!offered && partial.exists()) partial.deleteRecursively()
        }
    }

    private fun catalog(key: String): String {
        val locale = resources.configuration.locales[0]
        val tag = when (locale.language) {
            "ja" -> "ja"
            // the script is the language; only a locale without one needs the region
            "zh" -> if (locale.script.isEmpty()) {
                if (locale.country in setOf("TW", "HK", "MO")) "zh-Hant" else "zh-Hans"
            } else if (locale.script == "Hant") "zh-Hant" else "zh-Hans"
            else -> "en"
        }
        return assets.open("flutter_assets/assets/l10n/$tag.json").bufferedReader().use {
            JSONObject(it.readText()).getString(key)
        }
    }

    override fun onDestroy() { worker.shutdown(); super.onDestroy() }

    companion object {
        private val candidates = Regex("(?i)(?<![a-z0-9_.@/])(?:https?://)?(?:(?:www|mobile|m)\\.)?(?:twitter\\.com|x\\.com|fxtwitter\\.com|fixupx\\.com|vxtwitter\\.com|fixvx\\.com)/[^\\s<>()]+")
        private val hosts = setOf("twitter.com", "x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com")
        fun postLinks(text: String): List<String> = candidates.findAll(text).mapNotNull { match ->
            val value = match.value
            val uri = Uri.parse(if (value.contains("://")) value else "https://$value")
            val host = uri.host?.lowercase()?.removePrefix("www.")?.removePrefix("mobile.")?.removePrefix("m.")
            if (host !in hosts || uri.userInfo != null || uri.port != -1) return@mapNotNull null
            val segments = uri.pathSegments
            val pair = when {
                segments.size >= 4 && segments.take(3) == listOf("i", "web", "status") -> "i" to segments[3]
                segments.size >= 3 && segments[0] == "i" && segments[1] == "status" -> "i" to segments[2]
                segments.size >= 3 && segments[1].lowercase() in setOf("status", "statuses") -> segments[0] to segments[2]
                else -> return@mapNotNull null
            }
            val id = pair.second.takeWhile { it in '0'..'9' }
            if (!pair.first.matches(Regex("[A-Za-z0-9_]+")) || id.isEmpty() || id.length > 20) null
            else "https://x.com/${pair.first}/status/$id"
        }.distinct().toList()
    }
}
