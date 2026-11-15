import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// What a turn did on the Mac, read from its synced chat items (docs/sync.md,
/// `chatitem`) and said as the Mac's chat says it (ChatTranscript.ChatTurn):
/// while it works only its subagents show, never its steps; once over, a
/// line of what it did with its steps a tap away, and why it couldn't finish.
struct TurnWork: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Under a finished answer: Copy, Ask Again, its sites and steps, when.
        case actions
        /// A turn over with no answer: "You stopped after 40s · 6 steps".
        case worked
        /// Why the last turn couldn't finish, and Try Again.
        case failure
        /// Its thoughts, folded: "Thought for 12s".
        case thought
        /// Its subagents at work, a card each, while the turn goes on.
        case subagents
        /// A subagent's report the agent was handed: its card, not your words.
        case report
    }

    var kind: Kind
    /// Its turn's first item and its kind: where a fold opened stays open.
    var id = ""
    /// "Worked for 1m 12s", "You stopped after 40s", "Thought for 12s".
    var words = ""
    /// Its steps in the order they came, repeats kept (`runs` folds them).
    var steps: [Step] = []
    /// The answer to copy, its thinking, a report's body.
    var text = ""
    /// What the turn asked, for Ask Again and Try Again; nil while the chat runs.
    var question: String?
    /// When the answer came: the time at the end of the actions.
    var at: Date?
    /// A failure's cause and what to do; a report's subagent and its gist.
    var title = ""
    var detail = ""
    var subagents: [Subagent] = []

    /// One step as the Mac kept it: its kind, the tool's name, what it was
    /// about, its words (why it failed, what a command printed, a report).
    struct Step: Codable, Hashable, Sendable {
        var id: String
        var kind: String
        var name: String
        var detail: String
        var text = ""
        /// running, done, failed, or stopped (left running when you stopped the turn).
        var state: String
        var began: Date?
        var ended: Date?
    }

    /// A subagent at work: what it was asked to do, and since when.
    struct Subagent: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var since: Date?
    }

    init(kind: Kind, id: String = "", words: String = "", steps: [Step] = [], text: String = "", question: String? = nil, at: Date? = nil,
         title: String = "", detail: String = "", subagents: [Subagent] = []) {
        self.kind = kind
        self.id = id
        self.words = words
        self.steps = steps
        self.text = text
        self.question = question
        self.at = at
        self.title = title
        self.detail = detail
        self.subagents = subagents
    }

    enum CodingKeys: String, CodingKey { case kind, id, words, steps, text, question, at, title, detail, subagents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        words = try c.decodeIfPresent(String.self, forKey: .words) ?? ""
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        question = try c.decodeIfPresent(String.self, forKey: .question)
        at = try c.decodeIfPresent(Date.self, forKey: .at)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        subagents = try c.decodeIfPresent([Subagent].self, forKey: .subagents) ?? []
    }

    /// The steps that did any work (a pick you made isn't one).
    var work: [Step] { steps.filter { $0.kind != "chose" } }
    var failedCount: Int { work.filter { $0.state == "failed" }.count }

    /// "Worked for 6m · 29 steps".
    var summary: String {
        let count = work.count
        return count == 0 ? words : words + " \u{00B7} \(count) " + (count == 1 ? "step" : "steps")
    }
}

// MARK: - from the chat's items

extension TurnWork {
    /// A chat's items as turns: each question you asked begins one, words
    /// added while it worked stay in it, steps before the first question
    /// make a turn of their own (Chat.turns).
    static func turns(_ items: [SyncChatItem]) -> [[SyncChatItem]] {
        var out: [[SyncChatItem]] = []
        for item in items where !item.isInternal {
            if item.kind == "asked" && item.name != "steer" || out.isEmpty { out.append([item]) } else { out[out.count - 1].append(item) }
        }
        return out
    }

    /// Lines of Yab's between the agent's words, never its answer
    /// (ChatItem.asides, ChatItem.notes), told apart by their name.
    static let asides: Set<String> = ["compacted", "note", "status", "error", "notice", "sent", "review"]
    /// The line where one agent ran out of room and the other carried on.
    static let handedOver = "handover"
    /// What it asked you to pick from, said as its message (ChatItem.question).
    static let question = "question"
    /// A turn you stopped: a message of no words (ChatItem.stopped).
    static let stopped = "stopped"

    /// The agent's own words, not Yab's lines round them nor its answer to a
    /// report that changes nothing.
    static func said(_ item: SyncChatItem) -> Bool {
        item.kind == "message" && !asides.contains(item.name) && item.name != handedOver && item.name != stopped
            && !SubagentReport.isQuiet(item.text) && !item.text.isEmpty
    }

    /// A line of Yab's in the chat, in words: compacted, a notice, an error
    /// that didn't end the turn, who carried on. Nil for none.
    static func note(_ item: SyncChatItem, agent: String) -> String? {
        guard item.kind == "message" else { return nil }
        if item.name == "compacted" { return "Context compacted" }
        guard asides.contains(item.name) || item.name == handedOver, !item.text.isEmpty else { return nil }
        return item.name == "error" ? ChatProblem(item.text, agent: agent).title : item.text
    }

    /// A thought read off the Mac's transcript, folded in the chat
    /// (ChatItem.isThought); the live stream's thinking is never shown.
    static func isThought(_ item: SyncChatItem) -> Bool { item.kind == "thinking" && item.name == "thought" }

    /// "Thought for 12s", or "Thought" with no time kept.
    static func thoughtWords(_ items: [SyncChatItem]) -> String {
        let seconds = items.reduce(0.0) { sum, item in
            guard let began = item.began, let ended = item.ended, ended > began else { return sum }
            return sum + (ended - began)
        }
        return seconds >= 1 ? "Thought for " + span(seconds) : "Thought"
    }

    static func stopped(in turn: [SyncChatItem]) -> Bool {
        turn.contains { $0.kind == "message" && $0.name == stopped }
    }

    /// How a turn stood once over: stopped, failed (only the chat's last
    /// turn can be), else done.
    static func ending(_ turn: [SyncChatItem], last: Bool, state: String) -> String {
        if stopped(in: turn) { return "stopped" }
        return last && state == "failed" ? "failed" : "done"
    }

    /// The steps a turn's list shows: tools, commands, edits and subagents
    /// that did work; Yab's bookkeeping never gets a row. A step still
    /// going when the turn ended didn't get done if it failed, and was
    /// stopped where you stopped it.
    static func steps(_ turn: [SyncChatItem], ending: String, working: Bool = false) -> [Step] {
        turn.compactMap { item in
            guard ["tool", "command", "edit", "subagent"].contains(item.kind), !StepWords.of(item).quiet else { return nil }
            var state = item.state
            if state == "running", !working { state = ending == "failed" ? "failed" : ending == "stopped" ? "stopped" : "done" }
            return Step(id: item.id, kind: item.kind, name: item.name, detail: item.detail, text: item.text, state: state,
                        began: item.began.map(Date.init(timeIntervalSince1970:)), ended: item.ended.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// The tools that wait on the person: their time isn't work (Chat.asking).
    static let asking: Set<String> = ["ask", "AskUserQuestion", "handoff", "computer_access", "folder_access"]

    /// How long a turn's work went on, from its first step to its last,
    /// less the time it waited on you (Chat.worked).
    static func worked(_ turn: [SyncChatItem]) -> TimeInterval? {
        let starts = turn.compactMap(\.began)
        let ends = turn.compactMap { $0.ended ?? $0.began }
        guard let first = starts.min(), let last = ends.max(), last > first else { return nil }
        let waited = turn.filter { $0.kind == "tool" && asking.contains($0.name) }.reduce(0.0) { sum, item in
            guard let began = item.began else { return sum }
            return sum + max(0, (item.ended ?? last) - began)
        }
        return max(1, last - first - waited)
    }

    /// "40s", "1m 12s", "1h 3m" (Chat.span).
    static func span(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole % 3600 / 60)m"
    }

    /// The line under a turn that is over (ChatTurn.doneWords).
    static func doneWords(_ ending: String, seconds: TimeInterval?) -> String {
        let span = seconds.map(span)
        switch ending {
        case "stopped": return span.map { "You stopped after " + $0 } ?? "You stopped it"
        case "failed": return span.map { "Couldn\u{2019}t finish after " + $0 } ?? "Couldn\u{2019}t finish"
        default: return span.map { "Worked for " + $0 } ?? "Done"
        }
    }

    /// The subagents a running turn has at work: the ones it started that
    /// haven't reported yet.
    static func live(_ turn: [SyncChatItem]) -> [Subagent] {
        turn.filter { item in
            item.state == "running" && (item.kind == "subagent" && !["toParent", "wait", "sendInput", "sendMessage", "followupTask", "closeAgent", "interruptAgent"].contains(item.name)
                || item.kind == "tool" && item.name == "subagent")
        }.map { item in
            let name = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return Subagent(id: item.id, name: name.isEmpty ? "Subagent" : String(name.prefix(80)),
                            since: item.began.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// Steps in a row that did the same to the same, as one (ChatSteps.runs).
    static func runs(_ steps: [Step]) -> [[Step]] {
        var out: [[Step]] = []
        for step in steps {
            if let last = out.last?.first, last.kind == step.kind, last.name == step.name, last.detail == step.detail,
               step.state != "running", last.state == step.state {
                out[out.count - 1].append(step)
            } else {
                out.append([step])
            }
        }
        return out
    }

    /// The sites a turn worked on, in the order it came to them (ChatSteps.hosts).
    /// Only steps that went to a site count: a file read, Package.swift,
    /// looks like a host and isn't one.
    static func hosts(_ steps: [Step]) -> [String] {
        var out: [String] = []
        for step in steps where step.kind == "tool" || step.kind == "subagent" {
            guard let site = StepWords.of(step).site else { continue }
            for host in StepWords.hosts(step.detail).map(StepWords.bare) where !out.contains(host) { out.append(host) }
            if !out.contains(site) { out.append(site) }
        }
        return out
    }

    /// How long a command or a subagent took, once it is two seconds or more.
    static func took(_ step: Step) -> String? {
        guard ["command", "subagent"].contains(step.kind), step.state != "running",
              let began = step.began, let ended = step.ended, ended.timeIntervalSince(began) >= 2 else { return nil }
        return span(ended.timeIntervalSince(began))
    }

    /// Why a step failed, in its own words: a command's telling line from the
    /// end of what it printed, another step's first (ChatSteps.why).
    static func why(_ step: Step) -> String? {
        let lines = step.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { return nil }
        let line = step.kind == "command" ? lines.last { $0.lowercased().contains("error") } ?? last : first
        return line.count > 160 ? String(line.prefix(159)) + "\u{2026}" : line
    }
}

// MARK: - a subagent's report

/// A subagent's report as Yab hands it to its task (the Mac's
/// SubagentReport): said to the agent as yours, drawn as the subagent's card.
struct SubagentReport: Equatable {
    let name: String
    let id: String
    /// How its session ended: done, stopped, failed.
    let state: String
    let body: String

    static let quiet = "(quiet)"
    private static let head = "Subagent "
    private static let done = ") is done ("
    private static let asking = """

        ---
        If this report changes nothing in what you have told the user, answer with exactly \(quiet) \
        and nothing else. Otherwise tell the user plainly what it changes and what that means for \
        them, in a sentence or two.
        """

    static func isQuiet(_ words: String) -> Bool { words.trimmingCharacters(in: .whitespacesAndNewlines) == quiet }

    init?(_ said: String) {
        guard said.hasPrefix(Self.head) else { return nil }
        var text = said
        if let asked = text.range(of: Self.asking) { text.removeSubrange(asked) }
        guard let done = text.range(of: Self.done) else { return nil }
        let named = text[text.index(text.startIndex, offsetBy: Self.head.count)..<done.lowerBound]
        guard let open = named.range(of: " (", options: .backwards) else { return nil }
        name = String(named[..<open.lowerBound])
        id = String(named[open.upperBound...])
        let rest = text[done.upperBound...]
        state = String(rest.prefix { $0 != "," && $0 != ")" })
        let body = rest.firstRange(of: "\n\n").map { String(rest[$0.upperBound...]) } ?? ""
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !id.isEmpty else { return nil }
    }

    /// Its finding in one line, under its name.
    var gist: String {
        if body.isEmpty || body.hasPrefix("Stopped at the ") && body.hasSuffix("without a report.") {
            return state == "done" ? "No report" : "Stopped without a report"
        }
        let lines = body.split(whereSeparator: \.isNewline).map { Self.plain(String($0)).trimmingCharacters(in: .whitespaces) }
        let line = lines.first { !$0.isEmpty && !$0.hasPrefix("```") && $0 != "---" } ?? ""
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "-*\u{2022} "))
    }

    /// A line of Markdown in plain words: its links' words, no marks (Chat.plain).
    static func plain(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - why it couldn't finish

/// What went wrong in plain words, from what the agent said (the Mac's
/// ChatProblem): the cause and what to do. The iPhone offers only Try Again.
struct ChatProblem {
    enum Kind { case modelUnavailable, signIn, access, quota, rateLimit, service, network, invalidRequest, stopped, unknown }

    let kind: Kind
    let agent: String

    init(_ raw: String, agent: String) {
        self.agent = agent
        let (status, code, message) = Self.extract(raw)
        let text = (message + " " + (code ?? "")).lowercased()
        if text.contains("model_not_found") || text.contains("unsupported_model") ||
            (text.contains("model") && ["not supported", "unsupported", "not available", "does not exist", "may not exist", "do not have access",
                                         "don't have access", "not have access to it"].contains(where: text.contains)) {
            kind = .modelUnavailable
        } else if status == 401 || ["authentication_error", "unauthorized", "invalid_api_key", "invalid api key", "token expired", "token has expired",
                                    "not logged in", "login required", "invalid_grant"].contains(where: text.contains) {
            kind = .signIn
        } else if status == 403 || text.contains("permission_error") || text.contains("permission_denied") {
            kind = .access
        } else if ["insufficient_quota", "usage_limit", "usage limit", "weekly limit", "limit reached", "hit your", "credit balance",
                   "billing_hard_limit"].contains(where: text.contains) {
            kind = .quota
        } else if status == 429 || text.contains("rate_limit") || text.contains("rate limit") || text.contains("too many requests") {
            kind = .rateLimit
        } else if status.map({ $0 >= 500 }) == true || ["internal server error", "overloaded", "server_error", "service_unavailable"].contains(where: text.contains) {
            kind = .service
        } else if status == 408 || ["network", "econn", "timed out", "timeout", "connection", "offline", "dns"].contains(where: text.contains) {
            kind = .network
        } else if status == 400 || status == 404 || status == 422 || text.contains("invalid_request_error") {
            kind = .invalidRequest
        } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ["stopped (", "exit code", "terminated", "killed"].contains(where: text.contains) {
            kind = .stopped
        } else {
            kind = .unknown
        }
    }

    var title: String {
        switch kind {
        case .modelUnavailable: "This model isn\u{2019}t available"
        case .signIn: "Sign in to \(agent) again"
        case .access: "\(agent) didn\u{2019}t allow this request"
        case .quota: "\(agent) is out of room on this plan for now."
        case .rateLimit: "\(agent) is receiving too many requests"
        case .service: "\(agent)\u{2019}s server failed partway."
        case .network: "The connection dropped partway."
        case .invalidRequest: "\(agent) couldn\u{2019}t accept this request"
        case .stopped: "\(agent) stopped before it finished."
        case .unknown: "\(agent) couldn\u{2019}t finish."
        }
    }

    /// The Mac's words, where they point at its own settings: said as on your Mac.
    var detail: String {
        switch kind {
        case .modelUnavailable: "Choose another model on your Mac to try again."
        case .signIn: "Reconnect your account in AI settings on your Mac, then try again."
        case .access: "Check your account\u{2019}s permissions in AI settings on your Mac before trying again."
        case .quota: "Wait for your plan\u{2019}s limit to reset, or review your connected accounts on your Mac."
        case .rateLimit: "Wait a moment before trying again."
        case .service: "The service is temporarily unavailable. Try again in a moment."
        case .network: "Check your Mac\u{2019}s internet connection, then try again."
        case .invalidRequest: "Check the model and its settings on your Mac before trying again."
        case .stopped, .unknown: "You can try again to continue this chat."
        }
    }

    /// Both CLIs send envelopes, plain messages, and JSON inside messages.
    private static func extract(_ raw: String) -> (Int?, String?, String) {
        var message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var status: Int?
        var code: String?
        for _ in 0..<6 {
            guard let start = message.firstIndex(of: "{"), let end = message.lastIndex(of: "}"), start <= end,
                  let data = String(message[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let error = object["error"] as? [String: Any] ?? object
            if let http = (object["status"] as? Int) ?? (error["status"] as? Int), (400...599).contains(http) { status = http }
            let name = error["code"] as? String ?? error["type"] as? String
            if let name, name != "error", name.range(of: #"^[A-Za-z0-9_.-]{1,80}$"#, options: .regularExpression) != nil { code = name }
            let next = error["message"] as? String ?? object["message"] as? String ?? object["error"] as? String
            guard let next, next != message else { message = ""; break }
            message = next.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if status == nil,
           let range = raw.range(of: #"(?i)(?:HTTP(?:\s+status)?|API\s+error|status(?:\s+code)?)\s*[:=]?\s*([45][0-9]{2})\b"#, options: .regularExpression),
           let digits = raw[range].range(of: #"[45][0-9]{2}$"#, options: .regularExpression) {
            status = Int(raw[digits])
        }
        return (status, code, message)
    }

    /// A message that only repeats the error that ended the turn: the
    /// failure card says it (Chat.visibleMessage).
    static func repeats(_ item: SyncChatItem, failure: String) -> Bool {
        guard item.text == failure else { return false }
        return item.state == "failed" || failure.contains("{")
            || failure.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("api error:")
    }
}
