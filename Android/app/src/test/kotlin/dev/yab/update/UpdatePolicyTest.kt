package dev.yab.update

import org.junit.Assert.*
import org.junit.Test

class UpdatePolicyTest {
    private val hour = 60 * 60 * 1000L
    private fun offer(code: Int = 3, sha: String = "a".repeat(64), minSdk: Int = 29) = UpdateOffer(code, "0.1.$code", "https://yetanotherbrowser.com/android.apk", sha, minSdk)
    private fun after(record: UpdateRecord, offer: UpdateOffer, installed: Long = 2, sdk: Int = 36, now: Long = 1000, manual: Boolean = false) =
        UpdatePolicy.afterManifest(record, offer, installed, sdk, now, manual)

    @Test fun onlyAGreaterCodeOnASupportedSdkIsNewer() {
        assertTrue(UpdatePolicy.isNewer(offer(3), 2, 36))
        assertFalse(UpdatePolicy.isNewer(offer(2), 2, 36))
        assertFalse(UpdatePolicy.isNewer(offer(1), 2, 36))
        assertFalse(UpdatePolicy.isNewer(offer(3, minSdk = 37), 2, 36))
        assertTrue(UpdatePolicy.isNewer(offer(3, minSdk = 36), 2, 36))
    }

    @Test fun backoffDoublesAndStopsAtAWeek() {
        assertEquals(6 * hour, UpdatePolicy.retryDelay(1))
        assertEquals(12 * hour, UpdatePolicy.retryDelay(2))
        assertEquals(24 * hour, UpdatePolicy.retryDelay(3))
        assertEquals(96 * hour, UpdatePolicy.retryDelay(5))
        assertEquals(168 * hour, UpdatePolicy.retryDelay(6))
        assertEquals(168 * hour, UpdatePolicy.retryDelay(5000))
        assertEquals(6 * hour, UpdatePolicy.retryDelay(0))
    }

    @Test fun aFailedVersionWaitsForANewerOneOrALaterLaunchPastItsBackoff() {
        val failure = UpdatePolicy.failed(null, 3, now = 0, launch = 4)
        assertEquals(1, failure.attempts)
        assertFalse("same launch, even late", UpdatePolicy.mayTry(failure, 3, 100 * hour, 4))
        assertFalse("next launch, too soon", UpdatePolicy.mayTry(failure, 3, 5 * hour, 5))
        assertTrue(UpdatePolicy.mayTry(failure, 3, 6 * hour, 5))
        assertTrue("a newer version goes at once", UpdatePolicy.mayTry(failure, 4, 1, 4))
        assertFalse("an older one never", UpdatePolicy.mayTry(failure, 2, 100 * hour, 9))
        assertTrue(UpdatePolicy.mayTry(null, 3, 0, 0))
    }

    @Test fun attemptsCountPerVersion() {
        val twice = UpdatePolicy.failed(UpdatePolicy.failed(null, 3, 0, 1), 3, 0, 2)
        assertEquals(2, twice.attempts)
        assertEquals(12 * hour, twice.notBefore)
        assertEquals(1, UpdatePolicy.failed(twice, 4, 0, 2).attempts)
    }

    @Test fun aNewerOfferStartsADownload() {
        val decision = after(UpdateRecord(launch = 7), offer())
        assertEquals(UpdateAction.DOWNLOAD, decision.action)
        assertEquals(UpdateStage.DOWNLOADING, decision.record.stage)
        assertEquals(offer(), decision.record.offer)
        assertEquals(7, decision.record.launch)
    }

    @Test fun theSameVersionDoesNothing() {
        val record = UpdateRecord()
        val decision = after(record, offer(2))
        assertEquals(UpdateAction.NOTHING, decision.action)
        assertEquals(record, decision.record)
        assertFalse(decision.discard)
    }

    @Test fun repeatedCheckResumesInsteadOfRestarting() {
        val downloading = UpdateRecord(offer(), UpdateStage.DOWNLOADING)
        assertEquals(UpdateDecision(downloading, UpdateAction.DOWNLOAD), after(downloading, offer()))
        val ready = UpdateRecord(offer(), UpdateStage.READY)
        assertEquals(UpdateDecision(ready, UpdateAction.APPLY), after(ready, offer()))
    }

    @Test fun aNewerOrChangedOfferReplacesWaitingWork() {
        val decision = after(UpdateRecord(offer(3), UpdateStage.READY), offer(4))
        assertEquals(offer(4), decision.record.offer)
        assertTrue(decision.discard)
        assertEquals(UpdateAction.DOWNLOAD, decision.action)
        assertTrue(after(UpdateRecord(offer(3), UpdateStage.DOWNLOADING), offer(3, "b".repeat(64))).discard)
    }

    @Test fun aWithdrawnOfferDropsWaitingWork() {
        val decision = after(UpdateRecord(offer(3), UpdateStage.READY), offer(2))
        assertNull(decision.record.offer)
        assertEquals(UpdateStage.NONE, decision.record.stage)
        assertTrue(decision.discard)
    }

    @Test fun nothingInterruptsTheSystemsHands() {
        listOf(UpdateStage.INSTALLING, UpdateStage.NEEDS_PROMPT, UpdateStage.PROMPTED).forEach {
            val record = UpdateRecord(offer(3), it, session = 9)
            assertEquals(UpdateDecision(record, UpdateAction.NOTHING), after(record, offer(4)))
            assertEquals(UpdateDecision(record, UpdateAction.NOTHING), after(record, offer(2)))
        }
    }

    @Test fun aFailedVersionIsNotRetriedByAPeriodicCheck() {
        val failed = UpdatePolicy.fail(UpdateRecord(offer(3), UpdateStage.INSTALLING, session = 9, launch = 2), 0)
        assertNull(failed.offer)
        assertEquals(-1, failed.session)
        val same = after(failed, offer(3), now = 500 * hour)
        assertEquals(UpdateAction.NOTHING, same.action)
        assertEquals(failed, same.record)
        val nextLaunch = after(failed.copy(launch = 3), offer(3), now = 5 * hour)
        assertEquals(UpdateAction.NOTHING, nextLaunch.action)
        assertEquals(UpdateAction.DOWNLOAD, after(failed.copy(launch = 3), offer(3), now = 6 * hour).action)
        assertEquals(UpdateAction.DOWNLOAD, after(failed, offer(4)).action)
    }

    @Test fun aPersonAskingClearsTheBackoffOnce() {
        val failed = UpdatePolicy.fail(UpdateRecord(offer(3), UpdateStage.DOWNLOADING, launch = 2), 0)
        val decision = after(failed, offer(3), manual = true)
        assertEquals(UpdateAction.DOWNLOAD, decision.action)
        assertNull(decision.record.failure)
    }

    @Test fun anInstalledVersionClearsItsWork() {
        val decision = UpdatePolicy.reconcile(UpdateRecord(offer(3), UpdateStage.INSTALLING, session = 9, launch = 5), 3, false, 0)
        assertEquals(UpdateRecord(launch = 5), decision.record)
        assertTrue(decision.discard)
    }

    @Test fun aSessionTheSystemLostCountsAsAFailure() {
        val decision = UpdatePolicy.reconcile(UpdateRecord(offer(3), UpdateStage.INSTALLING, session = 9), 2, false, 0)
        assertEquals(3, decision.record.failure?.versionCode)
        assertEquals(UpdateStage.NONE, decision.record.stage)
    }

    @Test fun aWaitingPromptSurvivesARestart() {
        val record = UpdateRecord(offer(3), UpdateStage.NEEDS_PROMPT, session = 9, prompt = "intent:#Intent;end")
        assertEquals(record, UpdatePolicy.reconcile(record, 2, true, 0).record)
    }

    @Test fun aReadyApkIsAppliedAfterARestart() {
        assertEquals(UpdateAction.APPLY, UpdatePolicy.reconcile(UpdateRecord(offer(3), UpdateStage.READY), 2, false, 0).action)
    }

    @Test fun aPromptNobodyAnsweredExpiresWithTheLaunch() {
        val shown = UpdateRecord(offer(3), UpdateStage.PROMPTED, session = 9, promptLaunch = 4, launch = 4)
        assertFalse(UpdatePolicy.promptExpired(shown))
        assertTrue(UpdatePolicy.promptExpired(shown.copy(launch = 5)))
    }
}
