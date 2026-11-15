package dev.yab.agent

import org.junit.Assert.*
import org.junit.Test

class ApprovalMotionTest {
    private fun content(id: String, epoch: Long = 0, receipt: Boolean = false): ApprovalPresented {
        val request = ApprovalRequest(id, "account", "mac", 1, 200_000, "Claude", "Synthetic question", "Synthetic facts")
        return ApprovalPresented(ApprovalPresentationKey(request.account, epoch, request.mac, id, request.fingerprint(), 1), request,
            if (receipt) ApprovalReceipt(request, 1000) else null,
            if (receipt) null else ApprovalDisplayLease(request.account, epoch, id, request.fingerprint(), 1))
    }
    private fun ready(tray: ApprovalTrayPresentation, value: ApprovalPresented, reduced: Boolean = false) {
        tray.offer(value, { true }, reduced); tray.measure(value.key, 300.0)
        repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(ApprovalTravel.READY, tray.frame.value.phase)
    }
    @Test fun currentPhoneGeometryKeepsPointInsetsAndClipsTallBodies() {
        val portrait = ApprovalGeometry(390.0, 844.0, 47.0, 300.0)
        assertEquals(ApprovalRect(8.0, 476.0, 374.0, 360.0), portrait.rect)
        assertEquals(ApprovalRect(132.0, 49.0, 126.0, 37.0), portrait.island)
        assertEquals(.28, portrait.dim, 1e-10)
        val tall = portrait.copy(contentHeight = 1200.0)
        assertEquals(781.0, tall.trayHeight, 1e-10); assertEquals(721.0, tall.bodyCap, 1e-10)
        assertEquals(55.0, tall.rect.y, 1e-10)
        val folded = portrait.copy(fold = 1.0)
        assertEquals(portrait.island, folded.rect); assertEquals(0.0, folded.wordsOpacity, 0.0); assertEquals(0.0, folded.dim, 0.0)
        val wide = ApprovalGeometry(1024.0, 768.0, 24.0, 300.0, lift = 200.0)
        assertEquals(500.0, wide.width, 0.0); assertEquals(262.0, wide.x, 0.0); assertEquals(560.0, wide.bottom, 0.0)
    }
    @Test fun interruptedSourceSpringCarriesVelocityAndCapsLongFrames() {
        val spring = ApprovalSpringValue(500.0)
        spring.animate(0.0, ApprovalTiming.arrive)
        spring.advance(1.0 / 120)
        val position = spring.value; val speed = spring.velocity
        assertTrue(position in 0.0..500.0); assertTrue(speed < 0)
        spring.animate(800.0, ApprovalTiming.back)
        assertEquals(position, spring.value, 0.0); assertEquals(speed, spring.velocity, 0.0)
        val capped = ApprovalSpringValue(500.0); capped.animate(0.0, ApprovalTiming.arrive)
        val stalled = ApprovalSpringValue(500.0); stalled.animate(0.0, ApprovalTiming.arrive)
        capped.advance(.02); stalled.advance(1.0)
        assertEquals(capped.value, stalled.value, 0.0); assertEquals(capped.velocity, stalled.velocity, 0.0)
        val unit = ApprovalSpringValue(0.0, unit = true)
        unit.animate(.0001, ApprovalTiming.fold)
        assertTrue("Normalized springs retain the source's 1000-point threshold", unit.moving)
        unit.set(.5); assertEquals(0.0, unit.velocity, 0.0); assertFalse(unit.moving)
    }
    @Test fun oldFactsStayDrawnDuringExitAndOnlyLatestQueuedQuestionArrives() {
        val tray = ApprovalTrayPresentation(); val first = content("first")
        ready(tray, first)
        tray.offer(content("second"), { true }, false)
        assertEquals(first, tray.frame.value.content); assertFalse(tray.frame.value.interactive)
        tray.advance(1.0 / 120)
        assertTrue(tray.frame.value.rise > 0)
        val latest = content("latest"); tray.offer(latest, { true }, false)
        repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(latest, tray.frame.value.content)
        tray.measure(latest.key, 200.0); repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(ApprovalTravel.READY, tray.frame.value.phase)
        assertTrue(tray.frame.value.interactive)
        tray.offer(null, { false }, false)
        assertNull("Revoked account/epoch/Mac content cannot animate over a new owner", tray.frame.value.content)
        assertFalse(tray.frame.value.running)
    }
    @Test fun receiptFoldAndIslandMustFinishBeforeTheNextQuestionTakesTheSurface() {
        val tray = ApprovalTrayPresentation(); val receipt = content("sent", receipt = true)
        ready(tray, receipt)
        val next = content("next"); tray.offer(next, { true }, false)
        assertEquals(ApprovalTravel.FOLDING, tray.frame.value.phase)
        var foldedTime = 0.0
        repeat(120) { if (tray.frame.value.phase == ApprovalTravel.FOLDING) { tray.advance(1.0 / 120); foldedTime += 1.0 / 120 } }
        assertEquals(ApprovalTravel.ISLAND, tray.frame.value.phase)
        assertEquals(receipt, tray.frame.value.content)
        tray.advance(1.499 - foldedTime)
        assertEquals(ApprovalTravel.ISLAND, tray.frame.value.phase)
        tray.advance(.002)
        assertEquals(ApprovalTravel.ISLAND_LEAVING, tray.frame.value.phase)
        repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(next, tray.frame.value.content)
    }
    @Test fun reducedMotionCrossfadesInPlaceAndStillRetainsOutgoingFacts() {
        val tray = ApprovalTrayPresentation(); val first = content("first")
        tray.offer(first, { true }, true); tray.measure(first.key, 300.0)
        tray.advance(.1)
        assertEquals(.5, tray.frame.value.fade, 1e-6); assertEquals(0.0, tray.frame.value.rise, 0.0)
        tray.advance(.1); assertEquals(ApprovalTravel.READY, tray.frame.value.phase)
        val next = content("next"); tray.offer(next, { true }, true); tray.advance(.1)
        assertEquals(first, tray.frame.value.content); assertEquals(.5, tray.frame.value.fade, 1e-6)
        assertEquals(0.0, tray.frame.value.fold, 0.0); assertEquals(0.0, tray.frame.value.drag, 0.0)
        tray.advance(.1); assertEquals(next, tray.frame.value.content)
        assertEquals(0.0, tray.frame.value.fade, 0.0)
    }
    @Test fun regrabbingTheReturningTrayStartsAtItsLiveOffsetAndKeepsFlickDirection() {
        val tray = ApprovalTrayPresentation(); val value = content("question")
        ready(tray, value)
        tray.beginDrag(value.key); tray.drag(value.key, 90.0)
        assertFalse(tray.releaseDrag(value.key, 0.0))
        tray.advance(1.0 / 120)
        val returning = tray.frame.value.drag
        assertTrue(returning > 0 && returning < 90)
        tray.beginDrag(value.key); tray.drag(value.key, 1.0)
        assertEquals(returning + 1, tray.frame.value.drag, 1e-9)
        assertTrue("A short fast screen-space flick commits without a long pull", tray.releaseDrag(value.key, 651.0))
        val held = tray.frame.value.drag
        repeat(15) { tray.advance(1.0 / 120) }
        assertEquals("Waiting for actual transport cannot spring back first", held, tray.frame.value.drag, 0.0)
        tray.offer(null, { true }, false)
        assertEquals(held, tray.frame.value.rise, 0.0)
        assertEquals(651.0, tray.frame.value.riseVelocity, 0.0)
        tray.advance(1.0 / 120)
        assertTrue(tray.frame.value.rise > held)
    }
    @Test fun refusedOrCancelledDeclineReleasesItsHeldPullWithoutDismissingTheQuestion() {
        val tray = ApprovalTrayPresentation(); val value = content("question")
        ready(tray, value)
        tray.beginDrag(value.key); tray.drag(value.key, 30.0)
        assertTrue(tray.releaseDrag(value.key, 900.0))
        tray.submissionRetainedQuestion(value.key.copy(epoch = 2))
        tray.advance(1.0 / 120)
        assertEquals(30.0, tray.frame.value.drag, 0.0)
        tray.submissionRetainedQuestion(value.key)
        repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(0.0, tray.frame.value.drag, 0.0)
        assertEquals(value, tray.frame.value.content)
        assertEquals(ApprovalTravel.READY, tray.frame.value.phase)
        tray.beginDrag(value.key); tray.drag(value.key, 400.0)
        tray.cancelDrag(value.key)
        assertFalse("A cancelled long gesture must not become a decline", tray.frame.value.awaitingDecline)
        repeat(180) { tray.advance(1.0 / 120) }
        assertEquals(0.0, tray.frame.value.drag, 0.0)
        assertEquals(value, tray.frame.value.content)
    }
}
