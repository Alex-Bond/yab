package dev.yab.browser

import dev.yab.browser.engine.ReaderPreferencesStore
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class BrowserReaderPresentationTest {
    @Test fun ordinaryThemeAndSizeChoicesAreKeptWhenThemesCardCloses() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }
        assertTrue(card.control().theme(ReaderTheme.PAPER)); assertTrue(card.control().step(1))
        assertTrue(card.control().close()); assertFalse(card.state.value.shown); assertFalse(card.state.value.dropped)
        assertEquals(ReaderTheme.PAPER, store.snapshot().theme); assertEquals(20, store.snapshot().look.points)
    }
    @Test fun customizeCancelRestoresWholeBeforePrefsAndRetiresSavedControl() {
        val store = ReaderPreferencesStore(); val original = store.snapshot()
        val card = BrowserReaderPresentation(store) { true }; val opening = card.control()
        assertTrue(opening.customize()); assertFalse(opening.theme(ReaderTheme.FOCUS))
        val knobs = card.control(); assertTrue(knobs.change { it.copy(word = 24, bold = true) })
        assertTrue(knobs.mode(ReaderMode.DARK)); assertTrue(knobs.cancel())
        assertEquals(original, store.snapshot()); assertEquals(ReaderCardPage.THEMES, card.state.value.page)
        assertFalse(knobs.change { it.copy(word = 40) })
    }
    @Test fun fontsBackKeepsSameTransactionAndDoneCommitsButSavedFontActionCannotRetarget() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }
        assertTrue(card.control().customize()); assertTrue(card.control().fonts())
        val fonts = card.control(); assertTrue(fonts.change { it.copy(font = ReaderFont.GEORGIA) }); assertTrue(fonts.back())
        assertFalse(fonts.change { it.copy(font = ReaderFont.ATHELAS) })
        assertTrue(card.control().done()); assertTrue(card.control().close())
        assertEquals(ReaderFont.GEORGIA, store.snapshot().look.font)
    }
    @Test fun closeFromFontsRollsBackButDropFromFontsIntentionallyKeepsLiveEdits() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }
        card.control().customize(); card.control().fonts(); card.control().change { it.copy(font = ReaderFont.CHARTER) }
        assertTrue(card.control().close()); assertEquals(ReaderFont.SITE, store.snapshot().look.font)
        val next = BrowserReaderPresentation(store) { true }
        next.control().customize(); next.control().fonts(); val saved = next.control()
        assertTrue(saved.change { it.copy(font = ReaderFont.IOWAN) }); next.drop()
        assertEquals(ReaderFont.IOWAN, store.snapshot().look.font); assertTrue(next.state.value.dropped)
        assertFalse(saved.cancel()); assertFalse(saved.change { it.copy(font = ReaderFont.SITE) })
    }
    @Test fun originalHostLossCannotReviveAfterAccountStopDocumentOrWindowAba() {
        var current = true; val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { current }
        val old = card.control(); current = false; assertFalse(old.step(1)); current = true
        assertFalse(old.step(1)); assertFalse(card.control().theme(ReaderTheme.CALM)); assertFalse(card.current())
        val fresh = BrowserReaderPresentation(store) { current }
        assertTrue(fresh.control().theme(ReaderTheme.CALM)); assertEquals(ReaderTheme.CALM, store.snapshot().theme)
    }
    @Test fun sameTurnThemeAbaPermanentlyRetiresOldControlWhileFreshRenderWorks() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }; val old = card.control()
        store.set(store.snapshot().copy(theme = ReaderTheme.PAPER)); store.set(store.snapshot().copy(theme = ReaderTheme.ORIGINAL))
        assertFalse(old.step(1)); assertTrue(card.control().step(1)); assertEquals(20, store.snapshot().look.points)
        val reentrant = ReaderPreferencesStore(); var checks = 0
        val predicate = BrowserReaderPresentation(reentrant) {
            if (++checks == 2) {
                reentrant.set(reentrant.snapshot().copy(theme = ReaderTheme.FOCUS))
                reentrant.set(reentrant.snapshot().copy(theme = ReaderTheme.ORIGINAL))
            }
            true
        }
        assertFalse(predicate.control().step(1)); assertEquals(18, reentrant.snapshot().look.points)
    }
    @Test fun stalePageControlsCannotReviveAcrossCustomizeThemesCustomizeAba() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }
        card.control().customize(); val old = card.control(); assertTrue(old.done()); card.control().customize()
        assertFalse(old.reset()); assertFalse(old.cancel()); assertTrue(card.control().change { it.copy(margins = 20) })
        assertTrue(card.control().cancel()); assertEquals(0, store.snapshot().look.margins)
    }
    @Test fun disposingOneOriginalControlDoesNotCloseCardOrAuthorizeItsLaterCallback() {
        val store = ReaderPreferencesStore(); val card = BrowserReaderPresentation(store) { true }; val old = card.control()
        old.retire(); assertFalse(old.theme(ReaderTheme.CALM)); assertTrue(card.current())
        assertTrue(card.control().theme(ReaderTheme.CALM)); assertTrue(card.control().customize())
        assertTrue(card.control().reset()); assertFalse(store.snapshot().edited(ReaderTheme.CALM))
    }
}
