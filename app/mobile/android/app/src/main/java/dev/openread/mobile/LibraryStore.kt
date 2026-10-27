package dev.openread.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.content.ContentValues
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** SQLite stores the shelf, not whole novels in a CursorWindow. Text lives in bounded files. */
class LibraryStore(private val context: Context, databaseName: String = "openread-library.db", books: File = File(context.noBackupFilesDir, "Books")) : SQLiteOpenHelper(context, databaseName, null, 2) {
    private val root = books.apply { mkdirs() }
    private val mutable = MutableStateFlow<List<Reading>>(emptyList())
    val readings = mutable.asStateFlow()
    var recoveryError: String? = null; private set
    init { runCatching { refresh() }.onFailure { recoveryError = "Your library could not be opened. Its files have been kept for recovery." } }
    override fun onCreate(database: SQLiteDatabase) { database.execSQL("CREATE TABLE readings (id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL, created REAL NOT NULL)") }
    override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        database.query("readings", arrayOf("id", "document"), null, null, null, null, null).use { cursor ->
            while (cursor.moveToNext()) { val reading = Reading.fromJson(JSONObject(cursor.getString(1))); val stored = store(reading)
                database.update("readings", ContentValues().apply { put("document", stored.toString()) }, "id=?", arrayOf(reading.id)) }
        }
    }
    private fun stored(id: String): JSONObject? = readableDatabase.query("readings", arrayOf("document"), "id=?", arrayOf(id), null, null, null).use { cursor -> if (cursor.moveToFirst()) JSONObject(cursor.getString(0)) else null }
    @Synchronized fun load(id: String): Reading {
        val entry = requireNotNull(stored(id)); val reading = Reading.fromJson(entry.getJSONObject("reading"), true)
        val folder = entry.getString("folder"); UUID.fromString(folder); val count = entry.getInt("chunks"); require(count in 1..1000)
        val text = StringBuilder()
        repeat(count) { index -> val file = File(root, "$folder/$index.txt"); require(file.length() <= 300_000); text.append(file.readText()); require(text.length <= 20_000_000) }
        val source = text.toString(); require(hash(source) == entry.getString("hash") && source.length == reading.textLength) { "This book's text failed its integrity check. Its files have been kept." }
        return reading.copy(text = source).validated()
    }
    @Synchronized fun save(reading: Reading) {
        check(recoveryError == null) { recoveryError.orEmpty() }
        val old = stored(reading.id)
        val entry = if (old != null && (reading.text.isEmpty() || hash(reading.text) == old.getString("hash"))) {
            val summary = Reading.fromJson(old.getJSONObject("reading"), true).copy(position = reading.position, bookmarks = reading.bookmarks).validated(true)
            old.put("reading", summary.json())
        } else store(reading)
        try {
        require(mutable.value.any { it.id == reading.id } || mutable.value.size < 200) { "Your library holds 200 books. Export a backup and remove one first." }
        write(writableDatabase, entry); refresh()
        old?.takeIf { it.getString("folder") != entry.getString("folder") }?.let(::discard)
        } catch (error: Throwable) { if (stored(reading.id)?.optString("folder") != entry.getString("folder")) discard(entry); throw error }
    }
    @Synchronized fun remove(id: String) {
        check(recoveryError == null) { recoveryError.orEmpty() }; val old = stored(id)
        writableDatabase.delete("readings", "id=?", arrayOf(id)); refresh()
        old?.optString("folder")?.takeIf { runCatching { UUID.fromString(it) }.isSuccess }?.let { File(root, it).deleteRecursively() }
    }
    @Synchronized fun position(id: String, offset: Int) { mutable.value.firstOrNull { it.id == id }?.let { if (it.position != offset) save(it.copy(position = offset)) } }
    @Synchronized fun restore(data: ByteArray) {
        require(data.size <= 500 * 1024 * 1024)
        val file = File.createTempFile("openread-backup-", ".zip", context.cacheDir)
        try { file.writeBytes(data); restore(file) } finally { file.delete() }
    }
    @Synchronized fun restore(file: File) {
        require(file.length() <= 500L * 1024 * 1024) { "Choose a backup under 500 MB." }
        val input = file.inputStream().buffered(); input.mark(4); val first = input.read(); val second = input.read(); input.reset()
        val incoming = mutableListOf<JSONObject>(); val ids = mutableSetOf<String>(); var expanded = 0L
        fun add(reading: Reading) { require(ids.add(reading.id) && ids.size <= 200) { "This backup contains duplicate or too many readings." }; incoming += store(reading) }
        try {
        if (first == 0x50 && second == 0x4b) {
            ZipInputStream(input).use { zip -> while (true) { val entry = zip.nextEntry ?: break
                require(!entry.isDirectory && entry.name.startsWith("readings/") && entry.name.endsWith(".json")) { "This is not an OpenRead backup." }
                val output = java.io.ByteArrayOutputStream(); val block = ByteArray(64 * 1024)
                while (true) { val count = zip.read(block); if (count < 0) break; expanded += count; require(expanded <= 500L * 1024 * 1024 && output.size() + count <= 100 * 1024 * 1024) { "This backup expands beyond its import limit." }; output.write(block, 0, count) }
                add(Reading.fromJson(JSONObject(output.toString("UTF-8")))); zip.closeEntry()
            } }
        } else input.use { require(file.length() <= 25L * 1024 * 1024); ReadingText.restore(it.readBytes()).forEach(::add) }
        require((mutable.value.map { it.id } + ids).distinct().size <= 200)
        // Only publish database rows after every member has validated and its fresh text files exist.
        val replaced = incoming.mapNotNull { stored(it.getJSONObject("reading").getString("id")) }
        val db = writableDatabase; db.beginTransaction()
        try { incoming.forEach { write(db, it) }; db.setTransactionSuccessful() } finally { db.endTransaction() }
        refresh(); replaced.forEach(::discard)
        } finally { input.close(); incoming.filter { stored(it.getJSONObject("reading").getString("id"))?.optString("folder") != it.getString("folder") }.forEach(::discard) }
    }
    private fun discard(entry: JSONObject) { entry.optString("folder").takeIf { runCatching { UUID.fromString(it) }.isSuccess }?.let { File(root, it).deleteRecursively() } }
    @Synchronized fun backup(): File {
        val destination = File(context.cacheDir, "exports/OpenRead-library-${System.currentTimeMillis()}.zip").apply { parentFile?.mkdirs() }
        try { ZipOutputStream(destination.outputStream()).use { zip -> var total = 0L
            mutable.value.forEachIndexed { index, reading -> val body = load(reading.id).json().toString().toByteArray(); total += body.size; require(total <= 500L * 1024 * 1024) { "This backup exceeds 500 MB." }; zip.putNextEntry(ZipEntry("readings/$index.json")); zip.write(body); zip.closeEntry() }
        }; return destination } catch (error: Throwable) { destination.delete(); throw error }
    }
    private fun write(db: SQLiteDatabase, entry: JSONObject) { val reading = Reading.fromJson(entry.getJSONObject("reading"), true); check(db.insertWithOnConflict("readings", null, ContentValues().apply { put("id", reading.id); put("document", entry.toString()); put("created", reading.createdAt) }, SQLiteDatabase.CONFLICT_REPLACE) != -1L) { "Your reading could not be saved." } }
    private fun hash(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun store(source: Reading): JSONObject {
        val reading = source.validated(); val folder = UUID.randomUUID().toString(); val directory = File(root, folder).apply { mkdirs() }
        try {
        var offset = 0; var count = 0
        while (offset < reading.text.length) { var end = minOf(reading.text.length, offset + 64000); if (end < reading.text.length && reading.text[end - 1].isHighSurrogate()) end--; File(directory, "$count.txt").writeText(reading.text.substring(offset, end)); offset = end; count++ }
        val summary = reading.copy(text = "", cachedWordCount = reading.wordCount, cachedTextLength = reading.text.length)
        return JSONObject().put("reading", summary.json()).put("folder", folder).put("chunks", count).put("hash", hash(reading.text))
        } catch (error: Throwable) { directory.deleteRecursively(); throw error }
    }
    @Synchronized private fun refresh() {
        readableDatabase.query("readings", arrayOf("document"), null, null, null, null, "created DESC").use { cursor -> mutable.value = buildList { while (cursor.moveToNext()) add(Reading.fromJson(JSONObject(cursor.getString(0)).getJSONObject("reading"), true)) } }
    }
}
