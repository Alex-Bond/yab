import Foundation

/// A chat request is attempted only after its local receipt has committed.
/// A restart can report interruption; it cannot repeat an uncertain effect.
public enum ChatCommand {
    public static let lifetime: TimeInterval = 12 * 3600
    public static let invalid = "Yab couldn't read that chat request. Send the question again."
    public static let interrupted = "The Mac was interrupted while taking this question. Its outcome is unknown. Check the chat before asking again."

    public enum Outcome: Equatable {
        case taken(chat: String? = nil)
        case failed(String)
    }

    /// Kept separate from the Mac dispatcher so malformed fields cannot invoke it.
    public static func refusal(_ record: Record) -> String? {
        let kind = record["kind"]?.string ?? "agent"
        if record["kind"] != nil && record["kind"]?.string == nil { return invalid }
        guard kind == "agent" else { return invalid }
        if record["answerIndex"] != nil || record["choiceQuestion"] != nil { return SyncChoice.targetReason }
        if let value = record["choice"] {
            return SyncChoice.index(value) == nil ? SyncChoice.invalidReason : SyncChoice.targetReason
        }
        if record["chat"] != nil {
            guard let chat = record["chat"]?.string, chat.count > 2, chat.hasPrefix("a:") else { return SyncChoice.targetReason }
        }
        // A new chat in a project; words for a chat go where it is.
        if record["project"] != nil {
            guard ChatProjects.valid(record["project"]?.string), record["chat"] == nil else { return invalid }
        }
        let explicit = record["agentText"]
        let selected = record["cli"]?.string.flatMap(ChatAgent.init(rawValue:))
        // Files attached (SyncSendFile) are something to say without words.
        let files = record["files"]?.array?.isEmpty == false
        if record["cli"] != nil || explicit != nil {
            guard selected != nil, let text = explicit?.string, !text.isEmpty || files,
                  text.utf8.count <= 524_288, record["text"] == nil, record["chat"] == nil,
                  record["choice"] == nil, kind == "agent" else { return ChatAgent.invalid }
        } else {
            if record["text"] != nil && record["text"]?.string == nil { return invalid }
            guard record["text"]?.string?.isEmpty == false || files else { return invalid }
            if let text = record["text"]?.string, text.utf8.count > 524_288 { return invalid }
        }
        return nil
    }

    /// Account/device come from this live client, never from remote claim fields.
    /// This guarantees one dispatch attempt within the retained local journal.
    @discardableResult
    public static func consume(_ record: Record, in journal: Journal, account: String, device: String,
                               at now: Date = Date(), dispatch: (Record) throws -> Outcome) throws -> Bool {
        guard record.collection == "send", record.alive(), record["device"]?.string == device,
              record["kind"]?.string != "open" else { return false }
        let state = record["state"]?.string
        guard record["state"] == nil || state == "processing" else { return false }
        if state == "processing" {
            try journal.finishChatCommand(record, account: account, device: device,
                                          fields: terminal(.failed(interrupted), at: now))
            return true
        }
        let began = ProcessInfo.processInfo.systemUptime
        let claimed: Record
        switch try journal.claimChatCommand(record, account: account, device: device) {
        case .stale: return false
        case .alreadyClaimed:
            try journal.finishChatCommand(record, account: account, device: device,
                                          fields: terminal(.failed(interrupted), at: now))
            return true
        case let .claimed(saved): claimed = saved
        }
        // Include a database wait in the immutable request's age before dispatch.
        let current = now.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime - began))
        let outcome: Outcome
        if let reason = refusal(record) { outcome = .failed(reason) }
        else if let sent = record["at"]?.number, sent.isFinite, current.timeIntervalSince1970.isFinite,
                sent > 0, sent <= current.timeIntervalSince1970 + 300 {
            if current.timeIntervalSince1970 - sent > lifetime {
                try journal.finishChatCommand(claimed, account: account, device: device,
                                              fields: ["state": "expired", "took": .number(current.timeIntervalSince1970)])
                return true
            }
            do { outcome = try dispatch(record) }
            catch { outcome = .failed(interrupted) }
        } else { outcome = .failed(invalid) }
        try journal.finishChatCommand(claimed, account: account, device: device, fields: terminal(outcome, at: current))
        return true
    }

    private static func terminal(_ outcome: Outcome, at now: Date) -> [String: Value] {
        var fields: [String: Value] = ["took": .number(now.timeIntervalSince1970)]
        switch outcome {
        case let .taken(chat):
            fields["state"] = "taken"
            fields["reason"] = .null
            if let chat { fields["chat"] = .string(chat) }
        case let .failed(reason):
            fields["state"] = "failed"
            fields["reason"] = .string(reason)
        }
        return fields
    }
}
