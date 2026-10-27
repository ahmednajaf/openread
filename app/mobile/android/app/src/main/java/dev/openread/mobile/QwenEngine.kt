package dev.openread.mobile

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext

@androidx.annotation.Keep
internal fun interface QwenAudioCallback { fun onAudio(samples: FloatArray, startByte: Int, endByte: Int): Boolean }

internal object NativeQwen {
    init { System.loadLibrary("openread_qwen") }
    external fun create(root: String, model: String): Long
    external fun destroy(handle: Long)
    external fun generate(handle: Long, text: String, speaker: String, direction: String, prompt: String?, receiver: QwenAudioCallback?): FloatArray
    external fun clone(handle: Long, sample: String, transcript: String, output: String): Boolean
}
data class PersonalVoice(val id: String, val name: String, val transcript: String)
class QwenEngine(private val context: Context) {
    companion object {
        val speakers = listOf("ryan", "aiden", "vivian", "serena", "dylan", "eric", "uncle_fu", "ono_anna", "sohee")
        const val expressive = "qwen-talker-1.7b-customvoice-Q4_K_M.gguf"
        const val cloneModel = "qwen-talker-0.6b-base-Q4_K_M.gguf"
        fun isVoice(value: String) = value.startsWith("qwen:")
    }
    val root = File(context.noBackupFilesDir, "QwenModels").apply { mkdirs() }
    private val mutex = Mutex()
    private var handle = 0L
    private var loaded: String? = null
    private val cache = LinkedHashMap<String, SpokenClip>()
    private val manifest get() = JSONObject(context.assets.open("qwen-models.json").bufferedReader().use { it.readText() })
    fun profiles(): List<PersonalVoice> = File(root, "Profiles").listFiles().orEmpty().filter { it.extension == "json" && runCatching { UUID.fromString(it.nameWithoutExtension) }.isSuccess }.mapNotNull { file -> runCatching { JSONObject(file.readText()).let { value -> val id = value.getString("id"); UUID.fromString(id); PersonalVoice(id, value.getString("name"), value.getString("transcript")) } }.getOrNull() }.sortedBy { it.name }
    fun installed(pack: String): Boolean = listOf(if (pack == "clone") cloneModel else expressive, "qwen-tokenizer-12hz-Q4_K_M.gguf").all { File(root, it).isFile }
    fun installedVoice(voice: String): Boolean = installed(if (voice.startsWith("qwen:clone:")) "clone" else "expressive")
    fun label(voice: String): String = if (voice.startsWith("qwen:clone:")) profiles().firstOrNull { it.id == voice.removePrefix("qwen:clone:") }?.name ?: "Personal voice" else if (isVoice(voice)) "Qwen · " + voice.removePrefix("qwen:").replace('_', ' ').replaceFirstChar { it.uppercase() } else voice
    suspend fun download(pack: String, progress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        require(pack in listOf("expressive", "clone"))
        val array = manifest.getJSONArray("assets"); val assets = (0 until array.length()).map { array.getJSONObject(it) }.filter { it.getString("pack") in listOf(pack, "shared") }
        val total = assets.sumOf { it.getLong("bytes") }; var done = 0L
        for (asset in assets) {
            coroutineContext.ensureActive(); val destination = File(root, asset.getString("name")); val expected = asset.getLong("bytes")
            if (destination.isFile && destination.length() == expected && digest(destination) == asset.getString("sha256")) { done += expected; continue }
            val temporary = File(root, destination.name + ".download")
            val connection = URL(asset.getString("url")).openConnection() as HttpURLConnection
            connection.connectTimeout = 20_000; connection.readTimeout = 60_000
            try {
                require(connection.responseCode == 200 && connection.url.protocol == "https") { "Qwen download could not finish. Check your connection and retry." }
                var copied = 0L
                connection.inputStream.use { input -> temporary.outputStream().use { output ->
                    val block = ByteArray(1024 * 1024)
                    while (true) { coroutineContext.ensureActive(); val count = input.read(block); if (count < 0) break; copied += count; require(copied <= expected); output.write(block, 0, count); progress((done + copied).toFloat() / total) }
                } }
                require(copied == expected && digest(temporary) == asset.getString("sha256")) { "Qwen download failed its integrity check. Retry the download." }
                require(temporary.renameTo(destination)) { "Qwen could not be saved." }; done += expected
            } finally { connection.disconnect(); temporary.delete() }
        }
        progress(1f)
    }
    suspend fun release() = mutex.withLock { withContext(Dispatchers.IO) { unload(); cache.clear() } }
    private fun unload() { if (handle != 0L) NativeQwen.destroy(handle); handle = 0; loaded = null }
    private fun load(clone: Boolean) {
        val model = if (clone) cloneModel else expressive
        if (loaded == model && handle != 0L) return
        unload(); require(installed(if (clone) "clone" else "expressive")) { "Download this optional Qwen pack in Settings first." }
        val memory = android.app.ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(memory)
        require(!memory.lowMemory && memory.availMem >= 1_900_000_000L) { "There is not enough memory available for Qwen. Close other apps or choose a Kitten voice." }
        handle = NativeQwen.create(root.path, model); loaded = model
    }
    suspend fun generate(text: String, voice: String, direction: String, onChunk: ((SpokenClip) -> Unit)? = null): SpokenClip = mutex.withLock { withContext(Dispatchers.IO) {
        coroutineContext.ensureActive(); require(text.length <= 1600 && direction.length <= 500)
        val clone = voice.startsWith("qwen:clone:"); val key = voice.removePrefix(if (clone) "qwen:clone:" else "qwen:")
        if (clone) UUID.fromString(key) else require(key in speakers)
        val cacheKey = voice + "\n" + direction + "\n" + text
        cache[cacheKey]?.let { onChunk?.invoke(it); return@withContext it }
        load(clone)
        val quick = clone && profiles().firstOrNull { it.id == key }?.transcript?.isBlank() == true
        val receiver = onChunk?.let { send -> QwenAudioCallback { samples, start, end ->
            require(samples.all { it.isFinite() }) { "Qwen returned invalid audio." }
            val bytes = text.toByteArray(Charsets.UTF_8); val a = start.coerceAtLeast(0); val b = end.coerceAtMost(bytes.size)
            val valid = a < b && a <= bytes.size && (a == bytes.size || bytes[a].toInt() and 0xc0 != 0x80) && (b == bytes.size || bytes[b].toInt() and 0xc0 != 0x80)
            val duration = samples.size / 24000.0
            val words = if (valid) { val offset = String(bytes, 0, a, Charsets.UTF_8).length; ReadingText.estimatedWords(String(bytes, a, b-a, Charsets.UTF_8), duration).map { it.copy(offset = it.offset + offset) } } else emptyList()
            send(SpokenClip(KittenEngine.wav(samples), words, duration)); true
        } }
        val samples = kotlinx.coroutines.runInterruptible { NativeQwen.generate(handle, text, if (clone) "" else key, if (clone) "" else direction, if (clone) File(root, "Profiles/$key" + if (quick) ".speaker.json" else ".icl").path else null, receiver) }
        coroutineContext.ensureActive(); val duration = samples.size / 24000.0
        val clip = SpokenClip(KittenEngine.wav(samples), ReadingText.estimatedWords(text, duration), duration)
        cache[cacheKey] = clip; while (cache.size > 3) cache.remove(cache.keys.first())
        clip
    } }
    fun stream(text: String, voice: String, direction: String): kotlinx.coroutines.flow.Flow<SpokenClip> = kotlinx.coroutines.flow.channelFlow {
        generate(text, voice, direction) { trySendBlocking(it).getOrThrow() }
    }.buffer(3)
    suspend fun clone(name: String, transcript: String, sample: Uri, permission: Boolean): PersonalVoice = mutex.withLock { withContext(Dispatchers.IO) {
        require(permission && name.trim().isNotEmpty() && name.length <= 80 && transcript.length <= 2000) { "Add a voice name and permission confirmation. A transcript is optional." }
        val directory = File(root, "Profiles").apply { mkdirs() }; val voice = PersonalVoice(UUID.randomUUID().toString(), name.trim(), transcript.trim())
        val reference = File(directory, voice.id + ".wav"); val prompt = File(directory, voice.id + if (transcript.trim().isEmpty()) ".speaker.json" else ".icl")
        try {
            val decoded = VoiceSample.read(context, sample)
            require(decoded.all { it.isFinite() } && decoded.any { kotlin.math.abs(it) > 0.001f }) { "The sample contains no usable speech. Choose clear, audible speech." }
            reference.writeBytes(KittenEngine.wav(decoded))
            load(true); require(NativeQwen.clone(handle, reference.path, transcript, prompt.path)) { "This sample could not be prepared. Try clear speech without music." }
            coroutineContext.ensureActive()
            File(directory, voice.id + ".json").writeText(JSONObject().put("id", voice.id).put("name", voice.name).put("transcript", voice.transcript).toString())
            voice
        } catch (error: Throwable) { prompt.delete(); throw error } finally { reference.delete() }
    } }
    suspend fun remove(id: String) = mutex.withLock { withContext(Dispatchers.IO) { UUID.fromString(id); listOf("json", "icl", "speaker.json").forEach { File(root, "Profiles/$id.$it").delete() }; Unit } }
    private fun digest(file: File): String { val hash = MessageDigest.getInstance("SHA-256"); file.inputStream().use { input -> val block = ByteArray(1024 * 1024); while (true) { val count = input.read(block); if (count < 0) break; hash.update(block, 0, count) } }; return hash.digest().joinToString("") { "%02x".format(it) } }
}

class VoiceEngine(private val models: ModelStore, context: Context, private val selected: () -> String, private val direction: () -> String) {
    private val kitten = KittenEngine(models)
    val qwen = QwenEngine(context)
    suspend fun prepare(download: Boolean, progress: (Float) -> Unit = {}) {
        if (QwenEngine.isVoice(selected())) { kitten.release(); val pack = if (selected().startsWith("qwen:clone:")) "clone" else "expressive"; if (download) qwen.download(pack, progress); require(qwen.installed(pack)) { "Download this Qwen pack in Settings first." } }
        else { qwen.release(); kitten.prepare(download, progress) }
    }
    suspend fun generate(text: String, voice: String): SpokenClip = if (QwenEngine.isVoice(voice)) qwen.generate(text, voice, direction()) else kitten.generate(text, voice)
}
