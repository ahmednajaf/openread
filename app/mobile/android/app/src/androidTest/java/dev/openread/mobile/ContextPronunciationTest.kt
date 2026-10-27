package dev.openread.mobile

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ContextPronunciationTest {
    @Test fun sharedTokenizerAndRealContextInferencePreserveTenseAndPunctuation() {
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val models = ModelStore(context); models.preparePronunciation()
        val fixture = JSONObject(instrumentation.context.assets.open("pronunciation.json").bufferedReader().use { it.readText() })
        ContextPronunciation(File(models.root,"pronunciation")).use { model ->
            val tokens = fixture.getJSONArray("tokenization")
            for (i in 0 until tokens.length()) { val row = tokens.getJSONObject(i); val expected = row.getJSONArray("ids"); assertArrayEquals(row.getString("text"),LongArray(expected.length()) { expected.getLong(it) },model.tokenIDs(row.getString("text"))) }
            val decisions = fixture.getJSONArray("decisions")
            for (i in 0 until decisions.length()) { val row = decisions.getJSONObject(i); assertEquals(row.getString("text"),row.getString("replacements"),model.replacements(row.getString("text"))) }
            val source = "Yesterday, I read the book from cover to cover."
            assertTrue(NativePhonemizer.phonemizeContext(models.root.path,source,model.replacements(source)).contains("ˈɹɛd"))
            val present = "I read the book every morning."
            assertTrue(NativePhonemizer.phonemizeContext(models.root.path,present,model.replacements(present)).contains("ɹˈiːd"))
            val punctuation = "Please close the door; the shop is close by."
            val phones = NativePhonemizer.phonemizeContext(models.root.path,punctuation,model.replacements(punctuation))
            assertTrue(phones.contains("ˈkloʊz")); assertTrue(phones.contains(";")); assertTrue(phones.endsWith("."))
        }
    }
}
