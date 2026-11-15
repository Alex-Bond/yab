package dev.yab.android

import dev.yab.browser.model.*
import dev.yab.sync.SyncIdentityLease
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Pure UI ownership. Test callbacks never qualify genuine pairing or a native role grant. */
class FirstRunPresentationTest {
    private class Fixture(savedIdentity: Boolean = false) {
        var source = TabletJoinPresentation.Source(if (savedIdentity) SyncIdentityLease("saved-account", "saved-device", 4) else null, 4, true)
        var generation = 0L
        var token = Any()
        var active = true
        var code: String? = null
        val flow = FirstRunPresentation({ source }, { code })
        var callback: ((SyncIdentityLease) -> Unit)? = null
        var failureCallback: (() -> Unit)? = null
        var joins = 0
        var recoveries = 0
        var finishes = 0
        var newTabs = 0
        var requests = 0
        val cancelled = mutableListOf<String>()
        val role = FirstRunPresentation.DefaultBrowser(available = true, held = false)
        fun host(): FirstRunPresentation.Host {
            val capturedGeneration = generation; val capturedToken = token
            return FirstRunPresentation.Host { active && generation == capturedGeneration && token === capturedToken }
        }
        fun control(host: FirstRunPresentation.Host = host(), recovery: Boolean = false) = flow.control(host, recovery)
        fun timer(host: FirstRunPresentation.Host = host(), animationsDisabled: Boolean = false) = requireNotNull(flow.timer(host, animationsDisabled))
        fun finish(value: FirstRunPresentation.Completion): Boolean {
            if (!value.current { source }) return false
            finishes++; if (value.withoutMac) newTabs++
            return true
        }
        fun start(done: (SyncIdentityLease) -> Unit, failed: () -> Unit) { joins++; callback = done; failureCallback = failed }
        fun restore(text: String, done: (SyncIdentityLease) -> Unit, failed: () -> Unit) { assertTrue(text.isNotBlank()); recoveries++; callback = done; failureCallback = failed }
        fun choose(animationsDisabled: Boolean = false) {
            assertTrue(flow.begin(control()))
            val timer = timer(animationsDisabled = animationsDisabled)
            assertEquals(if (animationsDisabled) 0 else 1_300, timer.delayMillis.toInt())
            assertTrue(flow.advance(timer, role, ::finish))
            assertEquals(FirstRunPresentation.Step.CHOOSE, flow.state.value.step)
        }
        fun noMac() { choose(); assertTrue(flow.chooseNoMac(control())); assertTrue(flow.useWithoutMac(control())) }
        fun links() { noMac(); assertTrue(flow.advance(timer(), role, ::finish)); assertEquals(FirstRunPresentation.Step.LINKS, flow.state.value.step) }
        fun attach(): SyncIdentityLease {
            val identity = SyncIdentityLease("actual-test-account", "actual-test-device", source.epoch + 1)
            source = TabletJoinPresentation.Source(identity, identity.epoch, true)
            return identity
        }
        fun joined() {
            choose(); assertTrue(flow.chooseMac(control(), ::start)); val identity = attach(); callback!!(identity)
            assertEquals(FirstRunPresentation.Step.JOINED, flow.state.value.step)
        }
    }

    @Test fun withoutMacTakesLinksThenExactlyOneFreshNewTabAndNeverStartsPairing() {
        val f = Fixture(); f.noMac()
        assertEquals(400, f.timer().delayMillis.toInt()); assertEquals(0, f.finishes)
        assertTrue(f.flow.advance(f.timer(), f.role, f::finish))
        val old = f.control(); assertTrue(f.flow.notNow(old))
        assertEquals(200, f.timer().delayMillis.toInt()); assertEquals(0, f.finishes)
        assertTrue(f.flow.advance(f.timer(), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        assertEquals(1, f.finishes); assertEquals(1, f.newTabs)
        assertEquals(0, f.joins); assertEquals(0, f.recoveries); assertEquals(0, f.requests)
        assertFalse(f.flow.notNow(old)); assertEquals(1, f.finishes)
    }

    @Test fun originalCompletionGoesThrough1400And400And200ToGuideInsteadOfOrdinarySettings() {
        val f = Fixture(); f.joined()
        assertEquals(1_400, f.timer().delayMillis.toInt())
        assertTrue(f.flow.advance(f.timer(), f.role, f::finish))
        assertEquals(400, f.timer().delayMillis.toInt())
        assertTrue(f.flow.advance(f.timer(), f.role, f::finish)); assertTrue(f.flow.notNow(f.control()))
        assertEquals(200, f.timer().delayMillis.toInt()); assertTrue(f.flow.advance(f.timer(), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.GUIDE, f.flow.state.value.step); assertEquals(0, f.finishes)
        assertTrue(f.flow.finishGuide(f.control(), f::finish)); assertEquals(1, f.finishes); assertEquals(0, f.newTabs)
    }

    @Test fun nativeAnimationsDisabledSkipsEveryFirstRunPauseWithoutChangingThePath() {
        for (animationsDisabled in listOf(false, true)) {
            val f = Fixture(); f.choose(animationsDisabled = animationsDisabled)
            assertTrue(f.flow.chooseMac(f.control(), f::start)); f.callback!!(f.attach())
            for ((step, pause) in listOf(FirstRunPresentation.Step.JOINED to 1_400L, FirstRunPresentation.Step.TO_LINKS to 400L)) {
                assertEquals(step, f.flow.state.value.step)
                val timer = f.timer(animationsDisabled = animationsDisabled)
                assertEquals(if (animationsDisabled) 0L else pause, timer.delayMillis)
                assertTrue(f.flow.advance(timer, f.role, f::finish))
            }
            assertTrue(f.flow.notNow(f.control()))
            val timer = f.timer(animationsDisabled = animationsDisabled)
            assertEquals(if (animationsDisabled) 0L else 200L, timer.delayMillis)
            assertTrue(f.flow.advance(timer, f.role, f::finish))
            assertEquals(FirstRunPresentation.Step.GUIDE, f.flow.state.value.step)
            assertEquals(1, f.joins); assertEquals(0, f.finishes)

            val saved = Fixture(savedIdentity = true); val host = saved.host()
            assertTrue(saved.flow.begin(saved.control(host)))
            val welcome = saved.timer(host, animationsDisabled)
            assertEquals(if (animationsDisabled) 0L else 1_300L, welcome.delayMillis)
            assertTrue(saved.flow.advance(welcome, saved.role, saved::finish))
            assertEquals(FirstRunPresentation.Step.FOUND, saved.flow.state.value.step)
            assertTrue(saved.flow.joinSaved(saved.control(host), FirstRunPresentation.FoundCounts(2, 0, 0)))
            repeat(8) {
                val found = saved.timer(host, animationsDisabled)
                assertEquals(if (animationsDisabled) 0L else 100L, found.delayMillis)
                assertTrue(saved.flow.advance(found, saved.role, saved::finish))
            }
            assertEquals(FirstRunPresentation.Step.JOINED, saved.flow.state.value.step)
            assertEquals(0, saved.joins); assertEquals(0, saved.finishes)
        }
    }

    @Test fun heldOrUnavailableRoleSkipsTheQuestionWithoutRequestingASystemAction() {
        for (role in listOf(FirstRunPresentation.DefaultBrowser(true, true), FirstRunPresentation.DefaultBrowser(false, false))) {
            val f = Fixture(); f.noMac(); assertTrue(f.flow.advance(f.timer(), role, f::finish))
            assertEquals(FirstRunPresentation.Step.LEAVING_LINKS, f.flow.state.value.step)
            assertFalse(f.flow.makeDefault(f.control(), role) { f.requests++ })
            assertTrue(f.flow.advance(f.timer(), role, f::finish)); assertEquals(0, f.requests); assertEquals(1, f.newTabs)
        }
    }

    @Test fun defaultTapAdvancesBeforeTheOsCoverAndNeverWaitsForOrClaimsARoleResult() {
        val f = Fixture(); f.links(); val host = f.host(); val old = f.control(host)
        assertTrue(f.flow.makeDefault(old, f.role) {
            assertEquals(FirstRunPresentation.Step.LEAVING_LINKS, f.flow.state.value.step)
            f.requests++; f.generation++
        })
        assertEquals(1, f.requests); assertFalse(f.flow.makeDefault(old, f.role) { f.requests++ })
        // The VM keeps the accepted logical step. A fresh render, not an old role result, owns continuation.
        assertNull(f.flow.control(host)); val freshTimer = f.timer()
        assertTrue(f.flow.advance(freshTimer, f.role, f::finish)); assertEquals(1, f.newTabs)
        assertEquals(1, f.requests)
    }

    @Test fun oldTimerCannotAdvanceAfterAnUnobservedForegroundAbaOrAWindowReplacement() {
        for (replace in listOf(false, true)) {
            val f = Fixture(); f.noMac(); val old = f.timer()
            if (replace) f.token = Any() else f.generation++
            assertFalse(f.flow.advance(old, f.role, f::finish))
            assertEquals(FirstRunPresentation.Step.TO_LINKS, f.flow.state.value.step)
            assertTrue(f.flow.advance(f.timer(), f.role, f::finish))
        }
    }

    @Test fun lateOriginalJoinAfterStopCannotAdoptTheNowResumedHost() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val old = requireNotNull(f.callback); f.generation++; val identity = f.attach(); old(identity)
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        assertFalse(f.flow.state.value.step == FirstRunPresentation.Step.JOINED)
        assertEquals(0, f.finishes)
    }

    @Test fun cancellationRetiresTheAttemptBeforeTheOriginalCodeIsSentToCancel() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start)); val callback = f.callback!!
        f.code = "EXACT-ORIGINAL"; f.flow.observeCode(f.host(), f.code)
        assertTrue(f.flow.back(f.control(), "EXACT-ORIGINAL", { f.cancelled += it }, f::start))
        assertEquals(listOf("EXACT-ORIGINAL"), f.cancelled)
        callback(f.attach()); assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
    }

    @Test fun recoveryReplacesTheCodeAttemptAndOnlyTheNewOriginalCompletionCanShowJoined() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start)); val old = f.callback!!
        assertTrue(f.flow.useRecovery(f.control())); val input = f.flow.input(f.host())
        assertTrue(f.flow.editRecovery(input, "owned fixture recovery")); val text = f.flow.state.value.recovery
        assertTrue(f.flow.restore(f.control(recovery = true), text, f::restore)); val fresh = f.callback!!; val identity = f.attach()
        old(identity); assertEquals(FirstRunPresentation.Step.RECOVERY, f.flow.state.value.step)
        fresh(identity); assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
        fresh(identity); assertEquals(1, f.recoveries)
    }

    @Test fun recoveryTextAbaInvalidatesTheSavedButtonButPreservesTheSameCurrentEditor() {
        val f = Fixture(); f.choose(); f.flow.chooseMac(f.control(), f::start); f.flow.useRecovery(f.control())
        val host = f.host(); val input = f.flow.input(host)
        assertTrue(f.flow.editRecovery(input, "first")); val old = f.control(host, recovery = true)
        assertTrue(f.flow.editRecovery(input, "second")); assertTrue(f.flow.editRecovery(input, "first"))
        assertFalse(f.flow.restore(old, "first", f::restore)); assertEquals(0, f.recoveries)
        assertTrue(f.flow.restore(f.control(host, recovery = true), "first", f::restore)); assertEquals(1, f.recoveries)
        assertFalse(f.flow.editRecovery(input, "late editor"))
    }

    @Test fun currentInputReturnCanSubmitItsJustEditedValueWithoutCapturingANewButton() {
        val f = Fixture(); f.choose(); f.flow.chooseMac(f.control(), f::start); f.flow.useRecovery(f.control())
        val input = f.flow.input(f.host()); assertTrue(f.flow.editRecovery(input, "typed on the current editor"))
        assertTrue(f.flow.restoreFromInput(input, "typed on the current editor", f::restore)); assertEquals(1, f.recoveries)
        assertFalse(f.flow.restoreFromInput(input, "typed on the current editor", f::restore)); assertEquals(1, f.recoveries)
    }

    @Test fun accountEpochAndRemovalDoNotBorrowThePreviouslyRenderedLinksControl() {
        for (change in listOf("epoch", "device", "removed")) {
            val f = Fixture(); f.joined(); f.flow.advance(f.timer(), f.role, f::finish); f.flow.advance(f.timer(), f.role, f::finish)
            val old = f.control(); val identity = requireNotNull(f.source.identity)
            f.source = when (change) {
                "epoch" -> f.source.copy(epoch = f.source.epoch + 2, identity = identity.copy(epoch = identity.epoch + 2))
                "device" -> f.source.copy(identity = identity.copy(device = "replacement"))
                else -> f.source.copy(available = false)
            }
            assertFalse(f.flow.notNow(old)); assertEquals(FirstRunPresentation.Step.LINKS, f.flow.state.value.step)
        }
    }

    @Test fun copiedOrDisposedControlsCannotBorrowASubsequentStateOrReopenedJourney() {
        val f = Fixture(); f.choose(); val copy = f.control(); val values = mutableListOf<String>()
        assertTrue(f.flow.copy(copy, "https://yetanotherbrowser.com", { values.add(it) }))
        assertFalse(f.flow.copy(copy, "another", { values.add(it) })); assertEquals(1, values.size)
        val retired = f.control(); retired!!.retire(); assertFalse(f.flow.chooseNoMac(retired))
        val old = f.control(); f.flow.close(); val reopened = FirstRunPresentation({ f.source }, { f.code })
        assertFalse(reopened.chooseNoMac(old)); assertFalse(f.flow.chooseNoMac(old))
        val first = Fixture(); val second = Fixture(); first.choose(); second.choose()
        val foreign = first.control()
        assertFalse(second.flow.chooseNoMac(foreign))
        assertTrue(first.flow.chooseNoMac(foreign))
    }

    @Test fun completionRechecksItsOriginalSourceBeforeAnyWelcomedOrNewTabWrite() {
        val f = Fixture(); f.links(); f.flow.notNow(f.control())
        var writes = 0
        assertFalse(f.flow.advance(f.timer(), f.role, finish = { completion ->
            f.generation++
            if (completion.current { f.source }) { writes++; true } else false
        }))
        assertEquals(0, writes); assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test fun actualControllerStopStartWithoutAnInactivePollRetiresTheOriginalAction() = runTest {
        val engine = object : BrowserEngine {
            override fun activate(tab: BrowserTab, profile: WebsiteProfile) {}
            override fun navigate(tab: BrowserTab, url: String, profile: WebsiteProfile) {}
            override fun goBack(tabId: String) {}; override fun goForward(tabId: String) {}
            override fun reload(tabId: String) {}; override fun stop(tabId: String) {}; override fun close(tabId: String) {}
            override suspend fun clearWebsiteData(profileIds: Set<String>) {}
        }
        val controller = BrowserController(object : BrowserRepository {
            override suspend fun load() = BrowserSnapshot(spaces = listOf(BrowserSpace("s", "Personal")), selectedSpaceId = "s")
            override suspend fun save(snapshot: BrowserSnapshot) {}
        }, engine, backgroundScope)
        runCurrent(); val original = controller.settingsPresentationLifetime.value
        val f = Fixture(); f.choose()
        val host = FirstRunPresentation.Host { controller.settingsPresentationLifetime.value == original && original.active }
        val old = f.control(host); controller.backgrounded(); controller.foregrounded()
        assertTrue(controller.settingsPresentationLifetime.value.active)
        assertTrue(controller.settingsPresentationLifetime.value.generation > original.generation)
        assertFalse(f.flow.chooseMac(old, f::start)); assertEquals(0, f.joins)
    }
    @Test fun anInputThatObservedLostHostCannotReviveWhenTheSameBooleanReturns() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        assertTrue(f.flow.useRecovery(f.control())); val original = f.host()
        val input = requireNotNull(f.flow.input(original))
        assertTrue(f.flow.editRecovery(input, "first"))
        f.active = false; assertFalse(f.flow.editRecovery(input, "blocked"))
        f.active = true; assertFalse(f.flow.editRecovery(input, "revived"))
        assertEquals("first", f.flow.state.value.recovery)
        assertTrue(f.flow.editRecovery(f.flow.input(f.host()), "fresh"))
        assertEquals("fresh", f.flow.state.value.recovery)
    }

    @Test fun originalCompletionThatObservedLostHostCannotReplayWithoutAnObserveCall() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val original = requireNotNull(f.callback); val identity = f.attach()
        f.active = false; original(identity)
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        f.active = true; original(identity)
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        assertEquals(0, f.finishes)
    }

    @Test fun rotatedCodeCannotBeCancelledOrCopiedByAnOldControlBeforeItsNextRender() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        f.code = "AAAA-BBBB"; f.flow.observeCode(f.host(), f.code)
        val old = f.control(); f.code = "CCCC-DDDD"
        assertFalse(f.flow.back(old, "AAAA-BBBB", { f.cancelled += it }, f::start))
        assertFalse(f.flow.copy(old, "AAAA-BBBB") { fail("stale copy") })
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        assertTrue(f.cancelled.isEmpty()); f.flow.observeCode(f.host(), f.code)
        assertTrue(f.flow.back(f.control(), "CCCC-DDDD", { f.cancelled += it }, f::start))
        assertEquals(listOf("CCCC-DDDD"), f.cancelled)
    }

    @Test fun codeAbaRetiresCodeActionsButPreservesTheRecoveryEditorsOriginalInput() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        f.code = "AAAA-BBBB"; f.flow.observeCode(f.host(), f.code); val old = f.control()
        f.code = "CCCC-DDDD"; f.flow.observeCode(f.host(), f.code)
        f.code = "AAAA-BBBB"; f.flow.observeCode(f.host(), f.code)
        assertFalse(f.flow.back(old, "AAAA-BBBB", { f.cancelled += it }, f::start))
        assertFalse(f.flow.copy(old, "AAAA-BBBB") { fail("stale copy") })
        assertTrue(f.flow.useRecovery(f.control())); val input = requireNotNull(f.flow.input(f.host()))
        assertTrue(f.flow.editRecovery(input, "typed original"))
        f.code = "EEEE-FFFF"; f.flow.observeCode(f.host(), f.code)
        assertTrue(f.flow.editRecovery(input, "typed still current"))
        assertEquals("typed still current", f.flow.state.value.recovery)
    }

    @Test fun pendingCodeWithoutAnOriginalOperationKeyCannotAbandonTheLiveRequest() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        assertFalse(f.flow.back(f.control(), null, { fail("no original key") }, f::start))
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        f.callback!!(f.attach()); assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
    }

    @Test fun savedRealIdentityRequiresFreshFoundJoinThenUsesOnlyActualPublicCounts() {
        val f = Fixture(savedIdentity = true); val host = f.host()
        assertTrue(f.flow.begin(f.control(host))); assertTrue(f.flow.advance(f.timer(host), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.FOUND, f.flow.state.value.step); assertEquals(0, f.joins)
        val spaces = listOf(BrowserSpace("public", "Personal", tabs = listOf(
            BrowserTab("today", createdAt = 0), BrowserTab("kept", place = TabPlace.KEPT, createdAt = 0, folderId = "inner"),
            BrowserTab("pin", place = TabPlace.PINNED, createdAt = 0), BrowserTab("private-tab", isPrivate = true, createdAt = 0)),
            folders = listOf(BrowserFolder("outer", "Outer"), BrowserFolder("inner", "Inner", parentId = "outer"))),
            BrowserSpace("private", "Private", isPrivate = true, tabs = listOf(BrowserTab("hidden", createdAt = 0)),
                folders = listOf(BrowserFolder("secret", "Secret"))))
        val counts = FirstRunPresentation.FoundCounts.from(spaces)
        assertEquals(FirstRunPresentation.FoundCounts(2, 1, 2), counts)
        assertTrue(f.flow.joinSaved(f.control(host), counts)); var successHaptics = 0
        repeat(8) {
            assertEquals(100L, f.timer(host).delayMillis)
            assertTrue(f.flow.advance(f.timer(host), f.role, f::finish) { successHaptics++ })
        }
        assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
        assertEquals(2, f.flow.state.value.counted); assertEquals(1, successHaptics)
        assertEquals(0, f.joins); assertEquals(0, f.recoveries); assertEquals(0, f.finishes)
        assertTrue(f.flow.advance(f.timer(host), f.role, f::finish))
        assertTrue(f.flow.advance(f.timer(host), f.role, f::finish))
        assertTrue(f.flow.notNow(f.control(host))); assertTrue(f.flow.advance(f.timer(host), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.GUIDE, f.flow.state.value.step)
        assertTrue(f.flow.finishGuide(f.control(host), f::finish)); assertEquals(0, f.newTabs)
    }

    @Test fun foundCountingNeverBorrowsANewNativeHostAndRequiresANewJoinTapAfterStop() {
        val f = Fixture(savedIdentity = true); val oldHost = f.host()
        assertTrue(f.flow.begin(f.control(oldHost))); f.flow.advance(f.timer(oldHost), f.role, f::finish)
        assertTrue(f.flow.joinSaved(f.control(oldHost), FirstRunPresentation.FoundCounts(20, 2, 3)))
        val oldTimer = f.timer(oldHost); f.generation++
        val freshHost = f.host(); assertNull(f.flow.timer(freshHost, animationsDisabled = false))
        f.flow.observe(freshHost); assertFalse(f.flow.advance(oldTimer, f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.FOUND, f.flow.state.value.step)
        assertFalse(f.flow.state.value.counting); assertEquals(0, f.flow.state.value.counted)
        assertNull(f.flow.timer(freshHost, animationsDisabled = false))
        assertTrue(f.flow.joinSaved(f.control(freshHost), FirstRunPresentation.FoundCounts(2, 0, 0)))
        repeat(8) { assertTrue(f.flow.advance(f.timer(freshHost, animationsDisabled = true), f.role, f::finish)) }
        assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
    }

    @Test fun aGenuineLateJoinAfterStopCannotFakeJoinedButAFreshJourneyCanOfferItsSavedIdentity() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val old = requireNotNull(f.callback); f.generation++; val identity = f.attach(); old(identity)
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        f.flow.observe(f.host()); assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        val fresh = FirstRunPresentation({ f.source }, { f.code }); val host = f.host()
        assertTrue(fresh.begin(fresh.control(host)))
        assertTrue(fresh.advance(requireNotNull(fresh.timer(host, false)), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.FOUND, fresh.state.value.step)
        assertFalse(fresh.state.value.counting); assertEquals(0, f.finishes)
    }

    @Test fun onlyTheOriginalTerminalFailureAllowsLocalBackWithoutAnUnknownPendingCode() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val oldPending = f.control(); val failed = requireNotNull(f.failureCallback)
        assertFalse(f.flow.back(oldPending, null, { fail("unknown cancel") }, f::start))
        failed(); val revision = f.flow.state.value.failureRevision; failed()
        assertEquals(revision, f.flow.state.value.failureRevision)
        assertTrue(f.flow.back(f.control(), null, { fail("completed operation has no cancel key") }, f::start))
        assertEquals(FirstRunPresentation.Step.CHOOSE, f.flow.state.value.step)
        assertTrue(f.cancelled.isEmpty()); assertEquals(0, f.finishes)
    }

    @Test fun anOldFailureCannotRetireOrCompleteTheNewRecoveryAttempt() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val oldFailure = requireNotNull(f.failureCallback)
        assertTrue(f.flow.useRecovery(f.control())); val input = requireNotNull(f.flow.input(f.host()))
        assertTrue(f.flow.editRecovery(input, "current recovery"))
        assertTrue(f.flow.restore(f.control(recovery = true), "current recovery", f::restore))
        oldFailure(); assertEquals(0L, f.flow.state.value.failureRevision)
        requireNotNull(f.callback)(f.attach()); assertEquals(FirstRunPresentation.Step.JOINED, f.flow.state.value.step)
    }

    @Test fun failureAfterLostOriginalHostCannotReviveAndACompletedFailureCannotBecomeSuccess() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val oldFailure = requireNotNull(f.failureCallback); val oldSuccess = requireNotNull(f.callback)
        f.active = false; oldFailure(); f.active = true; oldFailure(); oldSuccess(f.attach())
        assertEquals(FirstRunPresentation.Step.CODE, f.flow.state.value.step)
        val fresh = Fixture(); fresh.choose(); fresh.flow.chooseMac(fresh.control(), fresh::start)
        requireNotNull(fresh.failureCallback)(); requireNotNull(fresh.callback)(fresh.attach())
        assertEquals(FirstRunPresentation.Step.CODE, fresh.flow.state.value.step)
    }

    @Test fun partialSavedIdentityFailureClosesOnlyItsOriginalAttemptAndFreshFoundNeedsCurrentPublication() {
        val f = Fixture(); f.choose(); assertTrue(f.flow.chooseMac(f.control(), f::start))
        val oldFailure = requireNotNull(f.failureCallback); val oldSuccess = requireNotNull(f.callback)
        val saved = SyncIdentityLease("partially-saved-account", "partially-saved-device", f.source.epoch + 1)
        f.source = TabletJoinPresentation.Source(saved, saved.epoch, available = false)
        oldFailure()
        assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        assertFalse(f.flow.state.value.trayUp); assertEquals(0, f.finishes)
        oldFailure(); oldSuccess(saved)
        assertEquals(FirstRunPresentation.Step.FINISHED, f.flow.state.value.step)
        val unavailable = FirstRunPresentation({ f.source }, { f.code })
        assertNull(unavailable.control(f.host())); unavailable.close()
        // Only a legitimate later native publication enables a separate fresh journey.
        f.source = f.source.copy(available = true)
        val fresh = FirstRunPresentation({ f.source }, { f.code }); val host = f.host()
        assertTrue(fresh.begin(fresh.control(host)))
        assertTrue(fresh.advance(requireNotNull(fresh.timer(host, false)), f.role, f::finish))
        assertEquals(FirstRunPresentation.Step.FOUND, fresh.state.value.step)
        assertFalse(fresh.state.value.counting); assertEquals(0, f.finishes)
        oldFailure(); oldSuccess(saved)
        assertEquals(FirstRunPresentation.Step.FOUND, fresh.state.value.step)
    }

}
