package dev.yab.agent

import dev.yab.core.sync.Record
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable data class ChatStep(val id: String, val kind: String, val name: String, val detail: String, val text: String,
                                 val state: String, val began: Long? = null, val ended: Long? = null)
@Serializable data class ChatWork(val kind: String, val id: String, val words: String = "", val text: String = "",
                                 val steps: List<ChatStep> = emptyList(), val question: String? = null,
                                 val title: String = "", val detail: String = "", val at: Long? = null,
                                 val subagents: List<ChatLiveAgent> = emptyList())
@Serializable data class ChatLiveAgent(val id: String, val name: String, val since: Long? = null)
@Serializable data class ChatHanded(val host: String, val title: String, val detail: String, val from: String)
@Serializable data class ChatResultRow(val title: String, val url: String? = null, val site: String? = null,
    val minutes: Int? = null, val cells: List<String>? = null, val tab: String? = null)
@Serializable data class ChatResultCard(val kind: String, val title: String = "", val detail: String? = null,
    val at: Double? = null, val end: Double? = null, val value: String? = null, val site: String? = null,
    val rows: List<ChatResultRow>? = null, val lit: Int? = null, val ref: String? = null, val url: String? = null) {
    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        fun parse(text: String): ChatResultCard? = runCatching {
            val raw = json.decodeFromString<ChatResultCard>(text)
            require(raw.kind in setOf("links", "table", "event", "promise", "watch", "routine", "folder"))
            val rows = raw.rows?.filter { it.title.isNotEmpty() }?.take(8)
            require(if (raw.kind in setOf("links", "table", "folder")) !rows.isNullOrEmpty() else raw.kind == "promise" || raw.title.isNotEmpty())
            raw.copy(rows = rows, lit = raw.lit?.takeIf { it in rows.orEmpty().indices })
        }.getOrNull()
    }
}

/** Projection of actual SyncChatItems. Bookkeeping is never presented as an assistant answer. */
object ChatTranscript {
    private fun Record.facts() = if (alive()) visible else JsonObject(fields.filterValues { it != JsonNull })
    private fun JsonObject.text(name: String) = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
    private fun JsonObject.number(name: String) = (get(name) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
    private fun files(send: Record?): List<ChatFile> = (send?.get("files") as? JsonArray).orEmpty().mapNotNull { value -> runCatching {
        val f = value.jsonObject; val size = f.number("size") ?: return@runCatching null
        require(size.isFinite() && size in 0.0..Int.MAX_VALUE.toDouble())
        ChatFile(f.text("name"), f.text("type"), size.toInt(), f.text("digest"))
    }.getOrNull() }
    fun messages(head: Record, items: List<Record>, sends: List<Record>, now: Long = System.currentTimeMillis()): List<AgentMessage> {
        val h = head.facts(); val remoteState = h.text("state")
        val agent = AgentProvider.fromWire(h.text("cli"))?.displayName ?: "Claude"
        val headRunning = remoteState == "running"
        val headUpdated = ChatTurnSemantics.millis(ChatTurnSemantics.updatedSeconds(head)) ?: 0
        val remaining = sends.filter { it["chat"]?.jsonPrimitive?.content == head.id }.sortedBy { (it["at"] as? JsonPrimitive)?.doubleOrNull ?: 0.0 }.toMutableList()
        val turns = ChatTurnSemantics.turns(items)
        val out = mutableListOf<AgentMessage>()
        var live = emptyList<ChatLiveAgent>()
        var hasFailure = false
        for ((index, turn) in turns.withIndex()) {
            val last = index == turns.lastIndex
            val asked = turn.firstOrNull { it.kind == "asked" && it.name != "steer" } ?: turn.firstOrNull { it.kind == "asked" }
            val report = asked?.let { ChatTurnSemantics.report(it.text) }
            val ending = ChatTurnSemantics.ending(turn, last, remoteState)
            val answered = mutableListOf<Int>(); val cards = mutableListOf<ChatResultCard>(); val thoughts = mutableListOf<ChatTurnItem>()
            fun fold() {
                if (thoughts.isEmpty()) return
                val text = thoughts.map { it.text }.filter(String::isNotEmpty).joinToString("\n\n")
                out += AgentMessage(thoughts.first().id, MessageRole.WORK, "", 0, AnswerOrigin.MAC,
                    work = ChatWork("thought", thoughts.first().id, ChatTurnSemantics.thoughtWords(thoughts), text))
                thoughts.clear()
            }
            for (item in turn) {
                if (ChatTurnSemantics.thought(item)) { thoughts += item; continue }; fold()
                val text = item.text
                val at = ChatTurnSemantics.millis(item.began) ?: headUpdated
                when (item.kind) {
                    "asked" -> if (text.isNotEmpty()) {
                        if (item.id == asked?.id && report != null) {
                            out += AgentMessage(item.id, MessageRole.WORK, "", at, AnswerOrigin.MAC,
                                work = ChatWork("report", item.id, text = report.body, title = report.name, detail = report.gist))
                            continue
                        }
                        val match = remaining.indexOfFirst { send ->
                            val f = send.facts()
                            f.text("state") == "taken" && f.text("text").ifEmpty { f.text("agentText") }.let { it == text || it.take(8000) == text } &&
                                (item.began == null || item.began >= (f.number("at") ?: 0.0) - 1)
                        }
                        val send = if (match >= 0) remaining.removeAt(match) else null
                        val handed = item.detail.lineSequence().firstOrNull { it.startsWith("w:") }?.removePrefix("w:")?.split('\t')?.takeIf { it.size == 4 && it[1].isNotBlank() }?.let { ChatHanded(it[0], it[1], it[2], it[3]) }
                        out += AgentMessage(item.id, MessageRole.USER, send?.get("question")?.jsonPrimitive?.content ?: text, at, AnswerOrigin.MAC, files(send), handed = handed)
                    }
                    "chose" -> if (text.isNotEmpty()) {
                        val match = remaining.indexOfFirst { it.facts().let { f -> f.text("state") == "taken" && f.text("text").ifEmpty { f.text("agentText") } == text } }
                        if (match >= 0) remaining.removeAt(match)
                        out += AgentMessage(item.id, MessageRole.USER, text, at, AnswerOrigin.MAC)
                    }
                    "message" -> when {
                        ChatTurnSemantics.said(item) && item.name == "question" -> out += AgentMessage(item.id, MessageRole.ASSISTANT, text, at, AnswerOrigin.MAC)
                        ChatTurnSemantics.said(item) -> {
                            if (last && remoteState == "failed" && ChatTurnSemantics.repeats(item, h.text("answer"))) continue
                            answered += out.size
                            out += AgentMessage(item.id, MessageRole.ASSISTANT, text, at, AnswerOrigin.MAC)
                        }
                        !(last && remoteState == "failed" && item.name == "error") -> {
                            ChatTurnSemantics.note(item, agent)?.let { note -> out += AgentMessage(item.id, MessageRole.NOTE, note, at, AnswerOrigin.MAC) }
                        }
                    }
                    "card" -> ChatResultCard.parse(text)?.let(cards::add)
                }
            }
            fold()
            if (cards.isNotEmpty()) {
                val answer = answered.lastOrNull()
                if (answer == null) out += AgentMessage(turn.first().id + "/cards", MessageRole.ASSISTANT, "", 0, AnswerOrigin.MAC, cards = cards)
                else out[answer] = out[answer].copy(cards = cards)
            }
            if (last && headRunning) { live = ChatTurnSemantics.live(turn); continue }
            val steps = ChatTurnSemantics.steps(turn, ending)
            val words = ChatTurnSemantics.doneWords(ending, ChatTurnSemantics.worked(turn))
            val question = asked?.text?.takeUnless { headRunning || report != null }
            when {
                ending == "failed" -> {
                    val raw = h.text("answer").ifEmpty { turn.lastOrNull { it.kind == "message" && it.name == "error" }?.text.orEmpty() }
                    val problem = ChatTurnSemantics.problem(raw, agent)
                    out += AgentMessage(turn.first().id + "/failed", MessageRole.WORK, "", 0, AnswerOrigin.MAC,
                        work = ChatWork("failure", turn.first().id, words, steps = steps, question = question, title = problem.title, detail = problem.detail))
                    hasFailure = true
                }
                ending == "stopped" -> out += AgentMessage(turn.first().id + "/stopped", MessageRole.NOTE, words, 0, AnswerOrigin.MAC)
                answered.isNotEmpty() -> {
                    val at = answered.last()
                    val final = turn.lastOrNull { ChatTurnSemantics.said(it) && it.name != "question" }
                    out[at] = out[at].copy(work = ChatWork("actions", turn.first().id, words, answered.joinToString("\n\n") { out[it].text }, steps, question,
                        at = ChatTurnSemantics.millis(final?.ended ?: final?.began)))
                }
            }
        }
        if (out.isEmpty() && h.text("answer").isNotEmpty() && remoteState != "failed") out += AgentMessage(head.id + "/answer", MessageRole.ASSISTANT, h.text("answer"), headUpdated, AnswerOrigin.MAC)
        if (remoteState == "failed" && !hasFailure) {
            val problem = ChatTurnSemantics.problem(h.text("answer"), agent)
            out += AgentMessage(head.id + "/failed", MessageRole.WORK, "", headUpdated, AnswerOrigin.MAC,
                work = ChatWork("failure", head.id, question = out.lastOrNull { it.role == MessageRole.USER }?.text, title = problem.title, detail = problem.detail))
        }
        for (send in remaining.filter { it.alive() && it["state"]?.jsonPrimitive?.content != "taken" && it["action"] == null }) {
            val f = send.facts(); val text = f.text("question").ifBlank { f.text("text").ifBlank { f.text("agentText") } }
            if (text.isNotBlank() || files(send).isNotEmpty()) out += AgentMessage(send.id, MessageRole.USER, text, ((f.number("at") ?: 0.0) * 1000).toLong(), files = files(send))
        }
        if (ChatTurnSemantics.isLive(head, now) && live.isNotEmpty()) out += AgentMessage(head.id + "/live", MessageRole.WORK, "", headUpdated, AnswerOrigin.MAC,
            work = ChatWork("subagents", head.id + "/live", subagents = live))
        return out
    }
}
