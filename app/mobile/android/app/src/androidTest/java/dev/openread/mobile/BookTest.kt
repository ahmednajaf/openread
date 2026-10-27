package dev.openread.mobile

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class BookTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun fixture(name: String) = File(context.cacheDir, name).apply { writeBytes(instrumentation.context.assets.open(name).use { it.readBytes() }) }
    @Test fun fragmentChapterLabelsKeepExactUnicodeLocations() {
        val book = DocumentImporter(context, ModelStore(context)).file(fixture("chapters.epub"))
        assertEquals(listOf("First & foremost", "Second chapter", "Final chapter"), book.chapters.map { it.title })
        assertTrue(book.text.substring(book.chapters[1].offset).startsWith("Second heading"))
        assertFalse(book.text.contains("supplementary")); assertFalse(book.text.contains("Do not speak the metadata"))
    }
    @Test fun completeBookPersistsOutsideCursorWindowAndRoundTripsZipBackup() {
        val book = DocumentImporter(context, ModelStore(context)).file(fixture("full-book.epub"))
        assertTrue(book.text.length > 2_000_000); assertEquals(24, book.chapters.size)
        val library = LibraryStore(context)
        try {
            library.save(book)
            assertEquals("", library.readings.value.first { it.id == book.id }.text)
            library.position(book.id, book.chapters.last().offset)
            val loaded = library.load(book.id)
            assertEquals(book.text, loaded.text); assertEquals(book.chapters.last().offset, loaded.position)
            val passages = ReadingText.passages(loaded)
            assertTrue(passages.any { it.start == loaded.chapters.last().offset })
            val window = ReadingText.window(loaded, loaded.position); assertTrue(window.end - window.start <= 64000)
            val windows = ReadingText.windows(loaded, passages)
            assertTrue(windows.size > loaded.chapters.size)
            var previous = 0
            windows.forEach { assertEquals(previous, it.start); assertTrue(it.end - it.start <= 64000); previous = it.end }
            assertEquals(loaded.text.length, previous)
            val backup = library.backup()
            try { library.remove(book.id); library.restore(backup.readBytes()); assertEquals(book.text, library.load(book.id).text); assertEquals(book.chapters, library.load(book.id).chapters) } finally { backup.delete() }
        } finally { library.remove(book.id); library.close() }
    }
    @Test fun legacyShelfMigratesAndInvalidBackupCannotPartiallyReplaceIt() {
        val root = File(context.cacheDir, "book-migration-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val file = File(root, "library.db")
        val original = Reading(title = "Existing book", text = "Keep this book and its place.", position = 5, bookmarks = listOf(ReadingBookmark(5, "My place")))
        android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            db.execSQL("CREATE TABLE readings (id TEXT PRIMARY KEY NOT NULL, document TEXT NOT NULL, created REAL NOT NULL)")
            db.execSQL("INSERT INTO readings VALUES (?, ?, ?)", arrayOf(original.id, original.json().toString(), original.createdAt)); db.version = 1
        }
        val books = File(root, "Books"); val library = LibraryStore(context, file.path, books)
        try {
            assertNull(library.recoveryError); assertEquals(original, library.load(original.id))
            val backup = File(root, "invalid.zip")
            java.util.zip.ZipOutputStream(backup.outputStream()).use { zip ->
                for ((name, text) in listOf("readings/0.json" to Reading(title = "Incoming", text = "New text.").json().toString(), "readings/1.json" to "{}")) {
                    zip.putNextEntry(java.util.zip.ZipEntry(name)); zip.write(text.toByteArray()); zip.closeEntry()
                }
            }
            assertTrue(runCatching { library.restore(backup) }.isFailure)
            assertEquals(original, library.load(original.id)); assertEquals(1, library.readings.value.size)
            assertEquals(1, books.listFiles()?.size)
        } finally { library.close(); root.deleteRecursively() }
    }
    @Test fun qwenRunsOnAndroidWithRealModelWeights() = runBlocking {
        val engine = QwenEngine(context); assumeTrue(engine.installed("expressive"))
        try {
            val text = "Tell me, Muse, the story of that resourceful man."
            val audio = engine.generate(text, "qwen:ryan", "Warm, natural storytelling.")
            assertTrue(audio.duration > 1); assertTrue(audio.wav.size > 44); assertEquals(ReadingText.words(text).size, audio.words.size)
            val cached = engine.generate(text, "qwen:ryan", "Warm, natural storytelling.")
            assertArrayEquals(audio.wav, cached.wav)
        } finally { engine.release() }
    }
    @Test fun voiceSamplesDecodeLocallyAndQuickCloningProducesSpeech() = runBlocking {
        val engine = QwenEngine(context); assumeTrue(engine.installed("clone"))
        val sample = File(engine.root, "test-reference.wav"); assumeTrue(sample.exists())
        try {
            val profile = engine.clone("Synthetic test narrator", "", android.net.Uri.fromFile(sample), true)
            try {
                val clip = engine.generate("A natural voice. A little more focus.", "qwen:clone:${profile.id}", "Warm storytelling")
                assertTrue(clip.duration > 1); assertTrue(clip.wav.size > 44)
                assertTrue(engine.profiles().any { it.id == profile.id })
            } finally { engine.remove(profile.id) }
        } finally { engine.release() }
    }

}
