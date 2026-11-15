package dev.yab.agent

import java.net.URI
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

data class ChatSection(val title: String, val chats: List<AgentChat>)
object ChatCollections {
    fun sections(chats: List<AgentChat>, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): List<ChatSection> {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return chats.groupBy { chat -> if (chat.pinned) "Pinned" else when (Instant.ofEpochMilli(chat.updatedAt).atZone(zone).toLocalDate()) {
            today -> "Today"; today.minusDays(1) -> "Yesterday"; else -> "Earlier"
        } }.let { groups -> listOf("Pinned", "Today", "Yesterday", "Earlier").mapNotNull { title -> groups[title]?.let { ChatSection(title, it) } } }
    }
}
data class ChatLink(val url: String, val title: String)
data class ChatSite(val host: String, val url: String, val visits: Int)
data class ChatInfoContents(val sites: List<ChatSite>, val links: List<ChatLink>, val media: List<ChatFile>, val files: List<ChatFile>, val steps: Int)
object ChatContents {
    fun read(chat: AgentChat, sitesInEncounterOrder: Boolean = false): ChatInfoContents {
        val links = linkedMapOf<String, ChatLink>(); val sites = linkedMapOf<String, ChatSite>(); val files = linkedMapOf<String, ChatFile>()
        val markdown = Regex("\\[([^]\\n]{1,300})]\\((https?://[^\\s)]+)\\)")
        val bare = Regex("https?://[^\\s<>()\\[\\]\"']+")
        var steps = 0
        for (message in chat.messages) {
            fun add(url: String, title: String?) {
                val value = url.trimEnd('.', ',', ';', ':', '!', '?')
                if (AgentMarkdown.safeUrl(value)) { links.remove(value); links[value] = ChatLink(value, title ?: value.substringAfter("://")) }
            }
            if (message.role in setOf(MessageRole.USER, MessageRole.ASSISTANT)) {
                markdown.findAll(message.text).forEach { add(it.groupValues[2], it.groupValues[1]) }
                bare.findAll(message.text).forEach { if (it.value !in links) add(it.value, null) }
            }
            message.cards.forEach { card -> card.url?.let { add(it, card.title) }; card.rows.orEmpty().forEach { it.url?.let { url -> add(url, it.title) } } }
            message.work?.steps.orEmpty().forEach { step ->
                steps++
                if (step.kind in setOf("tool", "subagent")) for (match in bare.findAll(step.detail)) if (AgentMarkdown.safeUrl(match.value)) {
                    val host = URI(match.value).host.removePrefix("www."); val previous = if (sitesInEncounterOrder) sites[host] else sites.remove(host)
                    sites[host] = ChatSite(host, match.value, (previous?.visits ?: 0) + 1)
                }
            }
            message.files.forEach { file -> files.putIfAbsent(file.digest + "/" + file.name, file) }
        }
        val all = files.values.toList().asReversed()
        return ChatInfoContents(sites.values.toList().let { if (sitesInEncounterOrder) it else it.asReversed() }, links.values.toList().asReversed(), all.filter { it.mime.startsWith("image/") }, all.filterNot { it.mime.startsWith("image/") }, steps)
    }
}
