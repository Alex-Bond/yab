package dev.yab.browser.engine

import org.junit.Assert.*
import org.junit.Test

class HistoryPaintIdentityTest {
    private fun uuid(value: Int) = "00000000-0000-0000-0000-${value.toString().padStart(12, '0')}"
    private fun key(value: Int = 1, changes: Number = 0, initial: Int = 1, known: Boolean = true): HistoryNavigationKey? {
        val fields = mapOf("known" to known, "key" to uuid(value), "id" to uuid(value + 100),
            "initialKey" to uuid(initial), "initialId" to uuid(initial + 100), "changes" to changes)
        return HistoryNavigationKey.read(fields::get)
    }
    private fun row(value: Int, navigation: Int = value) = """{"ID":$value,"docIdentifier":${value + 1000},"docshellUUID":"{${uuid(99)}}","navigationKey":"{${uuid(navigation)}}","navigationId":"{${uuid(navigation + 100)}}"}"""
    private fun snapshot(index: Int = 1, vararg rows: String) = checkNotNull(HistoryIdentitySnapshot.parse(
        """{"history":{"index":$index,"entries":[${rows.joinToString(",")}]}}"""))

    @Test fun onlyPositiveKnownInitialKeyAndTheExactNativeCurrentPositionCanBeCaptured() {
        val native = snapshot(1, row(1), row(2)); val key = key()!!
        val candidate = checkNotNull(HistoryPaintCandidate.create(native, key))
        assertTrue(candidate.current(native, key()))
        assertFalse(candidate.current(snapshot(2, row(1), row(2)), key()))
        assertFalse(candidate.current(snapshot(1, row(1), row(3)), key()))
        assertNull(HistoryPaintCandidate.create(native, key(2, initial = 2)))
        assertNull(HistoryPaintCandidate.create(null, key))
        assertNull(HistoryPaintCandidate.create(native, null))
    }
    @Test fun pushReplaceAndReturnToTheIdenticalKeyRemainDisqualifiedForThisVisit() {
        val native = snapshot(1, row(1)); val candidate = checkNotNull(HistoryPaintCandidate.create(native, key()))
        assertFalse(candidate.current(native, key(changes = 1)))
        assertFalse(candidate.current(native, key(value = 2, changes = 1)))
        assertFalse(candidate.current(native, key(value = 1, changes = 2))) // A→B→A is still a change.
        assertNull(HistoryPaintCandidate.create(native, key(changes = 2)))
    }
    @Test fun duplicatedNavigationPairCannotChooseBetweenDistinctNativeEntries() {
        val samePair = snapshot(1, row(1), row(2, navigation = 1))
        assertNotEquals(samePair.entries[0], samePair.entries[1])
        assertNull(HistoryPaintCandidate.create(samePair, key()))
    }
    @Test fun unknownAndNonIntegralOrUnboundedReceiptsNeverAuthorizeAnImage() {
        assertNull(key(known = false)); assertNull(key(changes = Double.NaN))
        assertNull(key(changes = .5)); assertNull(key(changes = -1))
        assertNull(key(changes = 9_007_199_254_740_992.0))
        val fields = mapOf("known" to true, "key" to uuid(1), "id" to uuid(101),
            "initialKey" to uuid(1), "initialId" to uuid(101), "changes" to 0)
        assertNull(HistoryNavigationKey.read((fields + ("key" to "{${uuid(1)}}"))::get))
        assertNull(HistoryNavigationKey.read((fields + ("key" to "not-an-opaque-native-key"))::get))
    }
    @Test fun releaseCallbackClosesEveryEvictedOrReplacedOwnerWithoutRecyclingPublishedValues() {
        val owner = Any(); val released = mutableListOf<Any>(); val store = HistoryFrameStore<Any>(owner) { released += it }
        val a = Any(); val b = Any(); val c = Any()
        assertTrue(store.retain(owner, snapshot(1, row(1)), 10, 10, 400, a))
        assertTrue(store.retain(owner, snapshot(2, row(1), row(2)), 10, 10, 400, b))
        store.removeCurrent(snapshot(2, row(1), row(2)))
        assertEquals(listOf(b), released)
        assertTrue(store.retain(owner, snapshot(2, row(1), row(2)), 10, 10, 400, c))
        store.pageStarted(); store.historyChanged(owner, snapshot(1, row(9)))
        assertEquals(setOf(a, b, c), released.toSet()); assertEquals(0, store.count)
    }
}
