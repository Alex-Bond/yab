package dev.yab.agent

import dev.yab.core.sync.Record
import java.util.Locale
import java.util.regex.Pattern
import kotlin.math.floor
import kotlinx.serialization.json.*

/** Only fields actually kept by SyncChatItem. Wire dates are seconds, not guessed UI dates. */
data class ChatTurnItem(val id: String, val order: Double, val kind: String, val name: String, val detail: String,
    val text: String, val state: String, val began: Double?, val ended: Double?)

data class ChatSubagentReport(val name: String, val id: String, val state: String, val body: String, val gist: String)
data class ChatFailure(val kind: String, val title: String, val detail: String)

/** Phone TurnWork/StepWords semantics. This helper never sends a command or infers a task tree. */
object ChatTurnSemantics {
    private val grapheme = Pattern.compile("\\X")
    private val asides = setOf("compacted", "note", "status", "error", "notice", "sent", "review")
    private val controls = setOf("toParent", "wait", "sendInput", "sendMessage", "followupTask", "closeAgent", "interruptAgent")
    private val asking = setOf("ask", "AskUserQuestion", "handoff", "computer_access", "folder_access")
    private val quietTools = setOf("wait", "boosts", "boost_read", "mail_list", "task_status", "memory_search", "memory_read", "remember",
        "history", "devices", "calendar", "calendar_free", "skill", "skills", "Skill", "name", "profile", "form_answers", "keep_address",
        "know_report", "suggest", "spaces", "tabs", "web_other", "ToolSearch", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskStop",
        "TaskOutput", "ListAgents", "ReadNotifications", "list_agents", "SubagentHandback", "clock", "sleep", "curr_time", "untrusted_input",
        "visualize/read_me", "retry", "compact", "hook", "update_goal", "create_goal", "get_goal")
    private const val INTERNAL = "Mac access was allowed for this task. Continue the original request: "
    private const val REPORT_FOOTER = "\n---\nIf this report changes nothing in what you have told the user, answer with exactly (quiet) and nothing else. Otherwise tell the user plainly what it changes and what that means for them, in a sentence or two."

    internal fun facts(record: Record): JsonObject = if (record.alive()) record.visible else JsonObject(record.fields.filterValues { it != JsonNull })
    internal fun text(facts: JsonObject, key: String): String = (facts[key] as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
    internal fun number(facts: JsonObject, key: String): Double? = (facts[key] as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull?.takeIf(Double::isFinite)
    internal fun millis(seconds: Double?): Long? = seconds?.times(1000)?.takeIf { it.isFinite() && it >= Long.MIN_VALUE.toDouble() && it < Long.MAX_VALUE.toDouble() }?.toLong()
    fun updatedSeconds(head: Record): Double = facts(head).let { number(it, "updated") ?: number(it, "started") ?: 0.0 }
    fun isLive(head: Record, now: Long = System.currentTimeMillis()): Boolean =
        text(facts(head), "state") == "running" && now / 1000.0 - updatedSeconds(head) < 21_600
    fun choices(head: Record): List<String> {
        val f = facts(head)
        if (text(f, "state") !in setOf("starting", "running", "waiting", "signing-in")) return emptyList()
        return (f["choices"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content }
    }

    fun read(record: Record): ChatTurnItem = facts(record).let { f -> ChatTurnItem(record.id, number(f, "n") ?: 0.0,
        text(f, "kind").ifEmpty { "message" }, text(f, "name"), text(f, "detail"), text(f, "text"), text(f, "state").ifEmpty { "done" }, number(f, "began"), number(f, "ended")) }
    fun turns(records: List<Record>): List<List<ChatTurnItem>> {
        val result = mutableListOf<MutableList<ChatTurnItem>>()
        for (item in records.map(::read).sortedWith(compareBy<ChatTurnItem> { it.order }.thenBy { it.id })) {
            if (item.kind == "asked" && item.text.startsWith(INTERNAL)) continue
            if (result.isEmpty() || item.kind == "asked" && item.name != "steer") result.add(mutableListOf())
            result.last() += item
        }
        return result
    }
    fun quiet(item: ChatTurnItem): Boolean = when (item.kind) {
        "command", "edit", "chose" -> false
        "subagent" -> item.name == "toParent"
        "tool" -> item.name in quietTools || item.name == "mail_accounts" && item.detail.substringBefore(':') != "add"
        else -> true
    }
    fun said(item: ChatTurnItem): Boolean = item.kind == "message" && item.name !in asides && item.name !in setOf("handover", "stopped") &&
        item.text.trim() != "(quiet)" && item.text.isNotEmpty()
    fun note(item: ChatTurnItem, agent: String): String? {
        if (item.kind != "message") return null
        if (item.name == "compacted") return "Context compacted"
        if (item.name !in asides && item.name != "handover" || item.text.isEmpty()) return null
        return if (item.name == "error") problem(item.text, agent).title else item.text
    }
    fun thought(item: ChatTurnItem): Boolean = item.kind == "thinking" && item.name == "thought"
    fun thoughtWords(items: List<ChatTurnItem>): String {
        val duration = items.sumOf { item -> if (item.began != null && item.ended != null && item.ended > item.began) item.ended - item.began else 0.0 }
        return if (duration >= 1) "Thought for ${span(duration)}" else "Thought"
    }
    fun ending(turn: List<ChatTurnItem>, last: Boolean, state: String): String = when {
        turn.any { it.kind == "message" && it.name == "stopped" } -> "stopped"
        last && state == "failed" -> "failed"
        else -> "done"
    }
    fun steps(turn: List<ChatTurnItem>, ending: String, working: Boolean = false): List<ChatStep> = turn.filter {
        it.kind in setOf("tool", "command", "edit", "subagent") && !quiet(it)
    }.map { item -> ChatStep(item.id, item.kind, item.name, item.detail, item.text,
        if (item.state == "running" && !working) ending else item.state, millis(item.began), millis(item.ended)) }
    fun worked(turn: List<ChatTurnItem>): Double? {
        val first = turn.mapNotNull { it.began }.minOrNull() ?: return null
        val last = turn.mapNotNull { it.ended ?: it.began }.maxOrNull() ?: return null
        if (last <= first) return null
        val waited = turn.filter { it.kind == "tool" && it.name in asking }.sumOf {
            if (it.began == null) 0.0 else ((it.ended ?: last) - it.began).coerceAtLeast(0.0)
        }
        return (last - first - waited).coerceAtLeast(1.0)
    }
    fun span(seconds: Double): String {
        val whole = floor(seconds.coerceAtLeast(0.0) + 0.5).toLong().coerceAtLeast(1)
        return when {
            whole < 60 -> "${whole}s"
            whole < 3600 -> "${whole / 60}m" + if (whole % 60 == 0L) "" else " ${whole % 60}s"
            else -> "${whole / 3600}h ${whole % 3600 / 60}m"
        }
    }
    fun doneWords(ending: String, seconds: Double?): String = when (ending) {
        "stopped" -> seconds?.let { "You stopped after ${span(it)}" } ?: "You stopped it"
        "failed" -> seconds?.let { "Couldn’t finish after ${span(it)}" } ?: "Couldn’t finish"
        else -> seconds?.let { "Worked for ${span(it)}" } ?: "Done"
    }
    fun live(turn: List<ChatTurnItem>): List<ChatLiveAgent> = turn.filter {
        it.state == "running" && (it.kind == "subagent" && it.name !in controls || it.kind == "tool" && it.name == "subagent")
    }.map { item ->
        val name = item.detail.trim()
        val matcher = grapheme.matcher(name)
        var end = 0
        var count = 0
        while (count < 80 && matcher.find()) {
            end = matcher.end()
            count++
        }
        ChatLiveAgent(item.id, name.substring(0, end).ifEmpty { "Subagent" }, millis(item.began))
    }

    fun report(raw: String): ChatSubagentReport? {
        if (!raw.startsWith("Subagent ")) return null
        val text = raw.substringBefore(REPORT_FOOTER)
        val end = text.indexOf(") is done (").takeIf { it >= 0 } ?: return null
        val named = text.substring("Subagent ".length, end)
        val open = named.lastIndexOf(" (").takeIf { it >= 0 } ?: return null
        val name = named.substring(0, open); val id = named.substring(open + 2)
        if (name.isEmpty() || id.isEmpty()) return null
        val rest = text.substring(end + ") is done (".length)
        val state = rest.takeWhile { it != ',' && it != ')' }
        val body = rest.substringAfter("\n\n", "").trim()
        val gist = if (body.isEmpty() || body.startsWith("Stopped at the ") && body.endsWith("without a report.")) {
            if (state == "done") "No report" else "Stopped without a report"
        } else body.lineSequence().map { line ->
            line.replace(Regex("\\[([^]]*)]\\([^)]*\\)"), "$1").replace(Regex("[*_`#]+"), "").trim()
        }.firstOrNull { it.isNotEmpty() && !it.startsWith("```") && it != "---" }.orEmpty().trim('-', '*', '•', ' ')
        return ChatSubagentReport(name, id, state, body, gist)
    }
    fun repeats(item: ChatTurnItem, failure: String): Boolean = item.text == failure &&
        (item.state == "failed" || failure.contains('{') || failure.trim().lowercase(Locale.ROOT).startsWith("api error:"))

    fun problem(raw: String, agent: String): ChatFailure {
        var message = raw.trim(); var status: Int? = null; var code: String? = null
        repeat(6) {
            val start = message.indexOf('{'); val end = message.lastIndexOf('}')
            if (start < 0 || end < start) return@repeat
            val objectValue = runCatching { Json.parseToJsonElement(message.substring(start, end + 1)) as? JsonObject }.getOrNull() ?: return@repeat
            val error = objectValue["error"] as? JsonObject ?: objectValue
            val http = number(objectValue, "status") ?: number(error, "status")
            if (http != null && http in 400.0..599.0 && http % 1 == 0.0) status = http.toInt()
            val nextCode = text(error, "code").ifEmpty { text(error, "type") }
            if (nextCode != "error" && nextCode.matches(Regex("[A-Za-z0-9_.-]{1,80}"))) code = nextCode
            val next = text(error, "message").ifEmpty { text(objectValue, "message").ifEmpty { text(objectValue, "error") } }
            if (next.isEmpty() || next == message) message = "" else message = next.trim()
        }
        if (status == null) status = Regex("(?i)(?:HTTP(?:\\s+status)?|API\\s+error|status(?:\\s+code)?)\\s*[:=]?\\s*([45][0-9]{2})\\b").find(raw)?.groupValues?.get(1)?.toIntOrNull()
        val words = (message + " " + code.orEmpty()).lowercase(Locale.ROOT)
        fun contains(vararg values: String) = values.any(words::contains)
        val kind = when {
            contains("model_not_found", "unsupported_model") || words.contains("model") && contains("not supported", "unsupported", "not available", "does not exist", "may not exist", "do not have access", "don't have access", "not have access to it") -> "modelUnavailable"
            status == 401 || contains("authentication_error", "unauthorized", "invalid_api_key", "invalid api key", "token expired", "token has expired", "not logged in", "login required", "invalid_grant") -> "signIn"
            status == 403 || contains("permission_error", "permission_denied") -> "access"
            contains("insufficient_quota", "usage_limit", "usage limit", "weekly limit", "limit reached", "hit your", "credit balance", "billing_hard_limit") -> "quota"
            status == 429 || contains("rate_limit", "rate limit", "too many requests") -> "rateLimit"
            status?.let { it >= 500 } == true || contains("internal server error", "overloaded", "server_error", "service_unavailable") -> "service"
            status == 408 || contains("network", "econn", "timed out", "timeout", "connection", "offline", "dns") -> "network"
            status in setOf(400, 404, 422) || contains("invalid_request_error") -> "invalidRequest"
            raw.trim().isEmpty() || contains("stopped (", "exit code", "terminated", "killed") -> "stopped"
            else -> "unknown"
        }
        return when (kind) {
            "modelUnavailable" -> ChatFailure(kind, "This model isn’t available", "Choose another model on your Mac to try again.")
            "signIn" -> ChatFailure(kind, "Sign in to $agent again", "Reconnect your account in AI settings on your Mac, then try again.")
            "access" -> ChatFailure(kind, "$agent didn’t allow this request", "Check your account’s permissions in AI settings on your Mac before trying again.")
            "quota" -> ChatFailure(kind, "$agent is out of room on this plan for now.", "Wait for your plan’s limit to reset, or review your connected accounts on your Mac.")
            "rateLimit" -> ChatFailure(kind, "$agent is receiving too many requests", "Wait a moment before trying again.")
            "service" -> ChatFailure(kind, "$agent’s server failed partway.", "The service is temporarily unavailable. Try again in a moment.")
            "network" -> ChatFailure(kind, "The connection dropped partway.", "Check your Mac’s internet connection, then try again.")
            "invalidRequest" -> ChatFailure(kind, "$agent couldn’t accept this request", "Check the model and its settings on your Mac before trying again.")
            "stopped" -> ChatFailure(kind, "$agent stopped before it finished.", "You can try again to continue this chat.")
            else -> ChatFailure(kind, "$agent couldn’t finish.", "You can try again to continue this chat.")
        }
    }
}
