package dev.yab.browser

import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import dev.yab.android.EngineTestActivity
import dev.yab.browser.model.*
import dev.yab.browser.ui.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Controlled-clock production History consumer, RAM profile/inert engine. No OS animation,
 * display cadence, actual browser page or paired Phone raster acceptance. */
class BrowserHistoryRowsDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<EngineTestActivity>()
    private val at = System.currentTimeMillis()
    private val a = BrowserVisit("https://a.example.test/story", "Owned First", at - 1000)
    private val b = BrowserVisit("https://b.example.test/story", "Owned Second", at - 2000)
    private fun row(visit: BrowserVisit) = compose.onNodeWithTag("history.row.${visit.identity}")
    private fun pan(visit: BrowserVisit) = compose.onNodeWithTag("history.pan.${visit.identity}")
    private fun x(visit: BrowserVisit) = row(visit).fetchSemanticsNode().config[HistoryRowOffsetKey]
    private fun swipe(visit: BrowserVisit, distance: Float, held: Boolean = false) {
        val d = compose.activity.resources.displayMetrics.density
        pan(visit).performTouchInput {
            val start = Offset(if(distance>0)16*d else width-16*d, height*.5f)
            down(start)
            for(step in 1..6) moveTo(start + Offset(distance*d*step/6,0f), delayMillis = 40)
            if (!held) up()
        }
        compose.mainClock.advanceTimeByFrame()
    }
    @Test fun onlyOneRowOpensAndFirstNativeTapClosesBeforeTheNextOpensThePage() = fixture { browser, engine ->
        swipe(a,80f);compose.mainClock.advanceTimeBy(1000)
        compose.runOnIdle { assertEquals(BrowserSurface.HISTORY,browser.state.value.surface);assertTrue(engine.pages.isEmpty()) }
        assertEquals(0f,x(a),.001f)
        swipe(a,-80f);compose.mainClock.advanceTimeBy(1000);assertEquals(-108f,x(a),.001f)
        swipe(b,-80f);compose.mainClock.advanceTimeBy(1000)
        assertEquals(0f,x(a),.001f);assertEquals(-108f,x(b),.001f)
        row(a).performTouchInput { click() };compose.mainClock.advanceTimeByFrame()
        assertTrue(engine.pages.isEmpty());assertEquals(BrowserSurface.HISTORY,browser.state.value.surface)
        compose.mainClock.advanceTimeBy(1000);row(a).performTouchInput { click() }
        compose.runOnIdle { assertEquals(listOf(a.url),engine.pages);assertEquals(BrowserSurface.PAGE,browser.state.value.surface) }
    }
    @Test fun rejectedRightOrVerticalJumpOnUpCannotOpenButTheNextSemanticClickCan() = fixture { browser, engine ->
        val d=compose.activity.resources.displayMetrics.density
        var openedTabId:String?=null
        for ((index,delta) in listOf(Offset(80f,0f),Offset(0f,80f)).withIndex()) {
            pan(a).performTouchInput {
                val start=Offset(16*d,height*.5f)
                down(start);updatePointerTo(0,start+delta*d);advanceEventTime(40);up()
            }
            compose.mainClock.advanceTimeByFrame()
            compose.runOnIdle { assertEquals(BrowserSurface.HISTORY,browser.state.value.surface);assertEquals(index,engine.pages.size) }
            assertEquals(0f,x(a),.001f)
            row(a).performSemanticsAction(SemanticsActions.OnClick) { assertTrue(it()) }
            compose.runOnIdle {
                assertEquals(BrowserSurface.PAGE,browser.state.value.surface)
                val selected=checkNotNull(browser.state.value.tab)
                assertEquals(a.url,selected.url);assertFalse(selected.isPrivate)
                if(index==0) openedTabId=selected.id else assertEquals(openedTabId,selected.id)
                assertEquals(listOf(a.url),engine.pages)
            }
            if(index==0) {
                compose.runOnIdle { browser.show(BrowserSurface.HISTORY) }
                compose.mainClock.advanceTimeByFrame()
            }
        }
    }
    @Test fun rejectedVerticalPanStillScrollsTheActualHistoryListWithoutOpening() {
        val visits=listOf(a,b)+(1..30).map { BrowserVisit("https://extra$it.example.test/","Extra $it",at-3000-it*1000) }
        fixture(visits) { browser, engine ->
            val d=compose.activity.resources.displayMetrics.density
            pan(b).performTouchInput {
                val start=Offset(width*.5f,height*.5f)
                down(start)
                for(step in 1..6) moveTo(start+Offset(0f,-80*d*step/6),delayMillis=40)
                up()
            }
            compose.mainClock.advanceTimeBy(1000)
            assertTrue(compose.onNodeWithTag("history.page").fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()>0f)
            compose.runOnIdle { assertEquals(BrowserSurface.HISTORY,browser.state.value.surface);assertTrue(engine.pages.isEmpty()) }
        }
    }
    @Test fun longSwipeInterruptedByBackgroundCannotDeleteAfterReturnOrBorrowFreshReopen() = fixture { browser, _ ->
        swipe(a,-270f);compose.mainClock.advanceTimeBy(80)
        assertTrue(row(a).fetchSemanticsNode().config[HistoryRowDeletingKey])
        compose.runOnIdle { browser.backgrounded();browser.foregrounded() }
        compose.mainClock.advanceTimeBy(1200)
        assertEquals(listOf(a,b),browser.state.value.history)
        compose.runOnIdle { browser.dismissSurface();browser.show(BrowserSurface.HISTORY) }
        compose.mainClock.advanceTimeByFrame();swipe(a,-270f);compose.mainClock.advanceTimeBy(1400)
        compose.runOnIdle { assertEquals(listOf(b),browser.state.value.history) }
    }
    @Test fun refreshedVisitCancelsPendingLongDeleteAndAccessibleDeleteRetainsItsOriginalRowToken() = fixture { browser, _ ->
        val stale = row(a).fetchSemanticsNode().config[SemanticsActions.CustomActions].single { it.label == "Delete" }.action
        swipe(a,-270f);compose.mainClock.advanceTimeBy(80)
        val snapshot = browser.publicSnapshot()!!
        compose.runOnIdle {
            browser.applySyncedSnapshot(snapshot.copy(history=listOf(a.copy(title="Owned replacement"),b)))
            browser.applySyncedSnapshot(snapshot)
            assertFalse(stale())
        }
        compose.mainClock.advanceTimeBy(1200)
        assertEquals(listOf(a,b),browser.state.value.history)
        val fresh = row(a).fetchSemanticsNode().config[SemanticsActions.CustomActions].single { it.label == "Delete" }.action
        compose.runOnIdle { assertTrue(fresh());assertEquals(listOf(b),browser.state.value.history);assertFalse(stale()) }
    }
    @Test fun heldLongSwipeRegrabCancellationDoesNotDeliverItsOldCompletion() = fixture { browser, _ ->
        swipe(a,-270f);compose.mainClock.advanceTimeBy(80)
        val before=x(a)
        val d=compose.activity.resources.displayMetrics.density
        val pane=pan(a).fetchSemanticsNode().boundsInRoot
        val body=row(a).fetchSemanticsNode().boundsInRoot
        val visibleLeft=maxOf(pane.left,body.left);val visibleRight=minOf(pane.right,body.right)
        assertTrue(visibleRight-visibleLeft>20*d)
        val point=Offset((visibleLeft+visibleRight)*.5f,(body.top+body.bottom)*.5f)-pane.topLeft
        val originalPan=pan(a)
        lateinit var original:HistoryRowPresentationLease
        compose.runOnIdle { original=browser.captureHistoryRow(browser.captureHistoryPresentation()!!,a)!! }
        originalPan.performTouchInput { down(point);moveBy(Offset(-10*d,0f),delayMillis=100) }
        compose.mainClock.advanceTimeByFrame()
        var pressed=true
        var failure:Throwable?=null
        try {
            assertTrue(x(a)<before)
            compose.runOnIdle { check(browser.historyRowActionsCurrent(original)) }
            originalPan.performTouchInput { cancel() };pressed=false
            compose.mainClock.advanceTimeBy(1200)
            assertEquals(listOf(a,b),browser.state.value.history)
            assertFalse(row(a).fetchSemanticsNode().config[HistoryRowDeletingKey])
        } catch(error:Throwable) { failure=error;throw error }
        finally { if(pressed) runCatching {
            compose.runOnIdle { check(browser.historyRowActionsCurrent(original)) }
            originalPan.performTouchInput { cancel() }
        }.exceptionOrNull()?.let { error -> failure?.addSuppressed(error) ?: throw error } }
    }
    @Test fun coalescedAtRestAbaRebindsCurrentActionsWithoutCancellingTheUnchangedOtherFinger() = fixture { browser, _ ->
        val stale=row(a).fetchSemanticsNode().config[SemanticsActions.CustomActions].single{it.label=="Delete"}.action
        lateinit var outer:HistoryPresentationLease
        lateinit var unchanged:HistoryRowPresentationLease
        compose.runOnIdle {
            outer=browser.captureHistoryPresentation()!!
            unchanged=browser.captureHistoryRow(outer,b)!!
        }
        swipe(b,-80f);compose.mainClock.advanceTimeBy(1000)
        val d=compose.activity.resources.displayMetrics.density
        val pane=pan(b).fetchSemanticsNode().boundsInRoot
        val body=row(b).fetchSemanticsNode().boundsInRoot
        val point=Offset((maxOf(pane.left,body.left)+minOf(pane.right,body.right))*.5f,body.center.y)-pane.topLeft
        val originalPan=pan(b)
        originalPan.performTouchInput { down(point);moveBy(Offset(-20*d,0f),delayMillis=40) }
        compose.mainClock.advanceTimeByFrame();assertEquals(-128f,x(b),.001f)
        var pressed=true
        var failure:Throwable?=null
        try {
            val snapshot=browser.publicSnapshot()!!
            compose.runOnIdle {
                browser.applySyncedSnapshot(snapshot.copy(history=listOf(b)))
                browser.applySyncedSnapshot(snapshot)
                assertFalse(stale())
                assertEquals(unchanged,browser.captureHistoryRow(outer,b))
            }
            // No caller state nudge: only the per-row token projection wakes this render.
            compose.mainClock.advanceTimeByFrame();assertEquals(-128f,x(b),.001f)
            compose.runOnIdle { check(browser.historyRowActionsCurrent(unchanged)) }
            originalPan.performTouchInput { up() };pressed=false
            compose.mainClock.advanceTimeBy(1000);assertEquals(-108f,x(b),.001f)
            val fresh=row(a).fetchSemanticsNode().config[SemanticsActions.CustomActions].single{it.label=="Delete"}.action
            compose.runOnIdle { assertTrue(fresh());assertEquals(listOf(b),browser.state.value.history) }
        } catch(error:Throwable) { failure=error;throw error }
        finally { if(pressed) runCatching {
            compose.runOnIdle { check(browser.historyRowActionsCurrent(unchanged)) }
            originalPan.performTouchInput { cancel() }
        }.exceptionOrNull()?.let { error -> failure?.addSuppressed(error) ?: throw error } }
    }
    private class Engine:BrowserEngine {
        val pages=mutableListOf<String>()
        override fun activate(tab:BrowserTab,profile:WebsiteProfile) {}
        override fun navigate(tab:BrowserTab,url:String,profile:WebsiteProfile) { pages+=url }
        override fun close(tabId:String) {}
        override fun goBack(tabId:String) {}
        override fun goForward(tabId:String) {}
        override fun reload(tabId:String) {}
        override fun stop(tabId:String) {}
        override suspend fun clearWebsiteData(profileIds:Set<String>) {}
    }
    private fun fixture(visits:List<BrowserVisit> = listOf(a,b),body:(BrowserController,Engine)->Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator")=="true")
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        val engine=Engine();lateinit var browser:BrowserController
        val snapshot=BrowserSnapshot(spaces=listOf(BrowserSpace("public","Public",tabs=listOf(BrowserTab("front",createdAt=at)),currentTabId="front")),selectedSpaceId="public",history=visits)
        compose.runOnIdle { browser=BrowserController(object:BrowserRepository {
            override suspend fun load()=snapshot
            override suspend fun save(snapshot:BrowserSnapshot) {}
        },engine,scope) }
        compose.waitUntil(5000){!browser.state.value.loading}
        compose.runOnIdle {browser.show(BrowserSurface.HISTORY)}
        compose.setContent {
            val state by browser.state.collectAsState()
            BrowserTheme(BrowserAppearance.LIGHT) { CompositionLocalProvider(LocalHistoryRowAnimationsEnabled provides true) {
                BrowserHistoryPanel(state,browser)
            } }
        }
        compose.mainClock.autoAdvance=false
        try { compose.mainClock.advanceTimeByFrame();body(browser,engine) }
        finally { compose.mainClock.autoAdvance=true;compose.runOnIdle{scope.cancel()} }
    }
}
