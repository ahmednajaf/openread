package dev.openread.mobile

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

data class VoiceAsset(val name: String, val url: String, val sha256: String)
class ModelStore(private val context: Context) {
    val root = File(context.noBackupFilesDir, "voices").apply { mkdirs() }
    private val manifest = JSONObject(context.assets.open("models.json").bufferedReader().use { it.readText() })
    val voiceAssets = manifest.getJSONArray("assets").let { array -> List(array.length()) { array.getJSONObject(it).let { VoiceAsset(it.getString("name"), it.getString("url"), it.getString("sha256")) } } }
    val ocrAssets = (manifest.optJSONArray("ocrAssets") ?: org.json.JSONArray()).let { array -> List(array.length()) { array.getJSONObject(it).let { VoiceAsset(it.getString("name"), it.getString("url"), it.getString("sha256")) } } }
    fun installed(ocr: Boolean = false): Boolean = (if (ocr) ocrAssets else voiceAssets).let { it.isNotEmpty() && it.all { asset -> File(root, asset.name).exists() } }
    suspend fun prepare(ocr: Boolean = false, download: Boolean = false, progress: (Float) -> Unit = {}) = withContext(Dispatchers.IO) {
        val assets = if (ocr) ocrAssets else voiceAssets
        require(assets.isNotEmpty()) { "The model manifest is missing." }
        assets.forEachIndexed { index, asset ->
            coroutineContext.ensureActive()
            val destination = File(root, asset.name); destination.parentFile?.mkdirs()
            if (destination.exists() && digest(destination) == asset.sha256) return@forEachIndexed
            require(download) { if (ocr) "Download Scan & Listen in Settings first." else "Download natural voices in Settings first." }
            val temporary = File(destination.path + ".download")
            val connection = URL(asset.url).openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000; connection.readTimeout = 60_000
            try {
                require(connection.responseCode == 200 && connection.url.protocol == "https") { "The model download could not finish. Check your connection and retry." }
                val total = connection.contentLengthLong; var copied = 0L
                connection.inputStream.use { input -> temporary.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive(); val count = input.read(buffer); if (count < 0) break
                        copied += count; require(copied <= 120 * 1024 * 1024) { "The model file exceeds its download limit." }
                        output.write(buffer, 0, count); if (total > 0) progress((index + copied.toFloat() / total) / assets.size)
                    }
                } }
                require(digest(temporary) == asset.sha256) { "The download failed its integrity check. Please retry." }
                if (destination.exists()) destination.delete()
                require(temporary.renameTo(destination)) { "The model could not be saved." }
            } finally { connection.disconnect(); temporary.delete() }
        }
        progress(1f)
    }
    fun preparePronunciation() {
        // Versioned with the app, not a network download. Replace legacy data on
        // app upgrade atomically so the engine and compiled dictionary match.
        fun copy(path: String) {
            val children = context.assets.list(path).orEmpty()
            if (children.isNotEmpty()) { children.forEach { copy("$path/$it") }; return }
            val destination = File(root, path); destination.parentFile?.mkdirs()
            val temporary = File(destination.path + ".new")
            context.assets.open(path).use { input -> temporary.outputStream().use { input.copyTo(it) } }
            require(temporary.renameTo(destination)) { "The pronunciation dictionary could not be installed." }
        }
        copy("espeak-ng-data")
    }
    private fun digest(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(1024 * 1024); while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) } }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
