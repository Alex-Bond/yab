package dev.yab.browser

import dev.yab.browser.model.SpaceSymbols
import org.junit.Assert.*
import org.junit.Test

class SpaceSymbolsTest {
    @Test fun drawingTheCurrentPhoneEmojiNeverReplacesTheMacSymbolOnSave() {
        for ((symbol, emoji) in listOf("star.fill" to "⭐️", "heart.fill" to "❤️", "rectangle.stack.fill" to "🗂️",
            "chevron.left.forwardslash.chevron.right" to "⌨️", "cloud" to "🌥️", "tram.fill" to "🚆")) {
            assertEquals(emoji, SpaceSymbols.emoji(symbol))
            assertEquals(symbol, SpaceSymbols.wire(emoji, symbol))
            assertEquals(symbol, SpaceSymbols.kept(emoji, symbol))
        }
        assertEquals("📁", SpaceSymbols.emoji("future.mac.symbol"))
        assertEquals("future.mac.symbol", SpaceSymbols.wire("📁", "future.mac.symbol"))
        assertEquals("", SpaceSymbols.emoji(""))
        assertFalse(SpaceSymbols.isSymbol("")); assertFalse(SpaceSymbols.isSymbol("é")); assertFalse(SpaceSymbols.isSymbol("⭐️"))
    }
    @Test fun anExplicitDifferentEmojiOrSymbolRemainsAnActualEdit() {
        assertEquals("🎨", SpaceSymbols.wire("🎨", "star.fill"))
        assertEquals("moon.fill", SpaceSymbols.wire("moon.fill", "star.fill"))
        assertEquals("🎨", SpaceSymbols.kept("🎨", "star.fill"))
        assertEquals("moon.fill", SpaceSymbols.kept("moon.fill", "star.fill"))
        assertEquals("⭐️", SpaceSymbols.wire("⭐️", "🎨"))
        assertEquals("🎨", SpaceSymbols.emoji("🎨"))
    }
    @Test fun onlyAnExactlyMatchingExplicitChoiceAllowsTheSymbolsOwnEmojiTwin() {
        assertEquals("⭐️", SpaceSymbols.kept("⭐️", "star.fill", choice = "⭐️"))
        assertEquals("🎨", SpaceSymbols.kept("🎨", "paintpalette.fill", choice = "🎨"))
        for (choice in listOf(null, "", "star.fill", "🔭")) {
            assertEquals("star.fill", SpaceSymbols.kept("⭐️", "star.fill", choice))
        }
        assertEquals("🔭", SpaceSymbols.kept("🔭", "star.fill", choice = "other"))
        assertEquals("future.mac.symbol", SpaceSymbols.wire("📁", "future.mac.symbol"))
    }
}
