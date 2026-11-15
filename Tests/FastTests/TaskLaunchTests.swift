import Foundation
import SQLite3
import SyncKit
import Testing

struct TaskLaunchTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-launch-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func request(_ journal: Journal, id: String = UUID().uuidString.lowercased(), account: String = "owned-account",
                         phone: String = "phone", mac: String = "mac", words: String = "Read the owned public page") throws -> Record {
        let request = try TaskRecords.Request(id: id, account: account, phone: phone, mac: mac, space: "owned-space", words: words)
        let record = Record(collection: TaskRecords.requestCollection, id: id, fields: try request.fields(),
                            stamps: ["body": Stamp(wall: 1, device: phone)])
        _ = try journal.receive([(record: record, version: 1)])
        return record
    }

    private func reserve(_ original: Record, _ journal: Journal, account: String = "owned-account", device: String = "mac",
                         phone: String = "phone", space: String = "owned-space", cli: String = "codex") throws -> TaskLaunch.Reservation {
        try journal.reserveTaskCommand(original, account: account, device: device, phone: phone, publicSpace: space, cli: cli)
    }

    private func sql(_ statement: String, path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Journal.Failure.open("Owned test database unavailable") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw Journal.Failure.sql("Owned SQL failed") }
    }

    @Test func aCommittedMappingReservesOneFullUUIDAndNeverCopiesTheRequestWords() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let original = try request(journal, words: "Unique owned secret stays in the original encrypted request only")
        guard case let .reserved(mapping) = try reserve(original, journal) else { Issue.record("Expected reservation"); return }
        #expect(UUID(uuidString: mapping.session) != nil && mapping.session.count == 36)
        #expect(mapping.request == original.id && mapping.cli == "codex" && mapping.attempted)
        #expect(mapping.policy == "read-only/v1")
        let retained = try journal.taskMapping(request: original.id, account: "owned-account", device: "mac")
        #expect(retained == mapping && journal.record(original.key) == original)
        let body = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        #expect(!body.contains("Unique owned secret"))
        let replay = try reserve(original, journal, cli: "claude")
        #expect(replay == .consumed)
        #expect(try journal.taskMapping(request: original.id, account: "owned-account", device: "mac") == mapping)
    }

    @Test func cleanReopenKeepsTheConsumedSessionWithoutReissuingAClaim() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        var first: Journal? = try Journal(path: path, device: "mac")
        let original = try request(try #require(first))
        guard case let .reserved(mapping) = try reserve(original, try #require(first)) else { Issue.record("Expected reservation"); return }
        first = nil
        let reopened = try Journal(path: path, device: "mac")
        #expect(try reopened.taskMapping(request: original.id, account: "owned-account", device: "mac") == mapping)
        #expect(try reserve(original, reopened) == .consumed)
    }

    @Test func twoConnectionsCanReserveOnlyOneSessionBeforeAnyLaterAdapter() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        let a = try Journal(path: path, device: "mac"), b = try Journal(path: path, device: "mac")
        let original = try request(a)
        let reserved = await withTaskGroup(of: TaskLaunch.Mapping?.self) { group in
            for journal in [a, b] {
                group.addTask {
                    do {
                        if case let .reserved(mapping) = try journal.reserveTaskCommand(original, account: "owned-account", device: "mac",
                                                                                         phone: "phone", publicSpace: "owned-space", cli: "codex") { return mapping }
                    } catch { Issue.record("Owned concurrent claim failed: \(error)") }
                    return nil
                }
            }
            var out: [TaskLaunch.Mapping] = []
            for await mapping in group { if let mapping { out.append(mapping) } }
            return out
        }
        #expect(reserved.count == 1)
        #expect(try a.taskMapping(request: original.id, account: "owned-account", device: "mac") == reserved.first)
    }

    @Test func staleBodyBeforeOrAfterReservationCannotRebindTheSession() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let original = try request(journal)
        let newer = try request(journal, id: original.id, words: "Changed task")
        // Its original writer supplies a genuinely newer stamp.
        var updated = newer; updated.stamps["body"] = Stamp(wall: 2, device: "phone")
        _ = try journal.receive([(record: updated, version: 2)])
        #expect(throws: (any Error).self) { try reserve(original, journal) }
        #expect(try journal.taskMapping(request: original.id, account: "owned-account", device: "mac") == nil)
        guard case let .reserved(mapping) = try reserve(updated, journal) else { Issue.record("Expected current reservation"); return }
        let changed = try request(journal, id: original.id, words: "Third task")
        var third = changed; third.stamps["body"] = Stamp(wall: 3, device: "phone")
        _ = try journal.receive([(record: third, version: 3)])
        #expect(try reserve(third, journal) == .consumed)
        #expect(throws: (any Error).self) { try journal.taskMapping(request: mapping.request, account: "owned-account", device: "mac") }
    }

    @Test func foreignWriterAccountMacSpaceCLIAndMemoryDatabaseHaveNoReservation() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let original = try request(journal)
        for (account, device, phone, space, cli) in [("other", "mac", "phone", "owned-space", "codex"),
                                                   ("owned-account", "other", "phone", "owned-space", "codex"),
                                                   ("owned-account", "mac", "other", "owned-space", "codex"),
                                                   ("owned-account", "mac", "phone", "private-or-other-space", "codex"),
                                                   ("owned-account", "mac", "phone", "owned-space", "unknown")] {
            #expect(throws: (any Error).self) { try reserve(original, journal, account: account, device: device, phone: phone, space: space, cli: cli) }
        }
        let memory = try Journal(path: nil, device: "mac"), volatile = try request(memory)
        #expect(throws: (any Error).self) { try reserve(volatile, memory) }
        var forged = original; forged.stamps["body"] = Stamp(wall: 10, device: "other")
        #expect(throws: (any Error).self) { try reserve(forged, journal) }
        #expect(try journal.taskMapping(request: original.id, account: "owned-account", device: "mac") == nil)
    }

    @Test func aPreviouslyBoundAccountOrDeviceCannotReuseTheLedger() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        let journal = try Journal(path: path, device: "mac"), original = try request(journal)
        _ = try reserve(original, journal)
        let foreign = try request(journal, account: "other-account")
        #expect(throws: (any Error).self) { try reserve(foreign, journal, account: "other-account") }
        let other = try Journal(path: path, device: "other-mac"), moved = try request(other, mac: "other-mac")
        #expect(throws: (any Error).self) { try reserve(moved, other, device: "other-mac") }
    }

    @Test func ignoredOrAbortedReceiptAndScopeWritesFailClosedWithoutChangingOtherNamespaces() throws {
        for operation in ["ABORT", "IGNORE"] {
            for target in ["receipt", "scope"] {
                let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
                let path = folder.appendingPathComponent("journal.sqlite").path
                let journal = try Journal(path: path, device: "mac"), original = try request(journal)
                let cap = try journal.change(.init(collection: OpenOnMac.capability, id: "mac"), ["device": "mac", "open": 1])
                let key = target == "receipt" ? "NEW.key LIKE 'task-launch/v1/%'" : "NEW.key = 'chat-command-scope/v1'"
                let raise = operation == "ABORT" ? "RAISE(ABORT, 'owned refusal')" : "RAISE(IGNORE)"
                try sql("CREATE TRIGGER refuse_task BEFORE INSERT ON meta WHEN \(key) BEGIN SELECT \(raise); END", path: path)
                #expect(throws: (any Error).self) { try reserve(original, journal) }
                #expect(try journal.taskMapping(request: original.id, account: "owned-account", device: "mac") == nil)
                #expect(journal.record(original.key) == original && journal.record(cap.key) == cap)
                try sql("DROP TRIGGER refuse_task", path: path)
                let recovered = try reserve(original, journal)
                guard case .reserved = recovered else { Issue.record("Expected reservation after owned rollback"); return }
            }
        }
    }
}
