package dev.yab.agent

import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test

class FieldChatsPageModelTest {
    private val owner = RemoteOwner("account", "mac", "a:chat", AgentProvider.CLAUDE)

    @Test fun archiveOlderIncludesAdjacentGridCardButProtectsPinnedArchivedAndWorkingRows() {
        val first = AgentChat("first", owner = owner)
        val adjacent = AgentChat("adjacent")
        val list = listOf(first, adjacent, AgentChat("pinned", pinned = true), AgentChat("archived", archived = true),
            AgentChat("working", delivery = DeliveryState.ANSWERING), AgentChat("waiting", delivery = DeliveryState.QUEUED))
        assertEquals(listOf("adjacent", "waiting"), FieldChatsPageModel.older(first, list).map { it.id })
        assertTrue(FieldChatsPageModel.older(AgentChat("missing"), list).isEmpty())
    }

    @Test fun capturedTargetCannotBorrowReusedChatIdFromAnotherMacPrivateScopeOrSyncEpoch() {
        val chat = AgentChat("first", owner = owner)
        val last = AgentChat("last")
        assertTrue(FieldChatsPageModel.older(chat, listOf(chat.copy(owner = owner.copy(mac = "new-mac")), last)).isEmpty())
        assertFalse(FieldChatsPageModel.sameOwner(chat.copy(privateOrigin = true), chat))
        val send = RemoteSend("account", 1, "send", chat.id, "mac", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "question", fingerprint = "captured")
        val pending = chat.copy(owner = null, pendingSend = send)
        assertFalse(FieldChatsPageModel.sameOwner(pending.copy(pendingSend = send.copy(epoch = 2)), pending))
        assertFalse(FieldChatsPageModel.sameOwner(pending.copy(pendingSend = send.copy(mac = "new-mac", fingerprint = "replacement")), pending))
        assertFalse(FieldChatsPageModel.sameOwner(pending.copy(owner = owner), pending))
    }

    @Test fun previewUsesLastActualAnswerAndExistingMarkdownRatherThanLaterFailureWorkOrDraft() {
        val answer = AgentMessage("answer", MessageRole.ASSISTANT, "# Result\n\n**Ready** [here](https://example.com).", 1)
        val chat = AgentChat("chat", draft = "unsent", messages = listOf(answer,
            AgentMessage("work", MessageRole.WORK, "in progress", 2), AgentMessage("failure", MessageRole.FAILURE, "not sent", 3)))
        assertEquals("Result Ready here.", FieldChatsPageModel.preview(chat))
        assertEquals(answer, FieldChatsPageModel.answer(chat))
        assertEquals("New chat", FieldChatsPageModel.preview(chat.copy(messages = listOf(chat.messages.last()))))
    }

    @Test fun pendingStatusNamesOriginalMacAndNeverBorrowsAnotherCurrentRoute() {
        val send = RemoteSend("account", 1, "send", "chat", "original", AgentProvider.CLAUDE, 1,
            MacSendState.WAITING, "question", fingerprint = "captured")
        val chat = AgentChat("chat", pendingSend = send, delivery = DeliveryState.QUEUED)
        assertEquals("Waiting for Original Mac", FieldChatsPageModel.status(chat, mapOf("original" to "Original Mac", "new" to "New Mac"), 0))
        assertEquals("Waiting for your Mac", FieldChatsPageModel.status(chat, mapOf("new" to "New Mac"), 0))
        assertEquals("working", FieldChatsPageModel.status(chat.copy(delivery = DeliveryState.ANSWERING), emptyMap(), 0))
        val zone = ZoneId.of("UTC")
        assertEquals("12:00", FieldChatsPageModel.status(AgentChat("done", updatedAt = 43_200_000), emptyMap(), 50_000_000, zone, Locale.US))
    }
}
