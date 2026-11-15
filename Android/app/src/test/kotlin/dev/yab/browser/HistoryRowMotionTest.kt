package dev.yab.browser

import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Authored source policy/real Controller tests. No SwiftUI or presented-frame oracle. */
@OptIn(ExperimentalCoroutinesApi::class)
class HistoryRowMotionTest {
    private val a = BrowserVisit("https://a.example.test/story", "First", 1000)
    private val b = BrowserVisit("https://b.example.test/", "Second", 2000)
    private val source = Any()
    private fun finish(model: HistoryRowMotion, current: Boolean = true, accepts: (Any, BrowserVisit) -> Boolean = { _, _ -> true }): List<HistoryRowTicket> {
        val out = mutableListOf<HistoryRowTicket>()
        for (i in 0..120) out += model.advance(i * 16_000_000L, current, accepts)
        return out
    }
    @Test fun atRestOnlyLeftAndStrictHorizontalDominanceCanBeginButOpenRowCanReverse() {
        val m = HistoryRowMotion()
        assertFalse(m.canStart(a, 40.0, 0.0, 100.0, 0.0))
        assertFalse(m.canStart(a, -40.0, 40.0, -100.0, 100.0))
        assertFalse(m.canStart(a, -40.0, 0.0, 0.0, 0.0))
        assertTrue(m.canStart(a, -40.0, 1.0, -100.0, 1.0))
        val t = m.begin(source, a)!!; m.move(t, -70.0); m.release(t, 0.0); finish(m)
        assertTrue(m.canStart(a, 20.0, 0.0, 100.0, 0.0))
        assertFalse(m.canStart(b, 20.0, 0.0, 100.0, 0.0))
    }
    @Test fun sourceLimitsOpenFlickAndRubberHaveExactStrictBoundaries() {
        assertEquals(0.0, HistoryRowMotion.displacement(40.0), 0.0)
        assertEquals(-330.0, HistoryRowMotion.displacement(-330.0), 0.0)
        assertEquals(-(330 + (1 - 1 / (120 * .55 / 30 + 1)) * 30), HistoryRowMotion.displacement(-450.0), 1e-12)
        assertTrue(HistoryRowMotion.displacement(-10000.0) > -360)
        fun target(distance: Double, velocity: Double): Double {
            val m = HistoryRowMotion(); val t = m.begin(source,a)!!; m.move(t,-distance); m.release(t,velocity); finish(m)
            return m.frame.value.rows[a.identity]?.x ?: 0.0
        }
        assertEquals(0.0,target(60.0,-500.0),0.0)
        assertEquals(-108.0,target(61.0,0.0),0.0)
        assertEquals(-108.0,target(20.0,-501.0),0.0)
    }
    @Test fun oneOpenRowAndFirstTapClosesInsteadOfOpeningAnyPage() {
        val m=HistoryRowMotion(); val x=m.begin(source,a)!!;m.move(x,-90.0);m.release(x,0.0);finish(m)
        val y=m.begin(source,b)!!;m.move(y,-80.0);m.release(y,0.0);finish(m)
        assertEquals(b.identity,m.frame.value.open);assertFalse(m.frame.value.rows.containsKey(a.identity))
        assertFalse(m.tap());assertNull(m.frame.value.open);assertTrue(m.tap())
    }
    @Test fun regrabAt80And160RetainsDrawnPoseAndCancelsTheOldDelayedDelete() {
        for (at in listOf(80L,160L)) {
            val m=HistoryRowMotion();val t=m.begin(source,a)!!;m.move(t,-270.0);m.release(t,0.0)
            m.advance(0,true){_,_->true};m.advance(at*1_000_000,true){_,_->true}
            val before=m.frame.value.rows.getValue(a.identity).x
            val fresh=m.begin(source,a)!!
            assertEquals(before,m.frame.value.rows.getValue(a.identity).x,0.0)
            assertFalse(m.move(t,-400.0));m.move(fresh,150.0);m.cancel(fresh)
            assertTrue(finish(m).isEmpty());assertFalse(m.frame.value.rows.getValue(a.identity).deleting)
        }
    }
    @Test fun completedLongSwipeIsOneShotAndSourceLossPermanentlyRevokesIt() {
        val m=HistoryRowMotion();val t=m.begin(source,a)!!;m.move(t,-251.0);m.release(t,0.0)
        val done=finish(m);assertEquals(listOf(a),done.map{it.visit});assertTrue(finish(m).isEmpty())
        val old=HistoryRowMotion();val held=old.begin(source,a)!!;old.move(held,-300.0);old.release(held,0.0)
        old.advance(0,false){_,_->true};assertTrue(finish(old).isEmpty());assertNull(old.begin(source,a))
        val refreshed=HistoryRowMotion();val r=refreshed.begin(source,a)!!;refreshed.move(r,-300.0);refreshed.release(r,0.0)
        refreshed.reconcile(true){_,_->false};assertTrue(finish(refreshed).isEmpty())
    }
    @Test fun reducedMotionAndDisabledAnimatorsKeepTheDestructiveSourceGuard() {
        for (animated in listOf(true,false)) {
            val m=HistoryRowMotion();m.configure(true,animated);val t=m.begin(source,a)!!;m.move(t,-270.0);m.release(t,0.0)
            assertTrue(m.advance(0,true){_,_->false}.isEmpty());assertTrue(finish(m).isEmpty())
            val live=HistoryRowMotion();live.configure(true,animated);val x=live.begin(source,a)!!;live.move(x,-270.0);live.release(x,0.0)
            assertEquals(listOf(a),finish(live).map{it.visit})
        }
    }
    @Test fun reducedPolicyChangesRetainTheCurrentlyDrawnPoseInsteadOfReplayingTheRelease() {
        val m=HistoryRowMotion();val t=m.begin(source,a)!!;m.move(t,-80.0);m.release(t,0.0)
        m.advance(0,true){_,_->true};m.advance(100_000_000,true){_,_->true}
        val normal=m.frame.value.rows.getValue(a.identity).x
        assertTrue(normal < -80)
        m.configure(true,true);m.advance(100_000_000,true){_,_->true}
        assertEquals(normal,m.frame.value.rows.getValue(a.identity).x,0.0)
        m.advance(116_000_000,true){_,_->true}
        val reduced=m.frame.value.rows.getValue(a.identity).x
        assertTrue(reduced < normal)
        m.configure(false,true);m.advance(116_000_000,true){_,_->true}
        assertEquals(reduced,m.frame.value.rows.getValue(a.identity).x,1e-12)
        assertTrue(finish(m).isEmpty());assertEquals(-108.0,m.frame.value.rows.getValue(a.identity).x,0.0)
    }
    @Test fun releasingOrCancellingAnotherRowDoesNotPauseTheSharedClosingClock() {
        for (cancel in listOf(false,true)) {
            val m=HistoryRowMotion();val first=m.begin(source,a)!!;m.move(first,-80.0);m.release(first,0.0);finish(m)
            val second=m.begin(source,b)!!;m.move(second,-80.0)
            m.advance(2_000_000_000,true){_,_->true};m.advance(2_100_000_000,true){_,_->true}
            val before=m.frame.value.rows.getValue(a.identity).x
            assertTrue(before > -108 && before < 0)
            if(cancel)m.cancel(second) else m.release(second,0.0)
            m.advance(2_116_000_000,true){_,_->true}
            assertTrue(m.frame.value.rows.getValue(a.identity).x > before)
        }
    }
    private class Repo(val data: BrowserSnapshot):BrowserRepository {
        override suspend fun load()=data
        override suspend fun save(snapshot:BrowserSnapshot) {}
    }
    private class Engine:BrowserEngine {
        override fun activate(tab:BrowserTab,profile:WebsiteProfile) {}
        override fun navigate(tab:BrowserTab,url:String,profile:WebsiteProfile) {}
        override fun close(tabId:String) {}
        override fun goBack(tabId:String) {}
        override fun goForward(tabId:String) {}
        override fun reload(tabId:String) {}
        override fun stop(tabId:String) {}
        override suspend fun clearWebsiteData(profileIds:Set<String>) {}
    }
    @Test fun actualControllerRetiresCoalescedRemoveReaddAndValueAbaButKeepsUnrelatedRow()= runTest {
        val snap=BrowserSnapshot(spaces=listOf(BrowserSpace("space","Public",tabs=listOf(BrowserTab("tab",createdAt=0)),currentTabId="tab")),selectedSpaceId="space",history=listOf(a,b))
        val c=BrowserController(Repo(snap),Engine(),backgroundScope);runCurrent();c.show(BrowserSurface.HISTORY)
        val outer=c.captureHistoryPresentation()!!;val oldA=c.captureHistoryRow(outer,a)!!;val oldB=c.captureHistoryRow(outer,b)!!
        val base=c.publicSnapshot()!!
        c.applySyncedSnapshot(base.copy(history=listOf(b)));c.applySyncedSnapshot(base)
        assertFalse(c.deleteHistoryRow(oldA));assertFalse(c.openHistoryRow(oldA));assertTrue(c.historyRowActionsCurrent(oldB))
        val fresh=c.captureHistoryRow(outer,a)!!
        c.applySyncedSnapshot(base.copy(history=listOf(a.copy(title="Replacement"),b)));c.applySyncedSnapshot(base)
        assertFalse(c.deleteHistoryRow(fresh));assertTrue(c.historyRowActionsCurrent(oldB))
        assertTrue(c.deleteHistoryRow(c.captureHistoryRow(outer,a)!!));assertEquals(listOf(b),c.state.value.history)
    }
    @Test fun realControllerForegroundReopenAndAccountResetCannotAdmitOldRows()=runTest {
        val snap=BrowserSnapshot(spaces=listOf(BrowserSpace("space","Public",tabs=listOf(BrowserTab("tab",createdAt=0)),currentTabId="tab")),selectedSpaceId="space",history=listOf(a))
        val c=BrowserController(Repo(snap),Engine(),backgroundScope);runCurrent();c.show(BrowserSurface.HISTORY)
        fun row()=c.captureHistoryRow(c.captureHistoryPresentation()!!,a)!!
        val stopped=row();c.backgrounded();c.foregrounded();assertFalse(c.deleteHistoryRow(stopped))
        val closed=row();c.dismissSurface();c.show(BrowserSurface.HISTORY);assertFalse(c.deleteHistoryRow(closed))
        val account=row();c.invalidateLocalOwnership();assertFalse(c.deleteHistoryRow(account))
        assertTrue(c.deleteHistoryRow(row()))
    }
}
