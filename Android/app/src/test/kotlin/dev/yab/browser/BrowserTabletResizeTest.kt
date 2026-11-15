package dev.yab.browser

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import org.junit.Assert.*
import org.junit.Test

class BrowserTabletResizeTest {
    private val window = WorkspaceWindowState(true, 2, 3, BrowserWorkspaceWindow(1376.0, 1032.0))
    @Test fun cachedRenderStillObservesTheNextResize() {
        val owner = BrowserTabletWorkspaceState(initialSidebarWidth = 304.0)
        val source = Any()
        val scope = Any()
        val observer = SnapshotStateObserver { it() }
        var invalidations = 0
        val changed: (Any) -> Unit = { invalidations++ }
        fun frame() = checkNotNull(owner.capture(window, 600, 24.0, true, source) { true })
        Snapshot.notifyObjectsInitialized()
        observer.start()
        try {
            var original = frame()
            observer.observeReads(scope, changed) { original = frame() }
            // A fresh composition of the same frame replaces its previous reads.
            observer.observeReads(scope, changed) { assertSame(original, frame()) }
            assertTrue(checkNotNull(original.beginResize(true) { true }).finish(264.0))
            Snapshot.sendApplyNotifications()
            assertEquals(1, invalidations)
            assertEquals(264.0, frame().frame.sidebar!!.width, 0.0)
        } finally { observer.stop(); observer.clear() }
    }
    @Test fun oneGestureFollowsItsOwnRevisionsAndPersistsOnlyAtRelease() {
        val saved = mutableListOf<Pair<Double, Double>>()
        val owner = BrowserTabletWorkspaceState(persistDimensions = { w, f -> saved += w to f; true })
        val source = Any()
        fun frame() = checkNotNull(owner.capture(window, 600, 24.0, true, source) { true })
        val first = frame()
        val gesture = checkNotNull(first.beginResize(true) { true })
        assertTrue(gesture.moveTo(304.0))
        val second = frame()
        assertFalse(first.current()); assertEquals(304.0, second.frame.sidebar!!.width, 0.0)
        assertTrue(gesture.moveTo(324.0)); assertTrue(saved.isEmpty())
        assertTrue(gesture.finish(344.0))
        assertEquals(344.0, frame().frame.sidebar!!.width, 0.0)
        assertEquals(listOf(344.0 to .5), saved)
        assertFalse(gesture.finish(264.0))
        val split = checkNotNull(frame().beginResize(false) { true })
        assertTrue(split.finish(600.0))
        assertEquals(600.0, frame().frame.pane(false).width, .001)
    }
    @Test fun cancellationRestoresGeometryButCoverageWindowAndSourceChangesNeverReviveAnOldGesture() {
        for (change in listOf("cancel", "cover", "window", "source")) {
            val owner = BrowserTabletWorkspaceState(); val source = Any(); var available = true
            fun frame(w: WorkspaceWindowState = window, key: Any = source) = checkNotNull(owner.capture(w, 600, 24.0, true, key) { true })
            val gesture = checkNotNull(frame().beginResize(true) { available })
            assertTrue(gesture.moveTo(304.0)); frame()
            when (change) {
                "cancel" -> { gesture.cancel(); assertEquals(264.0, frame().frame.sidebar!!.width, 0.0) }
                "cover" -> { available = false; assertFalse(gesture.moveTo(324.0)); available = true }
                "window" -> { frame(window.copy(generation = 4)); frame() }
                else -> { frame(key = Any()); frame() }
            }
            assertFalse(gesture.finish(360.0))
        }
    }
}
