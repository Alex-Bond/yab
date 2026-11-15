import CryptoKit
import Foundation

/// Task records are transport only. They never grant an agent permission,
/// enroll a signing key, or fall back to a legacy chat send.
public enum TaskRecords {
    public static let version = 1
    public static let requestCollection = "taskcommand"
    public static let observationCollection = "task"
    private static let bodyLimit = 524_288

    public enum Failure: Error, Equatable {
        case invalid, privateOrigin, unsupported, owner, stale, storage
    }

    public static func register() {
        Kind.register(Kind(requestCollection, removalWins: true))
        Kind.register(Kind(observationCollection, removalWins: true))
    }

    /// This capability permits record transport, not task execution.
    public static func supports(_ record: Record?, mac: String) -> Bool {
        guard let record, record.schema == 1, record.collection == OpenOnMac.capability, record.id == mac,
              record.alive(), record["device"]?.string == mac,
              record["taskRecords"]?.number == Double(version),
              record.stamps["device"]?.device == mac,
              record.stamps["taskRecords"]?.device == mac else { return false }
        return true
    }

    /// Read-only execution eligibility is separate from record transport. Only
    /// the owning Mac can advertise this version and producer-lifetime epoch.
    /// This decoder publishes nothing and grants no browser action approval.
    public static let readOnlyVersion = 1
    public static func readOnlyEpoch(_ record: Record?, mac: String) -> String? {
        guard supports(record, mac: mac), let record,
              record["taskReadOnly"]?.number == Double(readOnlyVersion),
              record.stamps["taskReadOnly"]?.device == mac,
              record.stamps["taskReadOnlyEpoch"]?.device == mac,
              let epoch = record["taskReadOnlyEpoch"]?.string, uuid(epoch) else { return nil }
        return epoch
    }

    /// Captured by the caller from the actual source, not the later selected tab.
    /// The engine additionally resolves its public space and tab from its journal.
    public struct Origin: Equatable, Sendable {
        public let space: String
        public let tab: String?
        public let url: String?
        public let title: String?
        public let isPrivate: Bool

        public init(space: String, tab: String? = nil, url: String? = nil, title: String? = nil, isPrivate: Bool) {
            self.space = space; self.tab = tab; self.url = url; self.title = title; self.isPrivate = isPrivate
        }
    }

    public struct Request: Codable, Equatable, Sendable {
        public let version: Int
        public let id: String
        public let account: String
        public let phone: String
        public let mac: String
        public let space: String
        public let tab: String?
        public let url: String?
        public let title: String?
        public let words: String
        public let created: Double
        /// Present only for an explicit read-only request. Old transport JSON
        /// decodes without it; nil encodes with the legacy exact field set.
        public let readOnlyEpoch: String?

        public init(id: String = UUID().uuidString.lowercased(), account: String, phone: String, mac: String,
                    space: String, tab: String? = nil, url: String? = nil, title: String? = nil,
                    words: String, created: Date = Date(), readOnlyEpoch: String? = nil) throws {
            version = TaskRecords.version
            self.id = id; self.account = account; self.phone = phone; self.mac = mac
            self.space = space; self.tab = tab; self.url = url; self.title = title
            self.words = words; self.created = created.timeIntervalSince1970; self.readOnlyEpoch = readOnlyEpoch
            try validate()
        }

        public func validate() throws {
            guard version == TaskRecords.version, TaskRecords.uuid(id),
                  [account, phone, mac, space].allSatisfy(TaskRecords.identity), phone != mac,
                  tab.map(TaskRecords.identity) ?? true, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  words.utf8.count <= TaskRecords.bodyLimit, created.isFinite, created > 0,
                  readOnlyEpoch.map(TaskRecords.uuid) ?? true,
                  url.map({ OpenOnMac.url($0) != nil }) ?? true,
                  title.map({ $0.utf8.count <= TaskRecords.bodyLimit }) ?? true,
                  tab != nil || (url == nil && title == nil) else { throw Failure.invalid }
        }

        public func fields() throws -> [String: Value] { ["body": .string(try TaskRecords.encode(self))] }

        public func digest() throws -> String {
            try validate()
            let data = Data(("yab task request v1\n" + (try TaskRecords.encode(self))).utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        public static func read(_ record: Record, account: String, phone: String) throws -> Request {
            let request: Request = try TaskRecords.read(record, collection: requestCollection, writer: phone)
            try request.validate()
            guard request.id == record.id, request.account == account, request.phone == phone else { throw Failure.owner }
            return request
        }

        public static func read(_ record: Record, account: String, phone: String, mac: String) throws -> Request {
            let request = try read(record, account: account, phone: phone)
            guard request.mac == mac else { throw Failure.owner }
            return request
        }
    }

    public enum Status: String, Codable, Sendable {
        case running, needsYou, waits, failed, done, stopped
    }

    /// An actual Mac observation of the retained request. No steps/results
    /// are synthesized from a fixture, words classifier, or local timer.
    public struct Observation: Codable, Equatable, Sendable {
        public let version: Int
        public let task: String
        public let requestDigest: String
        public let account: String
        public let phone: String
        public let mac: String
        public let revision: UInt64
        public let session: String?
        public let status: Status
        public let title: String
        public let progress: String
        public let result: String?
        public let resultURL: String?

        public init(request: Request, revision: UInt64, session: String? = nil, status: Status,
                    title: String, progress: String, result: String? = nil, resultURL: String? = nil) throws {
            version = TaskRecords.version; task = request.id; requestDigest = try request.digest()
            account = request.account; phone = request.phone; mac = request.mac
            self.revision = revision; self.session = session; self.status = status
            self.title = title; self.progress = progress; self.result = result; self.resultURL = resultURL
            try validate(request: request)
        }

        public func validate(request: Request) throws {
            guard version == TaskRecords.version, task == request.id,
                  account == request.account, phone == request.phone, mac == request.mac,
                  requestDigest == (try request.digest()), revision > 0,
                  session.map(TaskRecords.identity) ?? true,
                  title.utf8.count <= TaskRecords.bodyLimit, progress.utf8.count <= TaskRecords.bodyLimit,
                  result.map({ $0.utf8.count <= TaskRecords.bodyLimit }) ?? true,
                  resultURL.map({ OpenOnMac.url($0) != nil }) ?? true,
                  status != .done || (session != nil && result?.isEmpty == false),
                  status != .running || session != nil,
                  status == .done || (result == nil && resultURL == nil) else { throw Failure.invalid }
        }

        public func fields() throws -> [String: Value] { ["body": .string(try TaskRecords.encode(self))] }

        public static func read(_ record: Record, request: Request) throws -> Observation {
            let observation: Observation = try TaskRecords.read(record, collection: observationCollection, writer: request.mac)
            try observation.validate(request: request)
            guard record.id == request.id else { throw Failure.owner }
            return observation
        }
    }

    /// Publishes only the explicitly supplied observation. The caller must
    /// derive it from its real local engine; this helper launches nothing.
    /// Account and writer come from the locally active client, never the body.
    @discardableResult
    public static func publish(_ observation: Observation, requestRecord: Record, client: SyncClient,
                               knownPhones: [SyncClient.Listed]) throws -> Record {
        let mac = client.device.id, account = client.seal.account
        guard client.state == .live, client.journal.clock.device == mac,
              knownPhones.contains(where: { $0.id == observation.phone && !$0.revoked
                  && $0.isMobile }) else { throw Failure.owner }
        let request = try Request.read(requestRecord, account: account, phone: observation.phone, mac: mac)
        try observation.validate(request: request)
        let journal = client.journal
        let requestKey = Record.Key(collection: requestCollection, id: request.id)
        guard journal.record(requestKey) == requestRecord else { throw Failure.stale }
        let key = Record.Key(collection: observationCollection, id: request.id)
        if let had = journal.record(key) {
            let old = try Observation.read(had, request: request)
            guard observation.revision > old.revision else { throw Failure.stale }
        }
        let fields = try observation.fields()
        let saved = try journal.change(key, fields)
        guard saved.fields == fields, journal.record(key) == saved,
              (try Observation.read(saved, request: request)) == observation else { throw Failure.storage }
        client.kick()
        return saved
    }

    /// Stamp ownership is the existing cooperative sync provenance, not
    /// enrollment or a cryptographic permission to execute a browser action.
    private static func read<T: Decodable>(_ record: Record, collection: String, writer: String) throws -> T {
        guard record.collection == collection, record.schema == 1, record.alive(),
              Set(record.fields.keys) == Set(["body"]), record.stamps["body"]?.device == writer,
              let body = record["body"]?.string, body.utf8.count <= bodyLimit else { throw Failure.invalid }
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }

    fileprivate static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= bodyLimit else { throw Failure.invalid }
        return String(decoding: data, as: UTF8.self)
    }

    private static func identity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
}

/// Retains the latest observed Mac revision before any UI callback. A lower
/// revision or conflicting replay cannot become a new result after relaunch.
public final class TaskRecordInbox: @unchecked Sendable {
    private struct Saved: Codable { var account: String; var phone: String; var observations: [String: TaskRecords.Observation] }
    private static let diskLock = NSLock()
    private static let diskLimit = 8_388_608
    private let file: URL
    private let account: String
    private let phone: String

    public init(file: URL, account: String, phone: String) throws {
        self.file = file; self.account = account; self.phone = phone
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        _ = try read()
    }

    /// Only a live matching request/Mac can release its retained observation.
    public func current(request: TaskRecords.Request) throws -> TaskRecords.Observation? {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard request.account == account, request.phone == phone else { throw TaskRecords.Failure.owner }
        guard let had = (try read())[request.id] else { return nil }
        try had.validate(request: request)
        return had
    }

    @discardableResult
    public func accept(_ observation: TaskRecords.Observation, request: TaskRecords.Request) throws -> Bool {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        guard request.account == account, request.phone == phone else { throw TaskRecords.Failure.owner }
        try observation.validate(request: request)
        // Reload under the shared lock: a stopped engine's late callback cannot
        // overwrite a newer revision saved by its replacement in this process.
        var next = try read()
        if let old = next[request.id] {
            try old.validate(request: request)
            guard observation.revision >= old.revision else { throw TaskRecords.Failure.stale }
            if observation.revision == old.revision {
                guard observation == old else { throw TaskRecords.Failure.stale }
                return false
            }
        }
        next[request.id] = observation
        let data = try JSONEncoder().encode(Saved(account: account, phone: phone, observations: next))
        guard data.count <= Self.diskLimit else { throw TaskRecords.Failure.storage }
        try data.write(to: file, options: .atomic)
        guard try read() == next else { throw TaskRecords.Failure.storage }
        return true
    }

    private func read() throws -> [String: TaskRecords.Observation] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.diskLimit + 1) ?? Data()
        guard data.count <= Self.diskLimit else { throw TaskRecords.Failure.storage }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.account == account, saved.phone == phone else { throw TaskRecords.Failure.owner }
        return saved.observations
    }
}
