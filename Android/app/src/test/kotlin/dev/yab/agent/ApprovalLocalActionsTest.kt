package dev.yab.agent

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** Exercises the actual local detail actions, rather than a second copy of their gate. */
class ApprovalLocalActionsTest {
    private class Port : AgentSyncPort {
        override val connection = MutableStateFlow(RemoteConnection("account", listOf(RemoteMac("mac", "Mac", true, emptySet()))))
        override val conversations = MutableStateFlow(emptyList<RemoteConversation>())
        var answers = 0
        override suspend fun send(command: AgentSendCommand) = AgentSendReceipt()
        override suspend fun stop(owner: RemoteOwner) {}
        override suspend fun delete(owner: RemoteOwner) {}
        override suspend fun answerApproval(answer: ApprovalAnswer) { answers++ }
    }
    private class Fixture(private val scope: CoroutineScope) {
        val file = ApprovalFile("picture", "Synthetic.jpg", "image/jpeg", 64)
        val preview = ApprovalPreview(file.id, 0, "synthetic-not-decoded")
        val request = ApprovalRequest("question", "account", "mac", 1, 90_000, "Claude", "Read?", "Exact original facts",
            kind = ApprovalKind.MAIL_BATCH, sourceEpoch = 0,
            mails = listOf(ApprovalMail("First", listOf("Recipient"), "One", "Synthetic first body", files = listOf(file)),
                ApprovalMail("Second", listOf("Recipient"), "Two", "Synthetic second body")), previews = listOf(preview))
        val port = Port()
        val controller = ApprovalController(port) { 1000 }
        val lifetime = ApprovalInteractionLifetime().apply { resume() }
        init { controller.replaceValidated(listOf(request)) }
        fun presented(): ApprovalPresented {
            val current = controller.state.value; val request = current.requests.single()
            return ApprovalPresented(ApprovalPresentationKey(request.account, current.ownerEpoch, request.mac, request.id,
                request.fingerprint(), current.presentationGeneration), request, action = checkNotNull(controller.captureDisplayed(request)))
        }
        fun interaction() = ApprovalInteraction(scope, checkNotNull(lifetime.capture(lifetime.state.value)))
        fun actions(shown: ApprovalPresented, interaction: ApprovalInteraction = interaction()) =
            ApprovalDetailActions(controller, shown, false, interaction)
        fun anchors(shown: ApprovalPresented) {
            controller.detailAnchors.reconcile(shown.key)
            listOf("tray:mail.0", "tray:mail.1", "win:mail.0.picture").forEach {
                controller.detailAnchors.put(shown.key, it, ApprovalRect(16.0, 400.0, 300.0, 64.0))
            }
        }
    }

    @Test fun oldStopReturnRowsCannotOpenPageOrFoldTheSameStillCurrentRequest() = runTest {
        val fixture = Fixture(this); val shown = fixture.presented(); fixture.anchors(shown)
        val old = fixture.actions(shown)
        fixture.lifetime.stop(); fixture.lifetime.resume()
        // The source facts are unchanged: the lifecycle check must be the refusing authority.
        assertTrue(fixture.controller.isDisplayedCurrent(checkNotNull(shown.action)))
        old.openMail(0, "tray:mail.0"); assertNull(fixture.controller.windowPresentation.frame.value.target)
        val fresh = fixture.actions(shown); fresh.openMail(0, "tray:mail.0")
        assertNotNull(fixture.controller.windowPresentation.frame.value.target)
        assertFalse(old.page(1)); assertEquals(0, fixture.controller.windowPages.frame.value.selected)
        assertTrue(fresh.page(1)); assertEquals(1, fixture.controller.windowPages.frame.value.selected)
        old.foldWindow(); assertTrue(fixture.controller.windowPresentation.frame.value.opening)
        fresh.foldWindow(); assertFalse(fixture.controller.windowPresentation.frame.value.opening)
        assertEquals(1, fixture.controller.windowPresentation.frame.value.target?.index)
        assertEquals(0, fixture.port.answers)
    }

    @Test fun pausedAndRetiredPictureCallbacksCannotCloseOrReopenAFreshDetail() = runTest {
        val fixture = Fixture(this); val shown = fixture.presented(); fixture.anchors(shown)
        val old = fixture.actions(shown)
        fixture.lifetime.pause(); old.openPicture(fixture.file, fixture.preview, "win:mail.0.picture")
        assertNull(fixture.controller.picturePresentation.frame.value.target)
        fixture.lifetime.resume(); old.openPicture(fixture.file, fixture.preview, "win:mail.0.picture")
        assertTrue(fixture.controller.picturePresentation.frame.value.opening)
        fixture.lifetime.stop(); fixture.lifetime.resume()
        old.closePicture(); assertTrue(fixture.controller.picturePresentation.frame.value.opening)
        val fresh = fixture.actions(shown); fresh.closePicture()
        assertFalse(fixture.controller.picturePresentation.frame.value.opening)
        old.openPicture(fixture.file, fixture.preview, "win:mail.0.picture")
        assertFalse(fixture.controller.picturePresentation.frame.value.opening)
        fresh.openPicture(fixture.file, fixture.preview, "win:mail.0.picture")
        assertTrue(fixture.controller.picturePresentation.frame.value.opening)
        assertEquals(0, fixture.port.answers)
    }

    @Test fun freshLifecycleCannotAuthorizeRetiredFactsEpochOrDisposedComposition() = runTest {
        val fixture = Fixture(this); val shown = fixture.presented(); fixture.anchors(shown)
        val old = fixture.actions(shown)
        fixture.lifetime.dispose()
        val replacement = ApprovalInteractionLifetime().apply { resume() }
        val currentInteraction = ApprovalInteraction(this, checkNotNull(replacement.capture(replacement.state.value)))
        val fresh = fixture.actions(shown, currentInteraction)
        old.openMail(0, "tray:mail.0"); assertNull(fixture.controller.windowPresentation.frame.value.target)
        fixture.controller.replaceValidated(listOf(fixture.request.copy(summary = "Changed detail facts")))
        fresh.openMail(0, "tray:mail.0"); assertNull(fixture.controller.windowPresentation.frame.value.target)
        val changed = fixture.presented(); fixture.anchors(changed)
        fixture.actions(changed, currentInteraction).openMail(0, "tray:mail.0")
        assertNotNull(fixture.controller.windowPresentation.frame.value.target)
        fixture.port.connection.value = fixture.port.connection.value.copy(epoch = 1)
        // Even before the next reconciliation, fresh lifecycle cannot borrow another Sync owner.
        assertFalse(fresh.page(1)); assertFalse(fixture.actions(changed, currentInteraction).current())
        assertEquals(0, fixture.port.answers)
    }
}
