package dev.yab.nativefeatures

import org.junit.Assert.*
import org.junit.Test

class TranslationLanguageTest {
    @Test fun regionalAndroidLocalesResolveToSupportedModelLanguages() {
        assertEquals("en", translationLanguage("en-US"))
        assertEquals("pt", translationLanguage("pt-BR"))
        assertEquals("zh", translationLanguage("zh-Hans-CN"))
        assertEquals("he", translationLanguage("he-IL"))
        assertEquals("he", translationLanguage("iw-IL"))
    }
    @Test fun existingBaseCodesAndUnsupportedLanguagesRetainTheirMeaning() {
        assertEquals("en", translationLanguage("en"))
        assertNull(translationLanguage("xx-ZZ"))
        assertNull(translationLanguage("und"))
    }
}
