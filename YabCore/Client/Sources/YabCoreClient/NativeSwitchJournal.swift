import Foundation
import Darwin
import CryptoKit

/// Metadata-only write-ahead storage. Unused by production. A durable local
/// intent/cursor is NOT native approval, ownership, rollback or crash recovery.
public actor NativeSwitchJournal {
    public enum Privacy: String, Codable, Sendable { case persistentVerified, `private`, unknown }
    public enum Target: String, Codable, Sendable { case webKit, chromium }
    public struct Member: Codable, Equatable, Sendable {
        public let tab, profile, document: String
        public let browser: Int32
        public init(tab: String, profile: String, document: String, browser: Int32) {
            self.tab = tab; self.profile = profile; self.document = document; self.browser = browser
        }
    }
    public struct Intent: Codable, Equatable, Sendable {
        public let id: UUID
        public let peer: NativePeerIdentity.Evidence
        public let connection: String
        public let members: [Member]
        public let target: Target
        public let settingsBaselineSHA256: String
        public let privacy: Privacy
        public init(id: UUID, peer: NativePeerIdentity.Evidence, connection: String, members: [Member], target: Target,
                    settingsBaselineSHA256: String, privacy: Privacy) {
            self.id = id; self.peer = peer; self.connection = connection; self.members = members; self.target = target
            self.settingsBaselineSHA256 = settingsBaselineSHA256; self.privacy = privacy
        }
    }
    // sourcesObserved is metadata at an authenticated native callback only.
    // It is never approval/seal/commit, a continuous lease or crash recovery.
    public enum Phase: String, Codable, Sendable { case intent, reserveDispatchPending, sourcesDispatchPending, sourcesObserved, cancelDispatchPending, unknown }
    public enum Action: String, Codable, Sendable { case reserve, sources, cancel }
    public struct SourcesObservation: Codable, Equatable, Sendable {
        public let envelopeSHA256, requestFrameSHA256, groupSHA256, sourceReceiptSHA256, frameTreeSHA256: String
        public let requestFrameBytes: Int
        public let treeSequence, phaseSequence, operationSequence: String
        public let processes: [SourcesProcess]
        // Diagnostic durable process metadata cannot reconstruct a Mach right.
        public struct SourcesProcess: Codable, Equatable, Sendable {
            public let launchIncarnation: String
            public let osPID: Int32
            public let pidVersion: UInt32
            public let birthSec: String
            public let birthUsec: UInt32
            public let boot, executable, argvDigest, codeUnique, signingID, auditDigest: String
        }
    }
    public enum Loss: String, Codable, Sendable { case helperEOF, helperParentDeath, sourceProcessLost, unreadableIdentity, nativeOutcomeUnknown }
    public struct Pending: Codable, Equatable, Sendable {
        public let action: Action; public let command: String
        public let frameSHA256: String?; public let frameBytes: Int?
        init(action: Action, command: String, frameSHA256: String? = nil, frameBytes: Int? = nil) {
            self.action = action; self.command = command; self.frameSHA256 = frameSHA256; self.frameBytes = frameBytes
        }
    }
    private struct Record: Codable, Equatable {
        var version: Int = 1
        var revision: UInt64
        var previous: String?
        let intent: Intent
        var phase: Phase
        var pending: [Pending]
        var loss: Loss?
        var sources: SourcesObservation? = nil
    }
    private struct Envelope: Codable { let version: Int; let body: Data; let sha256: String }
    public struct Cursor: Equatable, Sendable {
        public let id: UUID, revision: UInt64, digest: String
        private init(id: UUID, revision: UInt64, digest: String) { self.id = id; self.revision = revision; self.digest = digest }
        fileprivate static func make(id: UUID, revision: UInt64, digest: String) -> Cursor { .init(id: id, revision: revision, digest: digest) }
    }
    public struct Snapshot: Equatable, Sendable {
        public let cursor: Cursor, intent: Intent, phase: Phase, pending: [Pending], loss: Loss?
        public let sources: SourcesObservation?
    }
    public enum Result: Equatable, Sendable {
        case stored(Snapshot), empty, conflict, busy, capacity, invalid, unknown
    }
    public static let maximumRecordBytes = 384 * 1024
    public static let maximumBodyBytes = 256 * 1024
    public static let slots = 64
    private let directory: Int32, lockFD: Int32
    private var poisoned = false
    private enum IOFailure: Error { case unknown }

    /// Use a dedicated new0700 subdirectory within an already trusted owner
    /// location. No profile/default path, automatic recovery, or cleanup scan.
    public init(directory url: URL) throws {
        let name = url.lastPathComponent
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.standardizedFileURL.path == url.path, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw IOFailure.unknown }
        let parent = url.deletingLastPathComponent().path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard parent >= 0 else { throw IOFailure.unknown }
        var owner = stat()
        guard fstat(parent, &owner) == 0, (owner.st_mode & S_IFMT) == S_IFDIR, owner.st_uid == getuid(), (owner.st_mode & 0o022) == 0 else {
            _ = Darwin.close(parent); throw IOFailure.unknown
        }
        let made = name.withCString { mkdirat(parent, $0, 0o700) }
        guard made == 0 || errno == EEXIST else { _ = Darwin.close(parent); throw IOFailure.unknown }
        let fd = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        var info = stat(), named = stat()
        let valid = fd >= 0 && fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() &&
            (info.st_mode & 0o777) == 0o700 && name.withCString({ fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0 &&
            named.st_dev == info.st_dev && named.st_ino == info.st_ino
        let persisted = made != 0 || fsync(parent) == 0
        let parentClosed = Darwin.close(parent) == 0
        guard valid && persisted && parentClosed else { if fd >= 0 { _ = Darwin.close(fd) }; throw IOFailure.unknown }
        let owned = openat(fd, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard owned >= 0 else { _ = Darwin.close(fd); throw IOFailure.unknown }
        var file = stat()
        guard fstat(owned, &file) == 0, Self.privateFile(file), Self.sameNamed(fd, ".lock", file) else {
            _ = Darwin.close(owned); _ = Darwin.close(fd); throw IOFailure.unknown
        }
        directory = fd; lockFD = owned
    }
    deinit { _ = Darwin.close(lockFD); _ = Darwin.close(directory) }

    public func load(_ id: UUID) -> Result {
        locked { try self.read(id).map { .stored(Self.snapshot($0.0, digest: $0.1)) } ?? .empty }
    }
    /// Diagnostic evidence may be persisted, but never becomes native
    /// authority. Only successful fsync+rename+dirfsync returns stored.
    public func create(_ intent: Intent) -> Result {
        guard Self.valid(intent) else { return .invalid }
        return locked {
            if let current = try self.readSlot(Self.slot(intent.id)) { return current.0.intent.id == intent.id ? .conflict : .capacity }
            return try self.persist(Record(revision: 1, previous: nil, intent: intent, phase: .intent, pending: [], loss: nil))
        }
    }
    /// Must return stored before the caller may consider native dispatch. It
    /// does NOT perform dispatch or authorize any native effect. Only the
    /// private original receive lane can add a native sources observation.
    public func writeAhead(_ action: Action, command: String, expected: Cursor, frameSHA256: String? = nil, frameBytes: Int? = nil) -> Result {
        guard Self.token(command, 128), Self.validFrame(frameSHA256, frameBytes) else { return .invalid }
        return locked {
            guard var record = try self.exact(expected) else { return .conflict }
            guard record.phase != .unknown, record.loss == nil, record.revision < 8,
                  !record.pending.contains(where: { $0.command == command }), record.pending.count < 32 else { return .invalid }
            switch (record.phase, action) {
            case (.intent, .reserve):
                record.phase = .reserveDispatchPending
                if frameSHA256 != nil { record.version = 2 }
            case (.reserveDispatchPending, .sources): record.version = 2; record.phase = .sourcesDispatchPending
            case (.reserveDispatchPending, .cancel), (.sourcesDispatchPending, .cancel), (.sourcesObserved, .cancel): record.phase = .cancelDispatchPending
            default: return .invalid
            }
            record.pending.append(Pending(action: action, command: command, frameSHA256: frameSHA256, frameBytes: frameBytes))
            record.previous = expected.digest; record.revision += 1
            return try self.persist(record)
        }
    }
    /// Only an actual original-client receive-lane token can call this path.
    /// Decoded JSON, loaded SourcesObservation or a diagnostic helper pin cannot
    /// construct that token. Latest loss is terminal under this same lock.
    func observedOriginalSources(_ receipt: NativeOriginalSourcesReceipt, expected: Cursor) -> Result {
        guard receipt.cursor == expected else { return .invalid }
        return locked {
            guard var record = try self.exact(expected), record.intent == receipt.intent else { return .conflict }
            guard record.version == 2, record.phase == .sourcesDispatchPending, record.loss == nil, record.sources == nil,
                  record.pending.last == Pending(action: .sources, command: receipt.command, frameSHA256: receipt.observation.requestFrameSHA256, frameBytes: receipt.observation.requestFrameBytes), record.revision < 8 else { return .invalid }
            record.sources = receipt.observation
            record.phase = .sourcesObserved; record.previous = expected.digest; record.revision += 1
            return try self.persist(record)
        }
    }
    /// Explicit helper/client loss path. Original pending commands and exact
    /// source/settings metadata remain. No cancel/resume/retire/native reply.
    public func sourceLost(_ loss: Loss, expected: Cursor) -> Result {
        locked {
            guard var record = try self.exact(expected) else { return .unknown }
            guard record.revision < 8 else { return .unknown }
            if record.phase == .unknown { return .stored(Self.snapshot(record, digest: expected.digest)) }
            record.phase = .unknown; record.loss = loss; record.previous = expected.digest; record.revision += 1
            return try self.persist(record)
        }
    }
    /// Loss is monotonic metadata ONLY. Read latest + immutable Intent match +
    /// persist run under the SAME file lock, so an in-flight source-phase CAS
    /// cannot leave a later positive revision after the source was poisoned.
    /// No new owner/recovery/request or payload is created from this metadata.
    func sourceLostLatest(_ loss: Loss, original: Intent) -> Result {
        locked {
            guard let latest = try self.read(original.id), latest.0.intent == original else { return .unknown }
            var record = latest.0
            if record.phase == .unknown { return .stored(Self.snapshot(record, digest: latest.1)) }
            guard record.revision < 8 else { return .unknown }
            record.phase = .unknown; record.loss = loss
            record.previous = latest.1; record.revision += 1
            return try self.persist(record)
        }
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func digest(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func token(_ text: String, _ maximum: Int = 256) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func valid(_ intent: Intent) -> Bool {
        guard intent.privacy == .persistentVerified, token(intent.connection, 128), digest(intent.settingsBaselineSHA256),
              intent.peer.pid > 0, intent.peer.startSec > 0, intent.peer.startUsec < 1_000_000, intent.peer.uid == getuid(),
              digest(intent.peer.argvSHA256), digest(intent.peer.auditSHA256), intent.peer.parent > 0,
              intent.peer.executable.hasPrefix("/"), token(intent.peer.executable, 4096), token(intent.peer.codeIdentifier),
              let boot = UUID(uuidString: intent.peer.bootSession), boot.uuidString == intent.peer.bootSession,
              intent.peer.codeUnique.utf8.count >= 32, intent.peer.codeUnique.utf8.count <= 128,
              intent.peer.codeUnique.utf8.count % 2 == 0,
              intent.peer.codeUnique.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !intent.members.isEmpty, intent.members.count <= 256 else { return false }
        var tabs = Set<String>(), browsers = Set<Int32>()
        for member in intent.members {
            guard token(member.tab), token(member.profile), token(member.document), member.browser > 0,
                  tabs.insert(member.tab).inserted, browsers.insert(member.browser).inserted else { return false }
        }
        return true
    }
    private static func validSources(_ sources: SourcesObservation) -> Bool {
        guard [sources.envelopeSHA256, sources.requestFrameSHA256, sources.groupSHA256, sources.sourceReceiptSHA256, sources.frameTreeSHA256].allSatisfy(digest),
              validFrame(sources.requestFrameSHA256, sources.requestFrameBytes),
              [sources.treeSequence, sources.phaseSequence, sources.operationSequence].allSatisfy({ NativeOriginalSourceMetadata.sequence(.string($0)) != nil }),
              !sources.processes.isEmpty, sources.processes.count <= 256,
              Set(sources.processes.map(\.launchIncarnation)).count == sources.processes.count else { return false }
        return sources.processes.allSatisfy { source in
            source.osPID > 0 && source.birthUsec < 1_000_000 && NativeOriginalSourceMetadata.sequence(.string(source.birthSec)) != nil &&
            UUID(uuidString: source.boot) != nil && token(source.launchIncarnation) && source.executable.hasPrefix("/") && token(source.executable, 4096) &&
            nativeDigest(source.argvDigest) && nativeDigest(source.auditDigest) && token(source.signingID) &&
            source.codeUnique.utf8.count >= 32 && source.codeUnique.utf8.count <= 128 && source.codeUnique.utf8.count % 2 == 0 &&
            source.codeUnique.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) })
        }
    }
    private static func nativeDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
    private static func validFrame(_ sha: String?, _ bytes: Int?) -> Bool {
        if sha == nil && bytes == nil { return true }
        guard let sha, let bytes else { return false }
        return digest(sha) && bytes > 1 && bytes <= Socket.limit + 1
    }
    private static func slot(_ id: UUID) -> String {
        // Fixed bounded slots fail closed on collision, never evict old work.
        let bytes = SHA256.hash(data: Data(id.uuidString.utf8)); var value: UInt64 = 0
        for byte in bytes.prefix(8) { value = (value << 8) | UInt64(byte) }
        return "slot-\(value % UInt64(slots))"
    }
    private static func snapshot(_ record: Record, digest: String) -> Snapshot {
        .init(cursor: .make(id: record.intent.id, revision: record.revision, digest: digest), intent: record.intent,
              phase: record.phase, pending: record.pending, loss: record.loss, sources: record.sources)
    }
    private static func privateFile(_ file: stat) -> Bool {
        (file.st_mode & S_IFMT) == S_IFREG && file.st_uid == getuid() && (file.st_mode & 0o777) == 0o600 && file.st_nlink == 1
    }
    private static func sameNamed(_ directory: Int32, _ name: String, _ opened: stat) -> Bool {
        var named = stat()
        return name.withCString { fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) } == 0 &&
            named.st_dev == opened.st_dev && named.st_ino == opened.st_ino && privateFile(named)
    }
    private func locked(_ work: () throws -> Result) -> Result {
        guard !poisoned else { return .unknown }
        var info = stat()
        guard fstat(lockFD, &info) == 0, Self.privateFile(info), Self.sameNamed(directory, ".lock", info) else { poisoned = true; return .unknown }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return .busy }; poisoned = true; return .unknown
        }
        var result: Result
        do {
            // A crash/indeterminate prior writer leaves one bounded staging
            // resource. Never unlink/adopt/replay it after a new process.
            var pending = stat()
            if fstatat(directory, ".pending", &pending, AT_SYMLINK_NOFOLLOW) == 0 { throw IOFailure.unknown }
            guard errno == ENOENT else { throw IOFailure.unknown }
            result = try work()
        } catch { poisoned = true; result = .unknown }
        if flock(lockFD, LOCK_UN) != 0 { poisoned = true; return .unknown }
        return result
    }
    private func exact(_ cursor: Cursor) throws -> Record? {
        guard let current = try read(cursor.id), current.0.revision == cursor.revision, current.1 == cursor.digest else { return nil }
        return current.0
    }
    private func read(_ id: UUID) throws -> (Record, String)? {
        guard let row = try readSlot(Self.slot(id)) else { return nil }
        guard row.0.intent.id == id else { return nil }
        return row
    }
    private func readSlot(_ name: String) throws -> (Record, String)? {
        var latest: (Record, String)?, gap = false
        // Eight bounded immutable revisions cover both v1 and v2 metadata.
        // No original evidence is overwritten/evicted or restored as authority.
        for revision in 1...8 {
            guard let row = try readRevision(name + "-r\(revision).json") else { gap = true; continue }
            guard !gap, row.0.revision == UInt64(revision), Self.slot(row.0.intent.id) == name else { throw IOFailure.unknown }
            if let prior = latest {
                guard row.0.intent == prior.0.intent, row.0.previous == prior.1, Self.transition(prior.0, row.0) else { throw IOFailure.unknown }
            } else {
                guard revision == 1, row.0.phase == .intent, row.0.pending.isEmpty, row.0.previous == nil else { throw IOFailure.unknown }
            }
            latest = row
        }
        return latest
    }
    private static func transition(_ before: Record, _ after: Record) -> Bool {
        guard before.phase != .unknown, after.revision == before.revision + 1 else { return false }
        if after.phase == .unknown { return after.pending == before.pending && after.sources == before.sources && after.version == before.version && after.loss != nil }
        if before.phase == .sourcesDispatchPending, after.phase == .sourcesObserved {
            return before.version == 2 && after.version == 2 && before.sources == nil && after.sources != nil &&
                after.pending == before.pending && after.loss == nil
        }
        guard after.sources == before.sources, after.loss == nil, after.pending.count == before.pending.count + 1,
              Array(after.pending.dropLast()) == before.pending else { return false }
        switch (before.phase, after.phase, after.pending.last?.action) {
        case (.intent, .reserveDispatchPending, .reserve):
            return before.version == 1 && (after.version == 1 || (after.version == 2 && after.pending.last?.frameSHA256 != nil))
        case (.reserveDispatchPending, .sourcesDispatchPending, .sources): return (before.version == 1 || before.version == 2) && after.version == 2
        case (.reserveDispatchPending, .cancelDispatchPending, .cancel), (.sourcesDispatchPending, .cancelDispatchPending, .cancel),
             (.sourcesObserved, .cancelDispatchPending, .cancel): return after.version == before.version
        default: return false
        }
    }
    private func readRevision(_ name: String) throws -> (Record, String)? {
        let fd = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 { if errno == ENOENT { return nil }; throw IOFailure.unknown }
        var info = stat(); var bytes = Data(); var failed = false
        if fstat(fd, &info) != 0 || !Self.privateFile(info) || !Self.sameNamed(directory, name, info) ||
            info.st_size <= 0 || info.st_size > Self.maximumRecordBytes { failed = true }
        if !failed {
            bytes = Data(count: Int(info.st_size))
            var done = 0
            while done < bytes.count {
                let size = bytes.count - done
                let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: done), size, off_t(done)) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { failed = true; break }
                done += count
            }
            var after = stat()
            if fstat(fd, &after) != 0 || after.st_size != info.st_size || after.st_ino != info.st_ino ||
                after.st_dev != info.st_dev || !Self.sameNamed(directory, name, info) { failed = true }
        }
        if Darwin.close(fd) != 0 { failed = true }
        guard !failed else { throw IOFailure.unknown }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1, envelope.body.count <= Self.maximumBodyBytes, Self.digest(envelope.sha256),
              Self.hash(envelope.body) == envelope.sha256 else { throw IOFailure.unknown }
        let row = try JSONDecoder().decode(Record.self, from: envelope.body)
        guard (row.version == 1 || row.version == 2), row.revision > 0, row.revision <= 8, Self.valid(row.intent), row.pending.count <= 32,
              (row.version == 2 || (row.sources == nil && row.phase != .sourcesDispatchPending && row.phase != .sourcesObserved && !row.pending.contains(where: { $0.action == .sources }))),
              (row.phase != .sourcesObserved || row.sources != nil),
              (row.sources == nil || (Self.validSources(row.sources!) && row.sources!.processes.allSatisfy({ UUID(uuidString: $0.boot) == UUID(uuidString: row.intent.peer.bootSession) }))),
              (row.sources == nil || row.pending.contains(where: { $0.action == .sources && $0.frameSHA256 == row.sources!.requestFrameSHA256 && $0.frameBytes == row.sources!.requestFrameBytes })),
              (row.revision == 1 ? row.previous == nil : row.previous.map(Self.digest) == true),
              (row.phase == .unknown ? row.loss != nil : row.loss == nil),
              Set(row.pending.map(\.command)).count == row.pending.count,
              row.pending.allSatisfy({ Self.token($0.command, 128) && Self.validFrame($0.frameSHA256, $0.frameBytes) && (row.version == 2 || $0.frameSHA256 == nil) }) else { throw IOFailure.unknown }
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        guard try canonical.encode(row) == envelope.body, try canonical.encode(envelope) == bytes else { throw IOFailure.unknown }
        return (row, envelope.sha256)
    }
    private func persist(_ record: Record) throws -> Result {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(record)
        guard body.count <= Self.maximumBodyBytes else { return .invalid }
        let digest = Self.hash(body), bytes = try encoder.encode(Envelope(version: 1, body: body, sha256: digest))
        guard bytes.count <= Self.maximumRecordBytes else { return .invalid }
        let fd = openat(directory, ".pending", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IOFailure.unknown }
        var info = stat(), failed = false
        if fstat(fd, &info) != 0 || !Self.privateFile(info) || !Self.sameNamed(directory, ".pending", info) { failed = true }
        var done = 0
        while !failed && done < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: done), bytes.count - done) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { failed = true; break }; done += count
        }
        if !failed && (fsync(fd) != 0 || !Self.sameNamed(directory, ".pending", info)) { failed = true }
        if Darwin.close(fd) != 0 { failed = true }
        guard !failed else { throw IOFailure.unknown } // Keep exact staging evidence.
        let name = Self.slot(record.intent.id) + "-r\(record.revision).json"
        guard name.withCString({ renameatx_np(directory, ".pending", directory, $0, UInt32(RENAME_EXCL)) }) == 0,
              fsync(directory) == 0 else { throw IOFailure.unknown }
        return .stored(Self.snapshot(record, digest: digest))
    }
}
