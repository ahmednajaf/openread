package dev.openread.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class ReadingChapter(val id: String, val title: String, val offset: Int)
data class ReadingBookmark(val offset: Int, val label: String)
data class Reading(
    val id: String = UUID.randomUUID().toString(), val title: String, val text: String,
    val source: String? = null, val author: String? = null, val position: Int = 0,
    val bookmarks: List<ReadingBookmark> = emptyList(), val createdAt: Double = System.currentTimeMillis() / 1000.0,
    val chapters: List<ReadingChapter> = emptyList(), val cachedWordCount: Int? = null, val cachedTextLength: Int? = null
) {
    val wordCount get() = cachedWordCount ?: ReadingText.wordCount(text)
    val textLength get() = cachedTextLength ?: text.length
    fun validated(summary: Boolean = false): Reading {
        require(id.isNotEmpty() && id.length <= 80 && title.isNotBlank() && title.length <= 240 && ((summary && text.isEmpty() && textLength in 1..20_000_000) || (text.isNotBlank() && text.length <= 20_000_000)) &&
            (source?.length ?: 0) <= 1000 && position in 0..textLength && bookmarks.size <= 200 &&
            bookmarks.all { it.offset in 0..textLength && it.label.length <= 160 }) { "This reading or backup is invalid. Nothing was imported." }
        require(cachedWordCount == null || cachedWordCount in 0..textLength)
        require(summary || cachedTextLength == null || cachedTextLength == text.length)
        require(chapters.size <= 5000 && chapters.map { it.id }.distinct().size == chapters.size && (chapters.isEmpty() || chapters.first().offset == 0))
        var previous = -1
        chapters.forEach { require(it.id.isNotEmpty() && it.id.length <= 80 && it.title.isNotBlank() && it.title.length <= 240 && it.offset > previous && it.offset < textLength); previous = it.offset }
        return this
    }
    fun json(): JSONObject = JSONObject().put("id", id).put("title", title).put("text", text).put("position", position).put("createdAt", createdAt)
        .put("chapters", JSONArray(chapters.map { JSONObject().put("id", it.id).put("title", it.title).put("offset", it.offset) })).put("cachedWordCount", cachedWordCount).put("cachedTextLength", cachedTextLength)
        .put("source", source).put("author", author).put("bookmarks", JSONArray(bookmarks.map { JSONObject().put("offset", it.offset).put("label", it.label) }))
    companion object {
        fun fromJson(value: JSONObject, summary: Boolean = false): Reading = Reading(value.getString("id"), value.getString("title"), value.getString("text"),
            value.optString("source").takeIf { it.isNotEmpty() && it != "null" }, value.optString("author").takeIf { it.isNotEmpty() && it != "null" }, value.optInt("position", 0),
            (value.optJSONArray("bookmarks") ?: JSONArray()).let { array -> List(array.length()) { index -> array.getJSONObject(index).let { ReadingBookmark(it.getInt("offset"), it.getString("label")) } } },
            value.optDouble("createdAt", System.currentTimeMillis() / 1000.0),
            value.optJSONArray("chapters")?.let { array -> List(array.length()) { index -> array.getJSONObject(index).let { ReadingChapter(it.getString("id"), it.getString("title"), it.getInt("offset")) } } }.orEmpty(),
            if (value.has("cachedWordCount") && !value.isNull("cachedWordCount")) value.getInt("cachedWordCount") else null,
            if (value.has("cachedTextLength") && !value.isNull("cachedTextLength")) value.getInt("cachedTextLength") else null).validated(summary)
    }
}
data class ReadingPassage(val text: String, val start: Int, val end: Int)
data class WordRange(val start: Int, val end: Int)
data class SpokenWord(val offset: Int, val length: Int, val start: Double, val end: Double)
data class SpokenClip(val wav: ByteArray, val words: List<SpokenWord>, val duration: Double)

object ReadingText {
    fun passages(reading: Reading, limit: Int = 420): List<ReadingPassage> {
        if (reading.chapters.isEmpty()) return passages(reading.text, limit)
        return reading.chapters.flatMapIndexed { index, chapter ->
            val end = reading.chapters.getOrNull(index + 1)?.offset ?: reading.text.length
            passages(reading.text.substring(chapter.offset, end), limit).map { ReadingPassage(it.text, it.start + chapter.offset, it.end + chapter.offset) }
        }
    }
    // Kotlin Regex.findAll restarts Android's ICU matcher for each result,
    // repeatedly copying a novel-sized input. Scan words once instead.
    fun wordCount(text: String): Int { var count = 0; var inside = false
        text.forEach { unit -> if (unit.isWhitespace()) inside = false else if (!inside) { count++; inside = true } }; return count
    }
    fun words(text: String): List<WordRange> = buildList {
        var start = -1
        text.forEachIndexed { index, unit -> if (unit.isWhitespace()) { if (start >= 0) { add(WordRange(start, index)); start = -1 } } else if (start < 0) start = index }
        if (start >= 0) add(WordRange(start, text.length))
    }
    fun passages(text: String, limit: Int = 420): List<ReadingPassage> {
        val matcher = java.util.regex.Pattern.compile("(?<=[.!?])\\s+|\\n\\s*\\n").matcher(text)
        val ends = buildList { while (matcher.find()) add(matcher.end()); add(text.length) }
        val result = mutableListOf<ReadingPassage>(); var start = 0; var pending = 0
        fun append(lower: Int, upper: Int) {
            var a = lower; var b = upper
            while (a < b && text[a].isWhitespace()) a++
            while (b > a && text[b - 1].isWhitespace()) b--
            if (b > a) result += ReadingPassage(text.substring(a, b), a, b)
        }
        ends.forEach { end ->
            if (end - start > limit && pending > start) { append(start, pending); start = pending }
            while (end - start > limit) {
                val space = (start until start + limit).lastOrNull { text[it].isWhitespace() }
                var cut = if (space != null && space > start + limit / 3) space else start + limit
                if (text[cut - 1].isHighSurrogate()) cut--
                append(start, cut); start = cut
            }
            pending = end
        }
        append(start, pending); return result
    }
    fun windows(reading: Reading, passages: List<ReadingPassage>, limit: Int = 64000): List<WordRange> {
        val mandatory = (reading.chapters.map { it.offset } + reading.text.length).toSet()
        val boundaries = (passages.map { it.start } + mandatory).distinct().sorted()
        val result = mutableListOf<WordRange>(); var lower = 0; var previous = 0
        fun append(end: Int) { if (end > lower) { result += WordRange(lower, end); lower = end } }
        boundaries.forEach { boundary ->
            if (boundary - lower > limit && previous > lower) append(previous)
            while (boundary - lower > limit) { var end = lower + limit; if (reading.text[end - 1].isHighSurrogate()) end--; append(end) }
            if (boundary in mandatory) append(boundary)
            previous = boundary
        }
        return result
    }
    fun window(reading: Reading, offset: Int): WordRange = windows(reading, passages(reading)).lastOrNull { it.start <= offset } ?: WordRange(0, 0)
    fun estimatedWords(text: String, duration: Double): List<SpokenWord> {
        val words = words(text); val total = words.sumOf { (it.end - it.start).coerceAtLeast(1) }.coerceAtLeast(1); var elapsed = 0
        return words.map { word -> val start = duration * elapsed / total; elapsed += (word.end - word.start).coerceAtLeast(1); SpokenWord(word.start, word.end - word.start, start, duration * elapsed / total) }
    }
    fun backup(readings: List<Reading>): ByteArray = JSONObject().put("format", "openread-mobile-library-v1").put("documents", JSONArray(readings.map { it.json() })).toString(2).toByteArray()
    fun restore(data: ByteArray): List<Reading> {
        require(data.size <= 25 * 1024 * 1024) { "Choose a backup under 25 MB." }
        val json = JSONObject(data.toString(Charsets.UTF_8)); require(json.getString("format") == "openread-mobile-library-v1") { "This is not a mobile OpenRead backup." }
        val array = json.getJSONArray("documents"); require(array.length() <= 200)
        val readings = List(array.length()) { Reading.fromJson(array.getJSONObject(it)) }
        require(readings.map { it.id }.distinct().size == readings.size) { "This backup contains duplicate readings." }; return readings
    }
}
