import CryptoKit
import Foundation

/// An assistant's question and a person's answer travel only inside the
/// account's sealed Sync journal. The assistant relay receives neither.
public enum AssistantApprovalRecords {
    public static let requestCollection = "assistantapproval"
    public static let answerCollection = "assistantanswer"
    private static let limit = 16_384

    public enum Failure: Error, Equatable {
        case invalid, owner, changed, expired
    }

    /// Said in a device's own commandcap record by a Yab that shows these
    /// questions and answers them; a device without it (an older iPhone
    /// build) gets the record but has nowhere to show it. Version 2 also
    /// picks one of a request's choices (a sign-in's account) and says the
    /// answer was proven there with Face ID, Touch ID or the passcode.
    public static let field = "assistantApprovals"
    public static let version = 2

    public static func answers(_ record: Record?, device: String) -> Bool {
        said(record, device: device) >= 1
    }

    /// A device that picks a choice and proves its answer (version 2).
    public static func chooses(_ record: Record?, device: String) -> Bool {
        said(record, device: device) >= 2
    }

    private static func said(_ record: Record?, device: String) -> Double {
        guard let record, record.collection == OpenOnMac.capability, record.id == device, record.alive(),
              record.stamps[field]?.device == device, let said = record[field]?.number else { return 0 }
        return said
    }

    public static func register() {
        Kind.register(Kind(requestCollection, removalWins: true))
        Kind.register(Kind(answerCollection, removalWins: true))
        registerDetails()
    }

    public struct Seen: Codable, Equatable, Sendable {
        public let device: String
        public let at: Double
        public init(device: String, at: Date = Date()) { self.device = device; self.at = at.timeIntervalSince1970 }
    }

    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let account: String
        public let mac: String
        public let assistant: String
        public let session: String
        public let tab: String
        public let permit: String
        public let title: String
        public let lines: [String]
        public let issued: Double
        public let expires: Double
        /// What the answer picks among (a sign-in's accounts), version 2;
        /// absent from a plain yes or no, so its digest is version 1's.
        public let choices: [String]?
        public var seen: Seen? = nil
        public var isChat: Bool { tab.hasPrefix("chat:") }
        public var yesLabel: String {
            guard isChat else { return "Approve" }
            if permit == "mail.read" { return "Search" }
            if permit.hasPrefix("mail.site:") { return "Go" }
            return "Allow"
        }
        public static func validPlace(_ place: String) -> Bool {
            UUID(uuidString: place) != nil || (place.hasPrefix("chat:") && place.utf8.count > 5 && place.utf8.count <= 261)
        }

        public init(id: String, account: String, mac: String, assistant: String, session: String,
                    tab: String, permit: String, title: String, lines: [String],
                    issued: Date = Date(), expires: Date, choices: [String]? = nil) throws {
            self.id = id; self.account = account; self.mac = mac; self.assistant = assistant
            self.session = session; self.tab = tab; self.permit = permit; self.title = title
            self.lines = lines; self.issued = issued.timeIntervalSince1970; self.expires = expires.timeIntervalSince1970
            self.choices = choices
            try validate()
        }

        public func validate(at now: Date? = nil) throws {
            guard UUID(uuidString: id) != nil, Self.validPlace(tab),
                  [account, mac, assistant, session, permit].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
                  !title.isEmpty, title.utf8.count <= 300, lines.count <= 20,
                  lines.allSatisfy({ $0.utf8.count <= 2_000 }),
                  choices.map({ !$0.isEmpty && $0.count <= 3 && Set($0).count == $0.count
                      && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 } }) ?? true,
                  seen.map({ $0.device == mac && $0.at.isFinite && $0.at >= issued - 300 }) ?? true,
                  issued.isFinite, expires.isFinite, expires > issued, expires - issued <= 86_400,
                  try encoded().utf8.count <= limit else { throw Failure.invalid }
            if let now, now.timeIntervalSince1970 >= expires { throw Failure.expired }
        }

        /// Who asks and what, as the title says them ("Claude: Pay $12?").
        public var asker: String { title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? title }
        public var question: String {
            let parts = title.split(separator: ":", maxSplits: 1)
            return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : title
        }

        /// The facts under the title on one short line, for a notification:
        /// the site, what for, the amount. A draft's words stay on the card.
        public var summary: String {
            String(lines.prefix(3).filter { !$0.contains("\n") }.joined(separator: " \u{B7} ").prefix(180))
        }

        public func digest() throws -> String {
            try validate()
            // Opening the question changes no fact the person approves.
            var facts = self
            facts.seen = nil
            let bytes = Data(("yab assistant approval v1\n" + (try facts.encoded())).utf8)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }

        public func fields() throws -> [String: Value] { ["body": .string(try encoded())] }

        public static func read(_ record: Record, account: String, mac: String) throws -> Request {
            let request: Request = try decode(record, collection: requestCollection, writer: mac)
            try request.validate()
            guard request.id.lowercased() == record.id.lowercased(), request.account == account,
                  request.mac == mac else { throw Failure.owner }
            return request
        }

        private func encoded() throws -> String { try AssistantApprovalRecords.encode(self) }
    }

    public struct Answer: Codable, Equatable, Sendable {
        public let id: String
        public let account: String
        public let mac: String
        public let device: String
        public let requestDigest: String
        public let yes: Bool
        public let at: Double
        /// The choice a yes picked, one of the request's (version 2).
        public let choice: String?
        /// Proven on that device, Face ID, Touch ID or its passcode, before
        /// this answer (version 2).
        public let proved: Bool?
        /// The detail this yes read (version 3); absent from a device that
        /// read only the lines, so its answer encodes as version 2's.
        public let detailDigest: String?
        /// A payment's card and address picked there, the detail's or one
        /// just kept on that device (`added`), checked by `validatePicks`.
        public let card: String?
        public let place: String?
        public let added: [String]?

        public init(request: Request, device: String, yes: Bool, at: Date = Date(),
                    choice: String? = nil, proved: Bool = false, detail: Detail? = nil,
                    card: String? = nil, place: String? = nil, added: [String] = []) throws {
            id = request.id; account = request.account; mac = request.mac; self.device = device
            requestDigest = try request.digest(); self.yes = yes; self.at = at.timeIntervalSince1970
            self.choice = choice; self.proved = proved ? true : nil
            detailDigest = try detail?.digest()
            self.card = yes ? card : nil; self.place = yes ? place : nil
            self.added = yes && !added.isEmpty ? added : nil
            try validate(request: request)
            try AssistantApprovalRecords.validatePicks(self, detail: detail)
        }

        public func validate(request: Request, now: Date = Date()) throws {
            try request.validate(at: now)
            guard id == request.id, account == request.account, mac == request.mac,
                  device != mac, !device.isEmpty, device.utf8.count <= 256,
                  requestDigest == (try request.digest()), at.isFinite,
                  at >= request.issued - 300, at <= min(now.timeIntervalSince1970 + 300, request.expires + 300),
                  // A yes to a request with choices picks one of them; a no
                  // and a plain yes or no pick nothing.
                  yes && request.choices != nil ? request.choices?.contains(choice ?? "") == true : choice == nil,
                  try AssistantApprovalRecords.encode(self).utf8.count <= limit else { throw Failure.changed }
        }

        public func fields() throws -> [String: Value] { ["body": .string(try AssistantApprovalRecords.encode(self))] }

        public static func read(_ record: Record, request: Request, device: String, now: Date = Date()) throws -> Answer {
            let answer: Answer = try decode(record, collection: answerCollection, writer: device)
            guard answer.id.lowercased() == record.id.lowercased(), answer.device == device else { throw Failure.owner }
            try answer.validate(request: request, now: now)
            return answer
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ record: Record, collection: String, writer: String) throws -> T {
        guard record.collection == collection, record.schema == 1, record.alive(),
              Set(record.fields.keys) == ["body"], record.stamps["body"]?.device == writer,
              let body = record["body"]?.string, body.utf8.count <= limit else { throw Failure.owner }
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }
}

// MARK: - how the asking Mac says it

extension AssistantApprovalRecords {
    /// How a question goes up (docs/approvals.md, "Reaching the iPhone").
    /// `ringing`: an alert on the other devices. `quiet`: the person is at
    /// the Mac, so it goes up already opened (`seen`): another device has
    /// it, answerable, but doesn't ring, and the push is an ordinary one,
    /// so the question's one withdrawal is still unspent. `opened`: seen on
    /// the Mac, its notifications taken off elsewhere.
    public enum Saying: Sendable { case ringing, quiet, opened }

    public static func publish(_ request: Request, _ saying: Saying, by client: SyncClient) throws {
        var request = request
        request.seen = saying == .ringing ? nil : (request.seen ?? Seen(device: request.mac))
        let key = Record.Key(collection: requestCollection, id: request.id)
        try client.journal.change(key, request.fields())
        switch saying {
        case .ringing: client.kick(alerting: key)
        case .quiet: client.kick()
        case .opened: client.kick(alerting: key, withdraw: true)
        }
    }

    /// A question that went up quiet, rung now (the person left the Mac):
    /// its `seen` taken off, so the other devices alert. Its facts and
    /// digest stay, so an answer given to the quiet one still holds. False
    /// when it isn't in Sync.
    @discardableResult
    public static func ring(_ id: String, by client: SyncClient, mac: String) throws -> Bool {
        let key = Record.Key(collection: requestCollection, id: id)
        guard let original = client.journal.record(key), original.alive() else { return false }
        var request = try Request.read(original, account: client.seal.account, mac: mac)
        guard request.seen != nil else { return true }
        request.seen = nil
        try client.journal.change(key, request.fields())
        client.kick(alerting: key)
        return true
    }
}
