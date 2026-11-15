package dev.yab.browser.engine

import dev.yab.browser.model.HistorySwipeDirection
import org.junit.Assert.*
import org.junit.Test

/** Drives the production commit adapter, with native current position deliberately ahead of Java's last callback. */
class HistoryRelativeCommitTest {
    private val pages = List(4) { "https://same.example/" to "Same" }
    @Test fun unreportedSpaPushCannotMakeBackSkipToTheOldAbsoluteTarget() {
        val history = NativeHistorySwipeRegistry().apply { update(pages.take(2), 1) }
        val target = history.capture("doc", HistorySwipeDirection.BACK)!! // Java's old absolute target is0.
        var actualNativeIndex = 2 // SPA pushed before its next Java callback was delivered.
        var calls = 0
        assertTrue(history.commitRelative("doc", target, { calls++; actualNativeIndex-- }, { fail("Wrong direction") }))
        assertEquals(1, actualNativeIndex); assertEquals(1, calls)
        assertFalse(history.commitRelative("doc", target, { calls++ }, { calls++ }))
        assertEquals(1, calls)
    }
    @Test fun forwardAlsoUsesExactlyOneActualNativeNeighborAndUnavailableNativeBackCanBeANoop() {
        val history = NativeHistorySwipeRegistry().apply { update(pages, 1) }
        var actualNativeIndex = 0
        val forward = history.capture("doc", HistorySwipeDirection.FORWARD)!!
        assertTrue(history.commitRelative("doc", forward, { fail("Wrong direction") }, { actualNativeIndex++ }))
        assertEquals(1, actualNativeIndex)
        val back = history.capture("doc", HistorySwipeDirection.BACK)!!
        actualNativeIndex = 0
        assertTrue(history.commitRelative("doc", back, { if (actualNativeIndex > 0) actualNativeIndex-- }, { fail("Wrong direction") }))
        assertEquals(0, actualNativeIndex)
    }
    @Test fun knownRevisionOrDocumentChangeCancelsInsteadOfBorrowingANewerNavigation() {
        val history = NativeHistorySwipeRegistry().apply { update(pages, 2) }
        val old = history.capture("doc", HistorySwipeDirection.BACK)!!
        var calls = 0
        assertFalse(history.commitRelative("replacement", old, { calls++ }, { calls++ }))
        history.update(pages, 3)
        assertFalse(history.commitRelative("doc", old, { calls++ }, { calls++ }))
        assertEquals(0, calls)
    }

    @Test fun acceptedBackCannotInventAForwardTargetBeforeTheActualNativeHistoryUpdate() {
        val history = NativeHistorySwipeRegistry().apply { update(pages.take(2), 1) }
        val back = history.capture("before", HistorySwipeDirection.BACK)!!
        var nativeIndex = 1
        assertTrue(history.commitRelative("before", back, { nativeIndex-- }, { fail("Wrong direction") }))
        assertEquals(0, nativeIndex)
        history.invalidate() // Native PageStart revokes leases, not the last acknowledged list.
        assertEquals(1, history.projection().currentIndex)
        assertFalse(history.projection().forwardAvailable)
        assertNull(history.capture("after", HistorySwipeDirection.FORWARD))
        history.update(pages.take(2), nativeIndex)
        assertEquals(0, history.projection().currentIndex)
        assertTrue(history.projection().forwardAvailable)
        val forward = history.capture("after", HistorySwipeDirection.FORWARD)!!
        assertTrue(history.commitRelative("after", forward, { fail("Wrong direction") }, { nativeIndex++ }))
        assertEquals(1, nativeIndex)
        assertFalse(history.projection().countsClamped)
    }
}
