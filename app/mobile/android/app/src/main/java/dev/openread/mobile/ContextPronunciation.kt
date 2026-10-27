package dev.openread.mobile

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.json.JSONObject
import java.io.File
import java.nio.LongBuffer
import java.text.Normalizer
import java.util.Locale
import kotlin.math.exp
import kotlin.math.ln

/** Same compact encoder, dictionary and tokenization as the Apple and desktop apps. */
internal class ContextPronunciation(private val folder: File) : AutoCloseable {
    private data class Entry(val id: Int, val ipa: String?, val tags: IntArray)
    private data class Candidate(val owner: Int, val word: String, val tokens: LongArray)
    private val vocabulary = File(folder, "vocab.txt").readLines().withIndex().associate { it.value to it.index.toLong() }
    private val data = JSONObject(File(folder, "lexicon.json").readText())
    private val words = data.getJSONObject("words").let { value -> value.keys().asSequence().associateWith { word ->
        val array = value.getJSONArray(word); (0 until array.length()).map { i -> val e = array.getJSONObject(i); val tags = e.getJSONArray("tags"); Entry(e.getInt("id"), if (e.isNull("ipa")) null else e.getString("ipa"), IntArray(tags.length()) { tags.getInt(it) }) }
    } }
    private val confidence = data.getDouble("confidence")
    private val grammarConfidence = data.getDouble("grammar_confidence")
    private val environment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private val punctuation = ";:,.!?\"'“”‘’()[]{}«»—…"
    internal fun tokenIDs(text: String): LongArray {
        val normalized = Normalizer.normalize(text.lowercase(Locale.ROOT), Normalizer.Form.NFD)
        val basic = mutableListOf<String>(); val word = StringBuilder()
        fun flush() { if (word.isNotEmpty()) { basic += word.toString(); word.setLength(0) } }
        normalized.codePoints().forEach { code ->
            val type = Character.getType(code)
            when {
                type == Character.NON_SPACING_MARK.toInt() -> Unit
                Character.isWhitespace(code) || Character.isSpaceChar(code) || code == 0x85 -> flush()
                type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt() -> Unit
                code in 33..47 || code in 58..64 || code in 91..96 || code in 123..126 || type in listOf(Character.CONNECTOR_PUNCTUATION.toInt(),Character.DASH_PUNCTUATION.toInt(),Character.START_PUNCTUATION.toInt(),Character.END_PUNCTUATION.toInt(),Character.INITIAL_QUOTE_PUNCTUATION.toInt(),Character.FINAL_QUOTE_PUNCTUATION.toInt(),Character.OTHER_PUNCTUATION.toInt()) || listOf(0x4e00..0x9fff,0x3400..0x4dbf,0x20000..0x2a6df,0x2a700..0x2b73f,0x2b740..0x2b81f,0x2b820..0x2ceaf,0xf900..0xfaff,0x2f800..0x2fa1f).any { code in it } -> { flush(); basic += String(Character.toChars(code)) }
                else -> word.appendCodePoint(code)
            }
        }
        flush(); val result = mutableListOf<Long>()
        for (word in basic) {
            if (word.codePointCount(0, word.length) > 100) { result += 100L; continue }
            var start = 0; val pieces = mutableListOf<Long>()
            while (start < word.length) {
                var end = word.length; var found: Long? = null
                while (end > start) { found = vocabulary[(if (start == 0) "" else "##") + word.substring(start,end)]; if (found != null) break; end -= if (end >= 2 && Character.isLowSurrogate(word[end-1]) && Character.isHighSurrogate(word[end-2])) 2 else 1 }
                if (found == null) { pieces.clear(); pieces += 100L; break }
                pieces += found; start = end
            }
            result += pieces
        }
        return result.toLongArray()
    }
    @Synchronized fun replacements(text: String): String {
        val candidates = mutableListOf<Candidate>()
        Regex("(?U)\\S+").findAll(text).forEachIndexed { owner, match ->
            val trimmed = match.value.trim { it in punctuation }; val word = trimmed.lowercase(Locale.ROOT)
            if (word in words && candidates.size < 64) {
                val a = match.range.first + match.value.indexOf(trimmed); val b = a + trimmed.length
                val tokens = longArrayOf(101) + tokenIDs(text.substring(0,a)).takeLast(55) + longArrayOf(1) + tokenIDs(trimmed) + longArrayOf(2) + tokenIDs(text.substring(b)).take(55) + longArrayOf(102)
                candidates += Candidate(owner,word,tokens)
            }
        }
        if (candidates.isEmpty()) return ""
        val engine = session ?: OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(2); options.setCPUArenaAllocator(false)
            environment.createSession(File(folder,"context.ort").path,options).also { session = it }
        }
        val replacements = mutableListOf<String>()
        for (batch in candidates.chunked(8)) {
            val width = batch.maxOf { it.tokens.size }; val ids = LongArray(batch.size*width)
            batch.forEachIndexed { i,c -> c.tokens.copyInto(ids,i*width) }; val mask = ids.map { if (it == 0L) 0L else 1L }.toLongArray()
            val shape = longArrayOf(batch.size.toLong(),width.toLong())
            OnnxTensor.createTensor(environment,LongBuffer.wrap(ids),shape).use { input -> OnnxTensor.createTensor(environment,LongBuffer.wrap(mask),shape).use { attention ->
                engine.run(mapOf("input_ids" to input,"attention_mask" to attention)).use { output ->
                    @Suppress("UNCHECKED_CAST") val scores = output[0].value as Array<FloatArray>
                    @Suppress("UNCHECKED_CAST") val grammar = output[1].value as Array<FloatArray>
                    batch.forEachIndexed { i,c ->
                        val entries = words.getValue(c.word)
                        if (entries.any { it.id !in scores[i].indices || it.tags.any { t -> t !in grammar[i].indices } }) return@forEachIndexed
                        val mass = DoubleArray(entries.size) { 1.0 }; val values = entries.map { scores[i][it.id].toDouble() }.toDoubleArray()
                        if (entries.all { it.tags.isNotEmpty() }) {
                            val peak = grammar[i].max(); val probs = grammar[i].map { exp((it-peak).toDouble()) }; val total = probs.sum()
                            entries.forEachIndexed { k,e -> mass[k] = e.tags.sumOf { probs[it]/total }; values[k] += ln(maxOf(.01,mass[k])) }
                        }
                        val peak = values.max(); val probs = values.map { exp(it-peak) }; val total = probs.sum(); val best = probs.indices.maxBy { probs[it] }
                        if (probs[best]/total >= confidence && mass[best] >= grammarConfidence) entries[best].ipa?.let { replacements += "${c.owner}\t$it" }
                    }
                }
            } }
        }
        return replacements.joinToString("\n")
    }
    @Synchronized override fun close() { session?.close(); session = null }
}
