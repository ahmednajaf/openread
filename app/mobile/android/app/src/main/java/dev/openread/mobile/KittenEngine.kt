// Token alphabet and duration joining follow KittenML KittenTTS (Apache-2.0).
// Exact upstream revisions and notices are retained in shared/NOTICES.txt.
package dev.openread.mobile

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.zip.ZipFile
import kotlin.coroutines.coroutineContext

internal object NativePhonemizer {
    init { System.loadLibrary("openread_phonemizer") }
    external fun create(rules: String, list: String): Long
    external fun phonemize(handle: Long, text: String): String
    external fun destroy(handle: Long)
}

/** Kitten Mini runs entirely on the phone. Only the explicitly requested model download uses a network. */
class KittenEngine(val models: ModelStore) {
    companion object {
        val voices = linkedMapOf("Kiki" to "expr-voice-5-f", "Rosie" to "expr-voice-4-f", "Jasper" to "expr-voice-2-m", "Luna" to "expr-voice-3-f",
            "Bruno" to "expr-voice-3-m", "Hugo" to "expr-voice-4-m", "Leo" to "expr-voice-5-m", "Bella" to "expr-voice-2-f")
        private const val SYMBOLS = "\$;:,.!?¡¿—…\"«»“” ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘’̩‘ᵻ"
        private val symbols = SYMBOLS.withIndex().associate { it.value to it.index.toLong() }
        internal fun tokens(phonemes: String): LongArray = longArrayOf(0) + phonemes.mapNotNull { symbols[it] }.toLongArray() + longArrayOf(10, 0)
        internal fun wav(samples: FloatArray): ByteArray {
            val output = ByteBuffer.allocate(44 + samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            output.put("RIFF".toByteArray()).putInt(36 + samples.size * 2).put("WAVEfmt ".toByteArray()).putInt(16)
                .putShort(1).putShort(1).putInt(24000).putInt(48000).putShort(2).putShort(16).put("data".toByteArray()).putInt(samples.size * 2)
            samples.forEach { output.putShort((it.coerceIn(-1f, 1f) * 32767).toInt().toShort()) }
            return output.array()
        }
    }
    private val mutex = Mutex()
    private val environment = OrtEnvironment.getEnvironment().apply { setTelemetry(false) }
    private var session: OrtSession? = null
    private var phonemizer = 0L
    private val embeddings = mutableMapOf<String, Embedding>()
    private val cache = LinkedHashMap<String, SpokenClip>()
    suspend fun prepare(download: Boolean, progress: (Float) -> Unit = {}) = mutex.withLock { withContext(Dispatchers.IO) {
        if (session != null) return@withContext
        models.prepare(download = download, progress = progress)
        val handle = NativePhonemizer.create(File(models.root, "en_rules").path, File(models.root, "en_list").path)
        try {
            val loaded = readEmbeddings(File(models.root, "voices.npz"))
            val engine = OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(2)
                options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                environment.createSession(File(models.root, "kitten_tts_mini_v0_8.onnx").path, options)
            }
            phonemizer = handle; embeddings.putAll(loaded); session = engine
        } catch (error: Throwable) { NativePhonemizer.destroy(handle); throw error }
    } }
    suspend fun generate(text: String, voice: String): SpokenClip = mutex.withLock { withContext(Dispatchers.Default) {
        val key = "$voice\n$text"
        cache[key]?.let { return@withContext it }
        val engine = checkNotNull(session) { "Download natural voices in Settings first." }
        val embedding = checkNotNull(embeddings[voices[voice] ?: voices.getValue("Kiki")]) { "This voice is missing from the download." }
        val phonemes = NativePhonemizer.phonemize(phonemizer, text.replace(Regex("\\s+"), " "))
        val encoded = tokens(phonemes); require(encoded.size > 3) { "There are no spoken words in this passage." }
        val body = encoded.drop(1).dropLast(2)
        val chunks = body.chunked(397)
        val samples = ArrayList<Float>(); var durations = LongArray(0)
        for (chunk in chunks) {
            coroutineContext.ensureActive()
            val ids = longArrayOf(0) + chunk.toLongArray() + longArrayOf(10, 0)
            // The style row and voice-specific speed priors match Kitten's published Mini configuration.
            val speed = 1f
            OnnxTensor.createTensor(environment, LongBuffer.wrap(ids), longArrayOf(1, ids.size.toLong())).use { input ->
                val row = embedding.row(phonemes.length)
                OnnxTensor.createTensor(environment, FloatBuffer.wrap(row), longArrayOf(1, row.size.toLong())).use { style ->
                    OnnxTensor.createTensor(environment, FloatBuffer.wrap(floatArrayOf(speed)), longArrayOf(1)).use { rate ->
                        engine.run(mapOf("input_ids" to input, "style" to style, "speed" to rate)).use { result ->
                            val value = result.get("waveform").orElseGet { result[0] } as OnnxTensor
                            val buffer = value.floatBuffer; val audio = FloatArray(buffer.remaining()); buffer.get(audio)
                            require(audio.all { it.isFinite() }) { "The voice returned invalid audio. Try another voice." }
                            val trim = if (audio.size > 6000) 5000 else 0
                            samples.addAll(audio.take(audio.size - trim))
                            if (chunks.size == 1 && result.get("duration").isPresent) {
                                val frames = (result.get("duration").get() as OnnxTensor).longBuffer
                                durations = LongArray(frames.remaining()).also { frames.get(it) }
                            }
                        }
                    }
                }
            }
        }
        coroutineContext.ensureActive()
        require(samples.size > 480 && samples.any { kotlin.math.abs(it) > 0.00001f }) { "This passage did not produce audio. Try another voice." }
        val duration = samples.size / 24000.0
        val predicted = predictedWords(text, phonemes, durations, duration)
        val clip = SpokenClip(wav(samples.toFloatArray()), predicted ?: ReadingText.estimatedWords(text, duration), duration)
        cache[key] = clip; while (cache.size > 3) cache.remove(cache.keys.first())
        clip
    } }
    private fun predictedWords(text: String, phonemes: String, frames: LongArray, duration: Double): List<SpokenWord>? {
        val source = ReadingText.words(text); val groups = Regex("\\S+").findAll(phonemes).toList()
        if (source.size != groups.size || frames.size != tokens(phonemes).size || frames.any { it < 0 }) return null
        // Match Kitten's join_timestamps: duration units are half-frames at 80 Hz,
        // with the inter-word space divided across the neighbouring words.
        var left = 2.0 * (frames[0] - 3).coerceAtLeast(0); var right = left; var token = 1
        return groups.mapIndexed { index, group ->
            val length = group.value.length
            if (token + length > frames.size) return null
            val start = (left / 80.0).coerceIn(0.0, duration)
            val wordFrames = frames.sliceArray(token until token + length).sum()
            val space = if (index < groups.lastIndex && token + length < frames.size) frames[token + length] else 0
            left = right + 2.0 * wordFrames + space
            val end = (left / 80.0).coerceIn(start, duration); right = left + space
            token += length + if (index < groups.lastIndex) 1 else 0
            SpokenWord(source[index].start, source[index].end - source[index].start, start, end)
        }.takeIf { words -> words.all { it.end > it.start } }
    }

    private data class Embedding(val values: FloatArray, val rows: Int, val width: Int) {
        fun row(length: Int) = values.copyOfRange(length.coerceIn(0, rows - 1) * width, (length.coerceIn(0, rows - 1) + 1) * width)
    }
    private fun readEmbeddings(file: File): Map<String, Embedding> = ZipFile(file).use { zip ->
        voices.values.associateWith { key ->
            val entry = requireNotNull(zip.getEntry("$key.npy")) { "The voices file is incomplete." }
            require(entry.size in 1..20_000_000) { "The voices file is invalid." }
            val bytes = zip.getInputStream(entry).use { it.readBytes() }
            require(bytes.size > 12 && bytes.copyOfRange(1, 6).toString(Charsets.US_ASCII) == "NUMPY")
            val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN); buffer.position(8)
            val headerLength = if (bytes[6].toInt() == 1) buffer.short.toInt() and 0xffff else buffer.int
            require(headerLength in 1..4096 && buffer.remaining() >= headerLength)
            val header = ByteArray(headerLength).also { buffer.get(it) }.toString(Charsets.US_ASCII)
            require("False" in header && "'<f4'" in header) { "The voice embedding has an unsupported format." }
            val shape = requireNotNull(Regex("'shape': \\(([^)]*)\\)").find(header)).groupValues[1].split(',').mapNotNull { it.trim().toIntOrNull() }
            require(shape.size in 2..3 && shape.all { it > 0 })
            val width = shape.drop(1).fold(1) { a, b -> Math.multiplyExact(a, b) }; val count = Math.multiplyExact(shape[0], width)
            require(count <= 5_000_000 && buffer.remaining() == count * 4)
            Embedding(FloatArray(count) { buffer.float }, shape[0], width)
        }
    }
}
