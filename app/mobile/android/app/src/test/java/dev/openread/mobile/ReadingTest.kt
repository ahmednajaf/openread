package dev.openread.mobile

import org.junit.Assert.*
import org.junit.Test

class ReadingTest {
    @Test fun unicodeRangesAndRepeatedWordsAreNotLost() {
        val text = "🙂 I\n\nA title\n\nOne repeated phrase. One repeated phrase.\n\n" + "🌊 words ".repeat(100)
        val passages = ReadingText.passages(text)
        assertTrue(passages.size > 1)
        passages.forEach { assertEquals(it.text, text.substring(it.start, it.end)); assertTrue(it.text.length <= 420) }
        assertEquals(text.filterNot { it.isWhitespace() }, passages.joinToString("") { it.text }.filterNot { it.isWhitespace() })
        val words = ReadingText.estimatedWords("🌊 Read this. Read this.", 4.0)
        assertEquals(3, words[1].offset); assertEquals(4.0, words.last().end, 0.00001)
        assertTrue(words.all { it.end > it.start })
    }
    @Test fun invalidBackupCannotPartiallyRestore() {
        val reading = Reading(title = "A reading", text = "Keep this text.")
        assertEquals(reading, ReadingText.restore(ReadingText.backup(listOf(reading))).single())
        assertThrows(IllegalArgumentException::class.java) { ReadingText.restore(ReadingText.backup(listOf(reading.copy(position = -1)))) }
        assertThrows(IllegalArgumentException::class.java) { ReadingText.restore(ReadingText.backup(listOf(reading, reading))) }
    }
}
