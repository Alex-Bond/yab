package dev.yab.nativefeatures

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class TranslationRulesTest {
    @Test fun hostRulesMatchIosWithoutGrantingOtherSchemesOrSiblingSites() {
        assertEquals("example.com", translationHost("https://WWW.Example.COM/article"))
        assertEquals("news.example.com", translationHost("https://news.example.com/article"))
        assertNull(translationHost("moz-extension://example.com/options.html"))
        assertNull(translationHost("file:///private.html"))
    }
    @Test fun onlyPublicRulesSurviveRecreationAndPrivateCannotEnterTheFile() {
        val directory = Files.createTempDirectory("yab-translation-rules").toFile()
        val file = directory.resolve("rules.json")
        try {
            val rules = FileTranslationRules(file)
            rules.setSource("example.com", false, "pt")
            val before = file.readText()
            rules.setSource("private-secret.invalid", true, "de")
            rules.setSource("example.com", true, "fr")
            assertEquals(before, file.readText())
            assertEquals("fr", rules.source("example.com", true))
            val restored = FileTranslationRules(file)
            assertEquals("pt", restored.source("example.com", false))
            assertNull(restored.source("example.com", true))
            assertNull(restored.source("private-secret.invalid", true))
            restored.setSource("example.com", false, null)
            assertNull(FileTranslationRules(file).source("example.com", false))
        } finally { file.delete(); directory.resolve("rules.json.pending").delete(); directory.delete() }
    }
}
