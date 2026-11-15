package dev.yab.agent

import androidx.compose.ui.graphics.Color
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

enum class FieldChatAction { COPY_ANSWER, PIN, UNPIN, MARK_READ, MARK_UNREAD, RENAME, ARCHIVE, UNARCHIVE, ARCHIVE_OLDER, STOP, DELETE }

/** UI-only captured intent. The caller checks this source and every original chat again. */
data class FieldChatCommand(val sourceKey: Any, val chat: AgentChat, val action: FieldChatAction,
    val title: String? = null, val older: List<AgentChat> = emptyList())
data class FieldChatDeleteQuestion(val title: String, val detail: String? = null)

object FieldChatsPageModel {
    fun working(chat: AgentChat): Boolean = chat.delivery == DeliveryState.ANSWERING

    /** Phone ChatFlow.archivableBelow uses displayed order, including the adjacent grid card. */
    fun older(chat: AgentChat, group: List<AgentChat>): List<AgentChat> {
        val index = group.indexOfFirst { sameOwner(it, chat) }
        if (index < 0) return emptyList()
        return group.drop(index + 1).filter { !it.pinned && !it.archived && !working(it) }
    }

    fun sameOwner(live: AgentChat, captured: AgentChat): Boolean = live.id == captured.id && live.owner == captured.owner &&
        live.privateOrigin == captured.privateOrigin && pendingOwner(live.pendingSend) == pendingOwner(captured.pendingSend)
    private fun pendingOwner(send: RemoteSend?): List<Any>? = send?.let { listOf(it.account, it.epoch, it.id, it.mac, it.provider, it.fingerprint) }

    fun answer(chat: AgentChat): AgentMessage? = chat.messages.lastOrNull { it.role == MessageRole.ASSISTANT }
    fun preview(chat: AgentChat): String {
        val message = answer(chat) ?: return "New chat"
        val source = message.text.ifBlank { message.cards.firstOrNull()?.let { it.detail ?: it.title }.orEmpty() }
        return AgentMarkdown.blocks(source).joinToString(" ") { AgentMarkdown.inline(it.text, Color.Unspecified).text }
            .lineSequence().map(String::trim).filter(String::isNotEmpty).joinToString(" ").ifBlank { "New chat" }
    }

    fun status(chat: AgentChat, macNames: Map<String, String>, now: Long, zone: ZoneId = ZoneId.systemDefault(),
        locale: Locale = Locale.getDefault()): String {
        if (working(chat)) return "working"
        chat.pendingSend?.takeIf { it.state in setOf(MacSendState.WAITING, MacSendState.PROCESSING) }?.let {
            return "Waiting for ${macNames[it.mac] ?: "your Mac"}"
        }
        if (chat.updatedAt <= 0) return ""
        val at = Instant.ofEpochMilli(chat.updatedAt).atZone(zone)
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val pattern = when {
            at.toLocalDate() == today -> "HH:mm"
            at.toLocalDate().isAfter(today.minusDays(7)) -> "EEE"
            else -> "MMM d"
        }
        return at.format(DateTimeFormatter.ofPattern(pattern, locale))
    }
}
