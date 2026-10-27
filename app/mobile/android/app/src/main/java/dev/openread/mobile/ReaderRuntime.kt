package dev.openread.mobile

import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File

class OpenReadApplication : Application() {
    val reader by lazy { ReaderRuntime(this) }
}
data class ReaderState(
    val reading: Reading? = null, val index: Int = 0, val playing: Boolean = false, val preparing: Boolean = false,
    val highlight: WordRange? = null, val status: String = "Ready", val error: String? = null,
    val voice: String = "Kiki", val speed: Float = 1f, val installed: Boolean = false,
    val downloading: Boolean = false, val downloadProgress: Float = 0f, val ocrInstalled: Boolean = false,
    val direction: String = "", val qwenExpressive: Boolean = false, val qwenCloning: Boolean = false, val personalVoices: List<PersonalVoice> = emptyList(),
    val follow: Boolean = true, val highlightWords: Boolean = true, val sleepMinutes: Int = 0
)
class ReaderRuntime(val context: Context) {
    val library = LibraryStore(context)
    val models = ModelStore(context)
    val engine = VoiceEngine(models, context, { state.value.voice }, { state.value.direction })
    val importer = DocumentImporter(context, models)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val preferences = context.getSharedPreferences("reading", Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(ReaderState(error = library.recoveryError, voice = preferences.getString("voice", "Kiki").takeIf { it in KittenEngine.voices || QwenEngine.isVoice(it.orEmpty()) } ?: "Kiki",
        speed = preferences.getFloat("speed", 1f).coerceIn(.5f, 2f), installed = models.installed(), ocrInstalled = models.installed(true)))
    val state = mutable.asStateFlow()
    internal val commandToken = java.util.UUID.randomUUID().toString()
    var service: ReadingService? = null
    var passages = emptyList<ReadingPassage>(); private set
    private var download: Job? = null
    private var textWindows = emptyList<WordRange>()
    var sleepDeadline = 0L; private set
    fun update(change: (ReaderState) -> ReaderState) { mutable.update(change) }
    fun open(reading: Reading) {
        service?.stopReading(); passages = ReadingText.passages(reading)
        textWindows = ReadingText.windows(reading, passages)
        val book = reading.copy(cachedWordCount = reading.wordCount, cachedTextLength = reading.text.length)
        val index = passages.indexOfFirst { it.end > reading.position }.coerceAtLeast(0)
        update { it.copy(reading = book, index = index, highlight = null, playing = false, preparing = false, status = "Ready to listen", error = null) }
    }
    fun command(action: String) {
        val intent = Intent(context, ReadingService::class.java).setAction(action).putExtra("openread.command", commandToken)
        if (action == "play" || (action in listOf("next", "previous") && state.value.playing)) ContextCompat.startForegroundService(context, intent)
        else if (service != null) context.startService(intent)
        else if (action == "next" || action == "previous") move(if (action == "next") 1 else -1)
    }
    fun move(delta: Int) {
        val s = state.value; val index = (s.index + delta).coerceIn(0, (passages.size - 1).coerceAtLeast(0))
        update { it.copy(index = index, highlight = null) }; persistPosition()
    }
    fun seek(offset: Int) {
        val active = state.value.playing || state.value.preparing
        service?.stopReading()
        val index = passages.indexOfFirst { it.end > offset }.takeIf { it >= 0 } ?: passages.lastIndex.coerceAtLeast(0)
        update { it.copy(index = index, highlight = null) }; persistPosition()
        if (active) command("play")
    }
    fun textWindow(): WordRange { val current = state.value; val offset = current.highlight?.start ?: passages.getOrNull(current.index)?.start ?: 0; return textWindows.lastOrNull { it.start <= offset } ?: WordRange(0, 0) }
    fun seekTextWindow(delta: Int) { val window = textWindow(); val index = textWindows.indexOf(window) + delta; textWindows.getOrNull(index)?.let { seek(it.start) } }
    fun speed(value: Float) {
        val speed = value.coerceIn(.5f, 2f); preferences.edit().putFloat("speed", speed).apply()
        update { it.copy(speed = speed) }; service?.setSpeed(speed)
    }
    fun voice(value: String) {
        if (value !in KittenEngine.voices && value !in QwenEngine.speakers.map { "qwen:$it" } && value !in engine.qwen.profiles().map { "qwen:clone:${it.id}" }) return
        val active = state.value.playing || state.value.preparing
        service?.stopReading(); preferences.edit().putString("voice", value).apply(); update { it.copy(voice = value, installed = if (QwenEngine.isVoice(value)) engine.qwen.installedVoice(value) else models.installed()) }
        if (active) command("play")
    }
    fun sleep(minutes: Int) { sleepDeadline = if (minutes > 0) System.currentTimeMillis() + minutes * 60_000L else 0L; update { it.copy(sleepMinutes = minutes) } }
    fun persistPosition() {
        val s = state.value; val reading = s.reading ?: return
        val offset = s.highlight?.start ?: passages.getOrNull(s.index)?.start ?: 0
        if (library.readings.value.any { it.id == reading.id }) scope.launch(Dispatchers.IO) { runCatching { library.position(reading.id, offset) }.onFailure { fail(it) } }
    }
    fun save() {
        val s = state.value; val reading = s.reading ?: return
        val saved = reading.copy(position = s.highlight?.start ?: passages.getOrNull(s.index)?.start ?: 0)
        scope.launch(Dispatchers.IO) { runCatching { library.save(saved) }.onSuccess { update { it.copy(reading = saved, status = "Saved to library") } }.onFailure { fail(it) } }
    }
    fun bookmark() {
        val s = state.value; val reading = s.reading ?: return
        val offset = s.highlight?.start ?: passages.getOrNull(s.index)?.start ?: 0
        if (reading.bookmarks.any { it.offset == offset }) return
        val label = reading.text.substring(offset).take(80).substringBefore('\n')
        update { it.copy(reading = reading.copy(bookmarks = reading.bookmarks + ReadingBookmark(offset, label))) }; save()
    }
    fun removeBookmark(offset: Int) { val reading = state.value.reading ?: return; update { it.copy(reading = reading.copy(bookmarks = reading.bookmarks.filterNot { b -> b.offset == offset })) }; save() }
    fun setup(ocr: Boolean = false) {
        if (download?.isActive == true) return
        update { it.copy(downloading = true, downloadProgress = 0f, error = null) }
        download = scope.launch {
            try {
                if (ocr) models.prepare(ocr = true, download = true) { progress -> update { it.copy(downloadProgress = progress) } }
                else engine.prepare(download = true) { progress -> update { it.copy(downloadProgress = progress) } }
                update { it.copy(installed = models.installed(), ocrInstalled = models.installed(true), status = "Ready to listen") }
            } catch (_: CancellationException) { } catch (error: Exception) { fail(error) }
            finally { update { it.copy(downloading = false) } }
        }
    }
    init { update { it.copy(direction = preferences.getString("direction", "").orEmpty(), qwenExpressive = engine.qwen.installed("expressive"), qwenCloning = engine.qwen.installed("clone"), personalVoices = engine.qwen.profiles(), installed = if (QwenEngine.isVoice(it.voice)) engine.qwen.installedVoice(it.voice) else models.installed()) } }
    fun direction(value: String) { val bounded = value.take(500); preferences.edit().putString("direction", bounded).apply(); update { it.copy(direction = bounded) } }
    fun setupQwen(pack: String) {
        if (download?.isActive == true) return
        service?.stopReading(); update { it.copy(downloading = true, downloadProgress = 0f, error = null) }
        download = scope.launch { try { engine.qwen.download(pack) { progress -> update { it.copy(downloadProgress = progress) } }; update { it.copy(qwenExpressive = engine.qwen.installed("expressive"), qwenCloning = engine.qwen.installed("clone"), installed = if (QwenEngine.isVoice(it.voice)) engine.qwen.installedVoice(it.voice) else models.installed()) } } catch (_: CancellationException) {} catch (error: Exception) { fail(error) } finally { update { it.copy(downloading = false) } } }
    }
    fun cloneVoice(name: String, transcript: String, sample: android.net.Uri, permission: Boolean) {
        if (download?.isActive == true) return
        service?.stopReading(); update { it.copy(downloading = true, status = "Preparing personal voice", error = null) }
        download = scope.launch { try { val profile = engine.qwen.clone(name, transcript, sample, permission); update { it.copy(personalVoices = engine.qwen.profiles()) }; voice("qwen:clone:${profile.id}") } catch (_: CancellationException) {} catch (error: Exception) { fail(error) } finally { update { it.copy(downloading = false) } } }
    }
    fun removeVoice(id: String) { scope.launch { try { engine.qwen.remove(id); if (state.value.voice == "qwen:clone:$id") voice("Kiki"); update { it.copy(personalVoices = engine.qwen.profiles()) } } catch (error: Exception) { fail(error) } } }
    fun cancelDownload() { download?.cancel() }
    fun fail(error: Throwable) { update { it.copy(error = error.message?.take(280) ?: "Something went wrong. Please try again.") } }
    suspend fun exportAudio(progress: (Int, Int) -> Unit): File {
        val reading = state.value.reading ?: error("Open a reading first.")
        // Stream bounded passages to disk instead of retaining whole-book audio.
        engine.prepare(download = false)
        val voice = state.value.voice; val parts = ReadingText.passages(reading)
        val output = File(context.cacheDir, "exports").apply { mkdirs() }.resolve("OpenRead-${System.currentTimeMillis()}.wav")
        try {
            withContext(Dispatchers.IO) { output.outputStream().use { stream ->
                stream.write(ByteArray(44))
                parts.forEachIndexed { index, passage ->
                    coroutineContext.ensureActive(); val clip = engine.generate(passage.text, voice)
                    require(output.length() + clip.wav.size - 44 <= Int.MAX_VALUE.toLong()) { "This export is too large for a WAV file." }
                    stream.write(clip.wav, 44, clip.wav.size - 44); progress(index + 1, parts.size)
                }
            }
                val bytes = output.length() - 44
                require(bytes <= Int.MAX_VALUE - 44) { "This export is too large." }
                val header = KittenEngine.wav(FloatArray(0)); java.nio.ByteBuffer.wrap(header).order(java.nio.ByteOrder.LITTLE_ENDIAN).apply { putInt(4, 36 + bytes.toInt()); putInt(40, bytes.toInt()) }
                java.io.RandomAccessFile(output, "rw").use { it.write(header) }
            }
            return output
        } catch (error: Throwable) { output.delete(); throw error }
    }
}
