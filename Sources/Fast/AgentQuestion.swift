import Foundation

/// Questions and permission replies used by live agent sessions.
enum AgentQuestion {
    struct Question: Equatable {
        var id: String?
        var text: String
    }

    /// How a wait is answered.
    enum Reply: Equatable {
        case allow
        /// Allowed, and the rules it suggested kept for the session.
        case always
        /// Allowed, and the chat goes on in this permission mode
        /// ("acceptEdits", "default").
        case mode(String)
        /// No, with your words when you said any.
        case deny(String?)
        /// Its questions answered, by each question's words.
        case answers([String: [String]])
    }

    /// Claude's questions ({question, header, multiSelect, options: [{label,
    /// description}]}), Codex's server's ({id, header, question, options}),
    /// or Codex's transcript's ({title, options: [String]}).
    static func questions(_ raw: Any?) -> [Question] {
        func words(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return (raw as? [[String: Any]] ?? []).compactMap { asked in
            guard let text = words(asked["question"]) ?? words(asked["title"]) else { return nil }
            return Question(id: words(asked["id"]), text: text)
        }
    }

    /// Claude Code's mode as Yab's composer names it: its "default" is Manual.
    static func ours(_ mode: String) -> String { mode == "default" ? "manual" : mode }

    // MARK: - answers on the wire

    static let denied = "The person said no to this. Don't try it another way; say what you would have done."

    /// Claude Code's `control_response` body for `can_use_tool`, checked
    /// against its own schema (2.1.287): allow with `updatedInput` and
    /// `updatedPermissions`, or deny with a `message`. A mode goes as the
    /// `setMode` permission update, applied before the tool runs, so
    /// ExitPlanMode finds the chat out of plan mode and keeps it there.
    /// AskUserQuestion reads its answers from its input: `answers`, keyed
    /// by each question's words, several picks joined with ", ".
    static func response(_ reply: Reply, input: [String: Any], suggestions: [Any]?) -> [String: Any] {
        switch reply {
        case .allow:
            return ["behavior": "allow", "updatedInput": input]
        case .always:
            var answer: [String: Any] = ["behavior": "allow", "updatedInput": input]
            if let suggestions, !suggestions.isEmpty { answer["updatedPermissions"] = suggestions }
            return answer
        case .mode(let mode):
            return ["behavior": "allow", "updatedInput": input,
                    "updatedPermissions": [["type": "setMode", "mode": mode, "destination": "session"]]]
        case .deny(let words):
            let said = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ["behavior": "deny", "message": said.isEmpty ? denied : said]
        case .answers(let picked):
            var changed = input
            changed["answers"] = claudeAnswers(picked)
            return ["behavior": "allow", "updatedInput": changed]
        }
    }

    static func claudeAnswers(_ picked: [String: [String]]) -> [String: String] {
        picked.mapValues { $0.joined(separator: ", ") }
    }

    /// Codex's server's answer to `item/tool/requestUserInput`: each
    /// question's id with its answers.
    static func codexAnswers(_ picked: [String: [String]], questions: [Question]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for question in questions {
            guard let id = question.id, let said = picked[question.text] else { continue }
            answers[id] = ["answers": said]
        }
        return answers
    }
}
