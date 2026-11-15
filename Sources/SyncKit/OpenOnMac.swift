import Foundation

/// A URL requested by the person on another device. It has no text or choice,
/// so an older Mac cannot mistake it for an agent prompt.
public enum OpenOnMac {
    public static let capability = "commandcap"
    public static let version = 1
    public static let lifetime: TimeInterval = 12 * 3600

    public enum Failure: Error, Equatable, LocalizedError {
        case invalid, unsupported, interrupted, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalid: return "Yab couldn't open that link."
            case .unsupported: return "Update Yab on your Mac to open this link."
            case .interrupted: return "This request was interrupted. Send the link again to open it."
            case .unavailable: return "Open Yab on your Mac and send the link again."
            }
        }
    }

    public static func url(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// `space`: the space the page was in on the sending device, as sync
    /// names it. A Mac that has that space opens the page there; an older
    /// Mac reads past it. `title`: the page's, for the words an iPhone shows
    /// as it arrives there ("From <Mac>: <title>"); a Mac reads past it.
    public static func fields(device: String, sender: String, url: URL, at: Date, space: String? = nil,
                              title: String? = nil) throws -> [String: Value] {
        guard !device.isEmpty, !sender.isEmpty, Self.url(url.absoluteString) != nil else { throw Failure.invalid }
        var fields: [String: Value] = ["device": .string(device), "clientDevice": .string(sender), "kind": "open",
                                       "url": .string(url.absoluteString), "at": .number(at.timeIntervalSince1970)]
        if let space = Self.space(.string(space ?? "")) { fields["space"] = .string(space) }
        if let title = Self.title(.string(title ?? "")) { fields["title"] = .string(title) }
        return fields
    }

    /// A page's title as the sender wrote it: one line, 200 characters at
    /// most, or nothing.
    public static func title(_ value: Value?) -> String? {
        guard let text = value?.string else { return nil }
        let line = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(200))
    }

    /// A space named by the sender: a UUID as sync writes it, or nothing.
    public static func space(_ value: Value?) -> String? {
        guard let text = value?.string, let id = UUID(uuidString: text) else { return nil }
        return id.uuidString
    }

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == capability, record.id == device, record.alive(),
              record["device"]?.string == device else { return false }
        return record["open"]?.number == Double(version)
    }

    /// Only the addressed Mac consumes this record. Its durable local receipt
    /// is committed with `opening` before `open` can touch a window or WebKit.
    /// The closure is injected in tests, where no real site is loaded.
    @discardableResult
    public static func consume(_ record: Record, in journal: Journal, device: String, at now: Date = Date(),
                               open: (URL) throws -> Void) throws -> Bool {
        guard record.collection == "send", record.alive(), record["device"]?.string == device,
              record["kind"]?.string == "open" else { return false }
        if record["state"]?.string == "opening" {
            try finish(record.key, in: journal, state: "failed", reason: Failure.interrupted.localizedDescription, at: now)
            return true
        }
        guard record["state"] == nil else { return false }
        guard try journal.claimCommand(record, fields: ["state": "opening"]) else {
            // A remote rewrite cannot reset the local receipt.
            if journal.record(record.key)?["state"] == nil {
                try finish(record.key, in: journal, state: "failed", reason: Failure.interrupted.localizedDescription, at: now)
            }
            return true
        }
        guard let sender = record["clientDevice"]?.string, !sender.isEmpty,
              record["chat"] == nil, record["text"] == nil, record["choice"] == nil, record["project"] == nil,
              let text = record["url"]?.string, let url = url(text),
              let sent = record["at"]?.number, sent.isFinite, sent <= now.timeIntervalSince1970 + 300 else {
            try finish(record.key, in: journal, state: "failed", reason: Failure.invalid.localizedDescription, at: now)
            return true
        }
        guard now.timeIntervalSince1970 - sent <= lifetime else {
            try finish(record.key, in: journal, state: "expired", at: now)
            return true
        }
        do {
            try open(url)
            try finish(record.key, in: journal, state: "taken", at: now)
        } catch {
            // A failure after the claim never causes another open on a retry.
            try finish(record.key, in: journal, state: "failed", reason: Failure.unavailable.localizedDescription, at: now)
        }
        return true
    }

    private static func finish(_ key: Record.Key, in journal: Journal, state: String, reason: String? = nil, at: Date) throws {
        try journal.change(key, ["state": .string(state), "reason": Value(reason), "took": .number(at.timeIntervalSince1970)])
    }
}
