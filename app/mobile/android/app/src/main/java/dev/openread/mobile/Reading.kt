package dev.openread.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class ReadingBookmark(val offset: Int, val label: String)
data class Reading(
    val id: String = UUID.randomUUID().toString(), val title: String, val text: String,
    val source: String? = null, val author: String? = null, val position: Int = 0,
    val bookmarks: List<ReadingBookmark> = emptyList(), val createdAt: Double = System.currentTimeMillis() / 1000.0
) {
    val wordCount get() = ReadingText.words(text).size
    fun validated(): Reading {
        require(id.isNotEmpty() && id.length <= 80 && title.isNotBlank() && title.length <= 240 && text.isNotBlank() && text.length <= 250_000 &&
            (source?.length ?: 0) <= 1000 && position in 0..text.length && bookmarks.size <= 200 &&
            bookmarks.all { it.offset in 0..text.length && it.label.length <= 160 }) { "This reading or backup is invalid. Nothing was imported." }
        return this
    }
    fun json(): JSONObject = JSONObject().put("id", id).put("title", title).put("text", text).put("position", position).put("createdAt", createdAt)
        .put("source", source).put("author", author).put("bookmarks", JSONArray(bookmarks.map { JSONObject().put("offset", it.offset).put("label", it.label) }))
    companion object {
        fun fromJson(value: JSONObject): Reading = Reading(value.getString("id"), value.getString("title"), value.getString("text"),
            value.optString("source").takeIf { it.isNotEmpty() && it != "null" }, value.optString("author").takeIf { it.isNotEmpty() && it != "null" }, value.optInt("position", 0),
            (value.optJSONArray("bookmarks") ?: JSONArray()).let { array -> List(array.length()) { index -> array.getJSONObject(index).let { ReadingBookmark(it.getInt("offset"), it.getString("label")) } } },
            value.optDouble("createdAt", System.currentTimeMillis() / 1000.0)).validated()
    }
}
data class ReadingPassage(val text: String, val start: Int, val end: Int)
data class WordRange(val start: Int, val end: Int)
data class SpokenWord(val offset: Int, val length: Int, val start: Double, val end: Double)
data class SpokenClip(val wav: ByteArray, val words: List<SpokenWord>, val duration: Double)

object ReadingText {
    fun words(text: String): List<WordRange> = Regex("\\S+").findAll(text).map { WordRange(it.range.first, it.range.last + 1) }.toList()
    fun passages(text: String, limit: Int = 420): List<ReadingPassage> {
        val ends = Regex("(?<=[.!?])\\s+|\\n\\s*\\n").findAll(text).map { it.range.last + 1 }.toList() + text.length
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
