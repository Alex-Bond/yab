package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.engine.ReaderPreferencesStore
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ReaderPreferencesTest {
    @Test fun originalDefaultsAndAllSixCurrentPhonePayloadsAreExact() {
        val original = ReaderPreferences()
        assertEquals(ReaderTheme.ORIGINAL, original.theme); assertEquals(ReaderMode.AUTO, original.mode); assertFalse(original.wide)
        assertEquals(listOf(14, 15, 16, 17, 18, 20, 22, 24, 26, 28), ReaderLook.sizes)
        val expected = listOf(
            listOf("#ffffff", "#1d1d1f", "#1c1c1e", "#e8e8ea", 18, 1.6, 400, 0.0, 0.0, 38.0, false, ""),
            listOf("#f2f1ee", "#5a5852", "#111111", "#8e8b85", 18, 1.7, 400, 0.0, 0.0, 38.0, false, ReaderFont.NEW_YORK.css),
            listOf("#f7f3ea", "#2a2620", "#252320", "#ddd6c8", 18, 1.7, 400, 0.0, 0.0, 38.0, true, ReaderFont.CHARTER.css),
            listOf("#ffffff", "#000000", "#000000", "#ffffff", 20, 1.55, 700, .01, 0.0, 38.0, false, ReaderFont.SYSTEM.css),
            listOf("#efe4cf", "#4a3b28", "#3a332b", "#ebe0cd", 20, 1.75, 400, 0.0, .04, 38.0, false, ReaderFont.IOWAN.css),
            listOf("#fffdf6", "#1d1b16", "#17160f", "#f2edd9", 20, 1.8, 500, 0.0, 0.0, 41.8, false, ReaderFont.ATHELAS.css))
        ReaderTheme.entries.forEachIndexed { index, theme ->
            val p = original.copy(theme = theme).payload
            assertEquals(expected[index], listOf(p.day.background, p.day.text, p.night.background, p.night.text,
                p.size, p.line, p.weight, p.letter, p.word, p.width, p.justify, p.font))
        }
    }
    @Test fun themeEditsRoundTripIndependentlyAndReturningToPresetDeletesOnlyThatEdit() {
        val paper = ReaderPreferences(theme = ReaderTheme.PAPER).step(2).change { it.copy(margins = 10, line = 1.95, font = ReaderFont.PALATINO) }
        val calm = paper.copy(theme = ReaderTheme.CALM).change { it.copy(word = 12) }
        assertEquals(22, calm.copy(theme = ReaderTheme.PAPER).look.points); assertEquals(12, calm.look.word)
        val reset = calm.reset(); assertFalse(reset.edited(ReaderTheme.CALM)); assertTrue(reset.edited(ReaderTheme.PAPER))
        val noPaper = reset.copy(theme = ReaderTheme.PAPER).change { ReaderThemeSpec.of(ReaderTheme.PAPER).look }
        assertTrue(noPaper.edits.isEmpty())
    }
    @Test fun textStepsStopAtEndsAndEveryPayloadHasBoundedNumericStyleValues() {
        var prefs = ReaderPreferences()
        repeat(20) { prefs = prefs.step(-1) }; assertEquals(14, prefs.payload.size)
        repeat(30) { prefs = prefs.step(1) }; assertEquals(28, prefs.payload.size)
        val bounded = prefs.change { it.copy(line = Double.NaN, letter = 1000, word = -1, margins = -999) }
        assertEquals(1.6, bounded.look.line, 0.0); assertEquals(10, bounded.look.letter)
        assertEquals(0, bounded.look.word); assertEquals(-30, bounded.look.margins)
        assertEquals(49.4, bounded.payload.width, 0.0)
        assertEquals(62.4, bounded.copy(wide = true).payload.width, 0.0)
    }
    @Test fun phoneColorNormalizationAndReadableFallbackCoverBothGrounds() {
        assertEquals(ReaderColors("#ffffff", "#000000"), ReaderColors("FFFFFF", "#fefefe"))
        assertEquals(ReaderColors("#000000", "#ffffff"), ReaderColors("000000", "#010101"))
        assertEquals("#ffffff", ReaderColors("invalid", "123456").background)
        assertEquals("#171717", ReaderColors("ffffff", "invalid").text)
        assertTrue(ReaderColors.contrast(ReaderColors("#ffffff", "#eeeeee").background, ReaderColors("#ffffff", "#eeeeee").text) >= 4.5)
    }
    @Test fun boldOffUsesThePresetWeightAndAppearanceDoesNotReplacePerThemeEdits() {
        val bold = ReaderPreferences(theme = ReaderTheme.BOLD).change { it.copy(bold = false) }
        assertEquals(700, bold.payload.weight)
        val quiet = ReaderPreferences(theme = ReaderTheme.QUIET).change { it.copy(bold = true) }
        assertEquals(700, quiet.payload.weight); assertEquals(400, quiet.change { it.copy(bold = false) }.payload.weight)
        val dark = quiet.copy(mode = ReaderMode.DARK)
        assertTrue(dark.dark(false)); assertEquals(quiet.edits, dark.edits)
        assertFalse(quiet.copy(mode = ReaderMode.LIGHT).dark(true))
        assertTrue(quiet.dark(true)); assertFalse(quiet.dark(false))
    }
    @Test fun actualLocalStorePersistsThemeModeWideAndEveryThemeEditWithoutOtherDeviceData() {
        val folder = Files.createTempDirectory("reader-prefs-").toFile()
        try {
            val file = File(folder, "reader.json"); val store = ReaderPreferencesStore(file)
            val value = ReaderPreferences(theme = ReaderTheme.PAPER, mode = ReaderMode.DARK, wide = true)
                .change { it.copy(size = 6, margins = 10) }.copy(theme = ReaderTheme.CALM).change { it.copy(word = 20) }
            assertTrue(store.set(value)); assertEquals(value, ReaderPreferencesStore(file).snapshot())
            assertFalse(file.readText().contains("account")); assertFalse(file.readText().contains("tab"))
            assertTrue(store.set(value.reset())); assertFalse(ReaderPreferencesStore(file).snapshot().edited(ReaderTheme.CALM))
            assertTrue(ReaderPreferencesStore(file).snapshot().edited(ReaderTheme.PAPER))
        } finally { folder.deleteRecursively() }
    }
    @Test fun failedDurableWriteDoesNotPublishUnpersistedSettings() {
        val folder = Files.createTempDirectory("reader-prefs-failure-").toFile()
        try {
            val blocker = File(folder, "not-directory").apply { writeText("blocked") }
            val store = ReaderPreferencesStore(File(blocker, "reader.json"))
            assertFalse(store.set(ReaderPreferences(theme = ReaderTheme.FOCUS)))
            assertEquals(ReaderPreferences(), store.snapshot()); assertNotNull(store.error.value)
        } finally { folder.deleteRecursively() }
    }
    @Test fun corruptOrOversizedLocalDataCannotInjectStylesAndThemeAbaStillAdvancesObservedRevision() {
        val folder = Files.createTempDirectory("reader-prefs-invalid-").toFile()
        try {
            val file = File(folder, "reader.json").apply { writeText("{bad}") }
            assertEquals(ReaderPreferences(), ReaderPreferencesStore(file).snapshot())
            file.writeText("x".repeat(65537)); assertEquals(ReaderPreferences(), ReaderPreferencesStore(file).snapshot())
            val store = ReaderPreferencesStore()
            assertTrue(store.set(store.snapshot().copy(theme = ReaderTheme.CALM)))
            assertTrue(store.set(store.snapshot().copy(theme = ReaderTheme.ORIGINAL)))
            assertEquals(ReaderPreferences(), store.snapshot()); assertEquals(2L, store.themeChanges.value)
        } finally { folder.deleteRecursively() }
    }
}
