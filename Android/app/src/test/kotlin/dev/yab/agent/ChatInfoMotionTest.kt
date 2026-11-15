package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ChatInfoMotionTest {
    @Test fun startsAtTheRealFaceAndEndsAtTheWholePage() {
        val first = ChatInfoZoom.pose(402f, 874f, 56f, 0f, 0f, false)
        assertEquals(44f, first.scale * 402f, .001f)
        assertEquals(44f, first.visibleHeight, 0f); assertEquals(56f, first.top, 0f)
        assertEquals(22f, first.corner * first.scale, .001f)
        val last = ChatInfoZoom.pose(402f, 874f, 56f, 1f, 0f, false)
        assertEquals(1f, last.scale, 0f); assertEquals(0f, last.top, .001f)
        assertEquals(874f, last.visibleHeight, 0f); assertEquals(0f, last.corner, 0f)
    }
    @Test fun draggingFollowsTheFingerAndReducedMotionDoesNotScaleOrTravel() {
        val drag = ChatInfoZoom.pose(402f, 874f, 56f, 1f, 300f, false)
        assertEquals(300f, drag.top, .001f); assertTrue(drag.scale in .8f..1f)
        assertTrue(drag.corner > 0); assertTrue(drag.dim < .15f)
        val still = ChatInfoZoom.pose(402f, 874f, 56f, .5f, 300f, true)
        assertEquals(1f, still.scale, 0f); assertEquals(0f, still.top, 0f)
        assertEquals(874f, still.visibleHeight, 0f); assertEquals(0f, still.corner, 0f)
    }
}
