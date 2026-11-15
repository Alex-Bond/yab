package dev.yab.android

import dev.yab.browser.model.BrowserWorkspaceWindow
import dev.yab.browser.model.BrowserController
import dev.yab.browser.model.BrowserEngine
import dev.yab.browser.model.BrowserRepository
import dev.yab.browser.model.BrowserSnapshot
import dev.yab.browser.model.BrowserSpace
import dev.yab.browser.model.BrowserTab
import dev.yab.browser.model.WebsiteProfile
import dev.yab.sync.SyncIdentityLease
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class TabletJoinPresentationTest {
    private class Fixture {
        var source = TabletJoinPresentation.Source(null, 7, true)
        var host = true
        fun owner() = TabletJoinPresentation({ source }, { host })
        fun attached(account: String = "account", device: String = "tablet", epoch: Long = 8): SyncIdentityLease =
            SyncIdentityLease(account, device, epoch).also { source = TabletJoinPresentation.Source(it, epoch, true) }
    }

    @Test fun anAttachedOriginalCompletionShowsOnceWithoutWaitingForLiveOrAMacRoster() {
        val f = Fixture(); val owner = f.owner()
        val attempt = requireNotNull(owner.begin(owner.control()))
        val attached = f.attached()
        assertNull("An account appearing, including reconnect/live publication, is not a completion", owner.state.value.success)
        assertTrue(owner.joined(attempt, attached))
        val success = requireNotNull(owner.state.value.success)
        assertEquals(attached, success.identity); assertTrue(owner.current(success))
        assertFalse("Duplicate original callback is not another presentation", owner.joined(attempt, attached))
        assertTrue(owner.finish(success)); assertTrue(owner.state.value.finished)
        assertFalse(owner.finish(success)); assertNull(owner.state.value.success)
    }

    @Test fun aNewRecoveryAttemptPermanentlyReplacesTheCodeAttemptAndItsOldCancelControl() {
        val f = Fixture(); val owner = f.owner()
        val code = requireNotNull(owner.begin(owner.control()))
        val oldCancel = owner.control()
        val recovery = requireNotNull(owner.begin(owner.control()))
        assertFalse(owner.cancel(oldCancel))
        val attached = f.attached()
        assertFalse(owner.joined(code, attached)); assertNull(owner.state.value.success)
        assertTrue(owner.joined(recovery, attached))
    }

    @Test fun cancelledCompletionCannotShowIntoAFreshAttempt() {
        val f = Fixture(); val owner = f.owner()
        val cancelled = requireNotNull(owner.begin(owner.control()))
        assertTrue(owner.cancel(owner.control()))
        val fresh = requireNotNull(owner.begin(owner.control()))
        val attached = f.attached()
        assertFalse(owner.joined(cancelled, attached)); assertTrue(owner.joined(fresh, attached))
    }

    @Test fun closingAndReopeningNeverAdoptsTheOldAttemptOrItsSavedControl() {
        val f = Fixture(); val old = f.owner()
        val attempt = requireNotNull(old.begin(old.control())); val oldControl = old.control()
        old.close()
        val fresh = f.owner(); val newAttempt = requireNotNull(fresh.begin(fresh.control()))
        assertNull(old.begin(oldControl))
        val attached = f.attached()
        assertFalse(old.joined(attempt, attached)); assertNull(old.state.value.success)
        assertTrue(fresh.joined(newAttempt, attached))
    }

    @Test fun anObservedStoppedOrReplacedHostCannotReviveWhenTheHostPredicateReturnsTrue() {
        val f = Fixture(); val owner = f.owner()
        val attempt = requireNotNull(owner.begin(owner.control()))
        f.host = false; assertFalse(owner.available())
        f.host = true
        assertFalse(owner.joined(attempt, f.attached())); assertNull(owner.state.value.success)
        assertNull(owner.begin(owner.control()))
    }

    @Test fun accountDeviceEpochRemovalAndTheirAbaCannotFinishAnOriginalSuccess() {
        val original = SyncIdentityLease("account", "tablet", 8)
        for (changed in listOf(
            TabletJoinPresentation.Source(original.copy(account = "other"), 8, true),
            TabletJoinPresentation.Source(original.copy(device = "other"), 8, true),
            TabletJoinPresentation.Source(original.copy(epoch = 9), 9, true),
            TabletJoinPresentation.Source(original, 8, false),
        )) {
            val f = Fixture(); val owner = f.owner(); val attempt = requireNotNull(owner.begin(owner.control()))
            f.attached(); assertTrue(owner.joined(attempt, original))
            val success = requireNotNull(owner.state.value.success)
            f.source = changed; assertFalse(owner.current(success))
            f.source = TabletJoinPresentation.Source(original, 8, true)
            assertFalse(owner.current(success)); assertFalse(owner.finish(success))
        }
    }

    @Test fun disposedOrConsumedControlsCannotStartOrCancelAnotherAttempt() {
        val f = Fixture(); val owner = f.owner()
        val disposed = owner.control(); disposed.retire(); assertNull(owner.begin(disposed))
        val once = owner.control(); val attempt = requireNotNull(owner.begin(once))
        assertNull(owner.begin(once)); assertFalse(owner.cancel(once))
        assertTrue(owner.joined(attempt, f.attached()))
    }

    @Test fun oldUnpairedControlsDoNotCaptureANewSourceAndInvalidCompletionsCannotRetry() {
        val f = Fixture(); val owner = f.owner(); val old = owner.control()
        f.source = f.source.copy(epoch = 9)
        assertNull(owner.begin(old))
        val fresh = requireNotNull(owner.begin(owner.control()))
        val attached = f.attached(epoch = 10)
        assertFalse(owner.joined(fresh, attached.copy(account = "wrong")))
        assertFalse(owner.joined(fresh, attached)); assertNull(owner.state.value.success)
        val pairedOwner = f.owner()
        assertNull("An already paired account cannot manufacture a first-run attempt", pairedOwner.begin(pairedOwner.control()))
    }

    @Test fun tabletJoinUsesTheExisting700And600PolicyInPortraitAndThePhone520CardWidth() {
        assertTrue(TabletJoinSuccessGeometry.eligible(BrowserWorkspaceWindow(700.0, 1000.0), 600))
        assertTrue(TabletJoinSuccessGeometry.eligible(BrowserWorkspaceWindow(1280.0, 800.0), 600))
        assertFalse(TabletJoinSuccessGeometry.eligible(BrowserWorkspaceWindow(699.9, 1000.0), 600))
        assertFalse(TabletJoinSuccessGeometry.eligible(BrowserWorkspaceWindow(700.0, 1000.0), 599))
        assertFalse(TabletJoinSuccessGeometry.eligible(BrowserWorkspaceWindow(0.0, 1000.0), 600))
        assertEquals(520.0, TabletJoinSuccessGeometry.width(700.0), 0.0)
        assertEquals(452.0, TabletJoinSuccessGeometry.width(500.0), 0.0)
        assertEquals(1.0, TabletJoinSuccessGeometry.width(20.0), 0.0)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun actualControllerStopStartBeforeCallbackCannotBorrowTheResumedForeground() = runTest {
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}
            override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}
            override fun stop(tabId: String) {}
            override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val browser = BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal")), selectedSpaceId = "s")
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, backgroundScope)
        runCurrent()
        val original = browser.settingsPresentationLifetime.value
        val f = Fixture()
        val owner = TabletJoinPresentation({ f.source }, {
            browser.settingsPresentationLifetime.value == original && original.active
        })
        val attempt = requireNotNull(owner.begin(owner.control()))
        browser.backgrounded(); browser.foregrounded()
        assertTrue(browser.settingsPresentationLifetime.value.active)
        assertTrue(browser.settingsPresentationLifetime.value.generation > original.generation)
        // No false-host poll occurs during STOP: the old completion sees only the resumed host.
        assertFalse(owner.joined(attempt, f.attached()))
        assertNull(owner.state.value.success)
    }
}
