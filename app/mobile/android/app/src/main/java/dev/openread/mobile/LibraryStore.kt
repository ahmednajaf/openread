package dev.openread.mobile

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.content.ContentValues
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

class LibraryStore(context: Context) : SQLiteOpenHelper(context, "openread-library.db", null, 1) {
    private val mutable = MutableStateFlow<List<Reading>>(emptyList())
    val readings = mutable.asStateFlow()
    var recoveryError: String? = null; private set
    init { runCatching { refresh() }.onFailure { recoveryError = "Your library could not be opened. Its database has been kept for recovery." } }
    override fun onCreate(database: SQLiteDatabase) { database.execSQL("CREATE TABLE readings (id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL, created REAL NOT NULL)") }
    override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}
    @Synchronized fun save(reading: Reading) {
        check(recoveryError == null) { recoveryError.orEmpty() }
        reading.validated()
        val next = mutable.value.filterNot { it.id == reading.id } + reading
        require(next.size <= 200 && ReadingText.backup(next).size <= 25 * 1024 * 1024) { "Your library is full. Export a backup and remove a reading first." }
        writableDatabase.insertWithOnConflict("readings", null, ContentValues().apply { put("id", reading.id); put("document", reading.json().toString()); put("created", reading.createdAt) }, SQLiteDatabase.CONFLICT_REPLACE)
        refresh()
    }
    @Synchronized fun remove(id: String) { check(recoveryError == null) { recoveryError.orEmpty() }; writableDatabase.delete("readings", "id=?", arrayOf(id)); refresh() }
    @Synchronized fun position(id: String, offset: Int) { mutable.value.firstOrNull { it.id == id }?.let { if (it.position != offset) save(it.copy(position = offset)) } }
    @Synchronized fun restore(data: ByteArray) {
        check(recoveryError == null) { recoveryError.orEmpty() }
        val entries = ReadingText.restore(data)
        val next = (mutable.value.associateBy { it.id } + entries.associateBy { it.id }).values.toList()
        require(next.size <= 200 && ReadingText.backup(next).size <= 25 * 1024 * 1024) { "The merged backup exceeds the library limit." }
        val db = writableDatabase; db.beginTransaction()
        try {
            entries.forEach { reading -> db.insertWithOnConflict("readings", null, ContentValues().apply { put("id", reading.id); put("document", reading.json().toString()); put("created", reading.createdAt) }, SQLiteDatabase.CONFLICT_REPLACE) }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
        refresh()
    }
    fun backup(): ByteArray = ReadingText.backup(mutable.value)
    @Synchronized private fun refresh() {
        readableDatabase.query("readings", arrayOf("document"), null, null, null, null, "created DESC").use { cursor -> mutable.value = buildList { while (cursor.moveToNext()) add(Reading.fromJson(JSONObject(cursor.getString(0)))) } }
    }
}
