package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ApprovalDetailMotionTest {
    private val owner = ApprovalPresentationKey("account", 1, "mac", "question", "exact-facts", 1)
    private fun target(kind: ApprovalDetailKind = ApprovalDetailKind.MAIL) = ApprovalDetailTarget(owner, kind, "row", 0)
    @Test fun originalWindowAndPictureCancelTokenReturnsAnOversizedPullWithoutClosing() {
        for (kind in ApprovalDetailKind.entries) {
            val motion = ApprovalDetailPresentation(); motion.open(target(kind), owner, false)
            val token = checkNotNull(motion.beginDrag(owner)); motion.drag(owner, 200.0, expected = token)
            assertTrue(motion.cancel(token)); assertFalse(motion.cancel(token))
            assertTrue(motion.frame.value.opening)
            repeat(360) { motion.advance(1.0 / 120) }
            assertNotNull(motion.frame.value.target); assertEquals(0.0, motion.frame.value.drag, 0.0)
        }
    }
    @Test fun sameOwnerFreshPullAndNewTargetCannotBeResetByOldWindowOrPictureCancel() {
        for (kind in ApprovalDetailKind.entries) {
            val motion = ApprovalDetailPresentation(); motion.open(target(kind), owner, false)
            val old = checkNotNull(motion.beginDrag(owner)); motion.drag(owner, 40.0, expected = old)
            val fresh = checkNotNull(motion.beginDrag(owner)); motion.drag(owner, 12.0, expected = fresh)
            val held = motion.frame.value
            assertFalse(motion.cancel(old)); motion.drag(owner, 1000.0, expected = old)
            assertFalse(motion.releaseDrag(owner, 900.0, expected = old))
            assertEquals(held, motion.frame.value); assertTrue(motion.gestureCurrent(fresh))
            assertTrue(motion.cancel(fresh)); assertFalse(motion.gestureCurrent(fresh))
            val closing = checkNotNull(motion.beginDrag(owner)); motion.close(owner)
            assertFalse(motion.cancel(closing))
            motion.open(target(kind).copy(anchor = "replacement"), owner, false)
            assertFalse(motion.cancel(closing))
            val revoked = checkNotNull(motion.beginDrag(owner)); motion.reconcile(owner.copy(epoch = 2), false)
            assertFalse(motion.cancel(revoked)); assertNull(motion.frame.value.target)
        }
    }
    @Test fun leavingReducedMotionSettlesTheHeldOriginalBeforeRetiringItsToken() {
        for (kind in ApprovalDetailKind.entries) {
            val motion = ApprovalDetailPresentation(); motion.open(target(kind), owner, true)
            repeat(30) { motion.advance(1.0 / 60) }
            val old = checkNotNull(motion.beginDrag(owner)); motion.drag(owner, 200.0, expected = old)
            assertEquals(200.0, motion.frame.value.drag, 0.0)
            motion.reconcile(owner, false)
            assertFalse(motion.cancel(old)); assertEquals(0.0, motion.frame.value.drag, 0.0)
            assertTrue(motion.frame.value.opening); assertNotNull(motion.frame.value.target)
            val fresh = checkNotNull(motion.beginDrag(owner)); motion.drag(owner, 20.0, expected = fresh)
            assertTrue(motion.cancel(fresh)); assertTrue(motion.frame.value.opening)
        }
    }
    @Test fun theFirstWindowFrameIsTheActualRowAndTheLastIsUnderTheStatusBar() {
        val row = ApprovalRect(24.0, 420.0, 342.0, 64.0)
        val open = ApprovalRect(8.0, 55.0, 374.0, 781.0)
        assertEquals(row, ApprovalDetailGeometry.window(row, open, 0.0))
        assertEquals(open, ApprovalDetailGeometry.window(row, open, 1.0))
        assertEquals(ApprovalRect(16.0, 237.5, 358.0, 422.5), ApprovalDetailGeometry.window(row, open, .5))
        assertEquals(0.0, ApprovalDetailGeometry.windowWords(.08), 0.0)
        assertEquals(1.0, ApprovalDetailGeometry.windowWords(.38), 1e-12)
        assertEquals(0.0, ApprovalDetailGeometry.windowGhost(.33), 0.0)
        assertEquals(1.0, ApprovalDetailGeometry.windowGround(.3), 0.0)
    }
    @Test fun originalDimensionsAndRealPaperFallbackDeterminePictureFit() {
        val wide = ApprovalDetailGeometry.fitPicture(390.0, 844.0, 47.0, true, 1600, 800)
        assertEquals(358.0, wide.width, 0.0); assertEquals(179.0, wide.height, 0.0)
        assertEquals(16.0, wide.x, 0.0)
        val image = ApprovalDetailGeometry.fitPicture(390.0, 844.0, 47.0, true)
        assertEquals(358.0, image.height, 0.0)
        val pdf = ApprovalDetailGeometry.fitPicture(390.0, 844.0, 47.0, false)
        assertEquals(8.5 / 11, pdf.width / pdf.height, 1e-12)
        val thumbnail = ApprovalRect(24.0, 500.0, 36.0, 46.0)
        assertEquals(thumbnail, ApprovalDetailGeometry.picture(thumbnail, wide, 0.0))
        assertEquals(wide, ApprovalDetailGeometry.picture(thumbnail, wide, 1.0))
        assertEquals(0.0, ApprovalDetailGeometry.pictureBlack(1.0, 400.0), 0.0)
        assertEquals(0.0, ApprovalDetailGeometry.pictureHeader(1.0, 5.0), 0.0)
    }
    @Test fun aClosingDetailKeepsItsOriginalTargetAndCanReverseBeforeItIsFreed() {
        val motion = ApprovalDetailPresentation(); val target = target()
        assertTrue(motion.open(target, owner, false))
        repeat(240) { motion.advance(1.0 / 120) }
        assertEquals(1.0, motion.frame.value.progress, 0.0)
        assertTrue(motion.close(owner))
        repeat(8) { motion.advance(1.0 / 120) }
        assertEquals(target, motion.frame.value.target)
        val interrupted = motion.frame.value.progress
        assertTrue(interrupted in 0.0..1.0)
        assertTrue(motion.open(target, owner, false))
        assertEquals(interrupted, motion.frame.value.progress, 0.0)
        repeat(240) { motion.advance(1.0 / 120) }
        assertEquals(1.0, motion.frame.value.progress, 0.0)
    }
    @Test fun changedFactsEpochOrAccountClearPicturesWithoutAnOldOwnerExit() {
        for (next in listOf(owner.copy(facts = "new"), owner.copy(epoch = 2), owner.copy(account = "another"), null)) {
            val motion = ApprovalDetailPresentation()
            motion.open(target(ApprovalDetailKind.PICTURE), owner, false)
            motion.advance(1.0 / 120)
            motion.reconcile(next, false)
            assertNull(motion.frame.value.target); assertFalse(motion.frame.value.running)
            assertFalse(motion.close(owner))
        }
    }
    @Test fun thePictureAndWindowHaveDifferentSourcePullCommitThresholds() {
        val picture = ApprovalDetailPresentation(); picture.open(target(ApprovalDetailKind.PICTURE), owner, false)
        picture.beginDrag(owner); picture.drag(owner, 2.0)
        assertTrue(picture.releaseDrag(owner, 651.0))
        val window = ApprovalDetailPresentation(); window.open(target(), owner, false)
        window.beginDrag(owner); window.drag(owner, 2.0)
        assertFalse(window.releaseDrag(owner, 651.0))
        window.beginDrag(owner); window.drag(owner, 45.0)
        assertTrue(window.releaseDrag(owner, 651.0))
    }
    @Test fun aCancelledOversizedPullAndOldOwnerCallbacksCannotCloseTheCurrentDetail() {
        val motion = ApprovalDetailPresentation(); motion.open(target(ApprovalDetailKind.PICTURE), owner, false)
        motion.beginDrag(owner); motion.drag(owner, 200.0)
        assertFalse(motion.releaseDrag(owner, 800.0, cancelled = true))
        assertTrue(motion.frame.value.opening)
        assertFalse(motion.close(owner.copy(epoch = 2)))
        repeat(180) { motion.advance(1.0 / 120) }
        assertEquals(0.0, motion.frame.value.drag, 0.0)
    }
    @Test fun reducedMotionFadesAtTheDestinationWithoutMovingThroughAnAnchor() {
        val motion = ApprovalDetailPresentation(); motion.open(target(), owner, true)
        assertEquals(1.0, motion.frame.value.progress, 0.0)
        assertEquals(0.0, motion.frame.value.opacity, 0.0)
        motion.advance(.1); assertEquals(.5, motion.frame.value.opacity, 1e-6)
        motion.advance(.1); assertFalse(motion.frame.value.running)
        motion.close(owner); motion.advance(.1)
        assertEquals(1.0, motion.frame.value.progress, 0.0)
        assertEquals(.5, motion.frame.value.opacity, 1e-6)
        motion.advance(.1); assertNull(motion.frame.value.target)
    }
    @Test fun concurrentDetailSpringsAdvanceOnOneElapsedFrameWhenAnotherOneStartsOrFinishes() {
        val window = ApprovalDetailPresentation(); val picture = ApprovalDetailPresentation()
        val baseline = ApprovalDetailPresentation()
        val pages = ApprovalWindowPages(); val clock = ApprovalDetailClock(window, picture, pages)
        window.open(target(), owner, false); baseline.open(target(), owner, false)
        var now = 0L; clock.frame(now)
        fun frame() { now += 8_000_000; clock.frame(now); baseline.advance(.008) }
        repeat(5) { frame() }
        picture.open(target(ApprovalDetailKind.PICTURE), owner, false)
        pages.open(owner, 2, 0); pages.goTo(owner, 1)
        repeat(80) {
            // Calling idle during a true-to-true component transition cannot discard elapsed time.
            clock.idle(); frame()
            assertEquals(baseline.frame.value.progress, window.frame.value.progress, 0.0)
        }
        picture.close(owner)
        repeat(120) {
            frame()
            assertEquals(baseline.frame.value.progress, window.frame.value.progress, 0.0)
        }
    }
    @Test fun aControllerRetiresSensitiveDetailStateWithoutWaitingForAnotherComposition() {
        val port = object : AgentSyncPort {
            override val connection = kotlinx.coroutines.flow.MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet())), epoch = 1))
            override val conversations = kotlinx.coroutines.flow.MutableStateFlow(emptyList<RemoteConversation>())
            override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
            override suspend fun stop(owner: RemoteOwner) {}
            override suspend fun delete(owner: RemoteOwner) {}
            override suspend fun answerApproval(answer: ApprovalAnswer): Unit = error("Read-only fixture must never answer")
        }
        var now = 1000L
        val controller = ApprovalController(port) { now }
        val request = ApprovalRequest("question", "account", "mac", 1, 2000, "Claude", "Synthetic question", "Synthetic facts")
        fun show() {
            controller.replaceValidated(listOf(request))
            val lease = checkNotNull(controller.captureDisplayed(request))
            val key = ApprovalPresentationKey("account", port.connection.value.epoch, "mac", request.id, request.fingerprint(), lease.generation)
            controller.windowPresentation.open(ApprovalDetailTarget(key, ApprovalDetailKind.MAIL, "row", 0), key, false)
            controller.picturePresentation.open(ApprovalDetailTarget(key, ApprovalDetailKind.PICTURE, "thumb", 0), key, false)
            assertNotNull(controller.picturePresentation.frame.value.target)
        }
        show(); controller.replaceValidated(listOf(request.copy(title = "Changed exact facts")))
        assertNull(controller.windowPresentation.frame.value.target); assertNull(controller.picturePresentation.frame.value.target)
        show(); port.connection.value = port.connection.value.copy(epoch = 2); controller.replaceValidated(listOf(request))
        assertNull(controller.windowPresentation.frame.value.target); assertNull(controller.picturePresentation.frame.value.target)
        show(); now = 2000; controller.expire()
        assertNull(controller.windowPresentation.frame.value.target); assertNull(controller.picturePresentation.frame.value.target)
    }
}
