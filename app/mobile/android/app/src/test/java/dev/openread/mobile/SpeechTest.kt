package dev.openread.mobile
import org.junit.Assert.*
import org.junit.Test

class SpeechTest {
    @Test fun chunksKeepEveryWholeWordAndPunctuation() {
        val ipa = "həlˈoʊ wˈɜːld! ".repeat(80)
        val chunks = KittenEngine.speechChunks(ipa)
        assertTrue(chunks.size > 1)
        assertTrue(chunks.all { KittenEngine.tokens(it).size <= 400 })
        assertEquals(ipa.trim().split(Regex("\\s+")), chunks.joinToString(" ").split(Regex("\\s+")))
    }
    @Test fun tailTrimmingPreservesAudibleSamples() {
        val audible = FloatArray(7200) { 0.2f }
        assertArrayEquals(audible, KittenEngine.trimSilence(audible), 0f)
        val padded = audible + FloatArray(9000)
        val trimmed = KittenEngine.trimSilence(padded)
        assertArrayEquals(audible, trimmed.take(audible.size).toFloatArray(), 0f)
        assertTrue(trimmed.size >= audible.size + 2400)
        assertTrue(trimmed.size >= padded.size - 4800)
    }
}
