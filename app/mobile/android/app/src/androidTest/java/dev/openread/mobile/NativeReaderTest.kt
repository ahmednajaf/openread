package dev.openread.mobile

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class NativeReaderTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun fixture(name: String): File = File(context.cacheDir, name).apply { writeBytes(instrumentation.context.assets.open(name).use { it.readBytes() }) }
    @Test fun englishPronunciationPreservesClausePunctuation() {
        val models = ModelStore(context)
        models.preparePronunciation()
        val ipa = NativePhonemizer.phonemize(models.root.path, "Hello, world! Are you ready? Yes; let's begin.")
        assertEquals(",!?;.", ipa.filter { it in ",!?;." })
        assertTrue(ipa.contains("ˈ"))
    }
    @Test fun importsPreserveWordsAndReadingOrder() = runBlocking {
        val importer = DocumentImporter(context, ModelStore(context))
        val article = importer.file(fixture("article.html"))
        assertTrue(article.text.contains("linked words")); assertFalse(article.text.contains("4 minutes")); assertFalse(article.text.contains("Skip navigation")); assertFalse(article.text.contains("Subscribe now"))
        assertTrue(article.text.indexOf("First point.") < article.text.indexOf("Second point."))
        val book = importer.file(fixture("ordered.epub"))
        assertTrue(book.text.indexOf("first chapter") < book.text.indexOf("second chapter"))
        assertTrue(importer.file(fixture("paragraphs.docx")).text.contains("The first paragraph.\n\nThe second paragraph."))
    }
    @Test fun externalEntitiesAreRejectedBeforeParsing() {
        val importer = DocumentImporter(context, ModelStore(context))
        assertThrows(IllegalArgumentException::class.java) { importer.file(fixture("external.docx")) }
    }
    @Test fun imageOCRWorksOffline() {
        val models = ModelStore(context); assumeTrue(models.installed(true))
        val image = android.graphics.Bitmap.createBitmap(1200, 300, android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(image); canvas.drawColor(android.graphics.Color.WHITE)
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textSize = 66f; color = android.graphics.Color.BLACK }
        canvas.drawText("Read these words clearly.", 50f, 150f, paint)
        val file = File(context.cacheDir, "ocr-test.png")
        try {
            file.outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            assertTrue(DocumentImporter(context, models).file(file).text.contains("Read these words", ignoreCase = true))
        } finally { image.recycle(); file.delete() }
    }
    @Test fun foregroundReaderAdvancesHighlightsAndPauseClearsThem() = runBlocking {
        val runtime = (context.applicationContext as OpenReadApplication).reader
        assumeTrue(runtime.models.installed())
        try {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                runtime.open(Reading(title = "Playback check", text = "Tell me, Muse, the story of that resourceful man who wandered far and wide."))
                runtime.command("play")
            }
            val seen = mutableSetOf<Int>(); val deadline = System.currentTimeMillis() + 20_000
            while (seen.size < 3 && System.currentTimeMillis() < deadline && runtime.state.value.error == null) {
                kotlinx.coroutines.delay(50); runtime.state.value.highlight?.let { seen += it.start }
            }
            assertNull(runtime.state.value.error); assertTrue("Background reader must advance through source words", seen.size >= 3)
            // A bare intent from another app must not control the private reading.
            context.startService(android.content.Intent(context, ReadingService::class.java).setAction("stop"))
            kotlinx.coroutines.delay(100); assertTrue(runtime.state.value.playing)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { runtime.command("pause") }
            kotlinx.coroutines.delay(100)
            assertFalse(runtime.state.value.playing); assertNull(runtime.state.value.highlight)
        } finally { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { runtime.command("stop") } }
    }
    @Test fun exportedAudioPlaysAndAdvancesWithMedia3() = runBlocking {
        val app = context.applicationContext as OpenReadApplication
        assumeTrue(app.reader.models.installed())
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { app.reader.open(Reading(title = "Audio export check", text = "Read these words slowly. ".repeat(20))) }
        val file = app.reader.exportAudio { _, _ -> }
        val bytes = file.readBytes(); val header = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        assertEquals("RIFF", bytes.copyOfRange(0, 4).toString(Charsets.US_ASCII)); assertEquals(bytes.size - 44, header.getInt(40))
        var player: androidx.media3.exoplayer.ExoPlayer? = null
        try {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                player = androidx.media3.exoplayer.ExoPlayer.Builder(context).build().apply { setMediaItem(androidx.media3.common.MediaItem.fromUri(android.net.Uri.fromFile(file))); prepare(); play() }
            }
            val deadline = System.currentTimeMillis() + 8000
            var position = 0L
            while (position < 200 && System.currentTimeMillis() < deadline) {
                kotlinx.coroutines.delay(50)
                position = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { player!!.currentPosition }
            }
            assertTrue("Exported audio must play, not just produce bytes", position >= 200)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { player!!.pause(); assertFalse(player!!.isPlaying) }
        } finally { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { player?.release() }; file.delete() }
    }
    @Test fun localKittenProducesAudibleAudioWithSourceRanges() = runBlocking {
        val models = ModelStore(context); assumeTrue("Install the voice pack before running inference checks", models.installed())
        val engine = KittenEngine(models); engine.prepare(download = false)
        for ((voice, text) in listOf("Kiki" to "Tell me, Muse, the story of that resourceful man.", "Rosie" to "I", "Jasper" to "Read these words. Read these words.")) {
            val clip = engine.generate(text, voice)
            assertTrue(clip.duration > .02); assertTrue(clip.wav.size > 44)
            assertTrue(clip.wav.drop(44).any { it != 0.toByte() })
            assertEquals(ReadingText.words(text).size, clip.words.size)
            assertTrue(clip.words.all { it.start >= 0 && it.end > it.start && it.end <= clip.duration && it.offset + it.length <= text.length })
        }
    }
}
