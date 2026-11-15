import Foundation
import SQLite3
import SyncKit
import Testing

struct TaskObservationTests {
    private struct Owned {
        let folder: URL
        let path: String
        let journal: Journal
        let request: TaskRecords.Request
        let mapping: TaskLaunch.Mapping

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("task-observation-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            path = folder.appendingPathComponent("journal.sqlite").path
            journal = try Journal(path: path, device: "mac")
            request = try TaskRecords.Request(account: "owned-account", phone: "phone", mac: "mac",
                                               space: "owned-space", words: "Read the owned page")
            let raw = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(),
                             stamps: ["body": Stamp(wall: 1, device: "phone")])
            _ = try journal.receive([(record: raw, version: 1)])
            guard case let .reserved(value) = try journal.reserveTaskCommand(raw, account: request.account,
                         device: request.mac, phone: request.phone, publicSpace: request.space, cli: "codex") else { throw TaskLaunch.Failure.context }
            mapping = value
        }

        func observation(_ revision: UInt64, status: TaskRecords.Status = .running,
                         progress: String = "Reading the real page", result: String? = nil) throws -> TaskRecords.Observation {
            try .init(request: request, revision: revision, session: mapping.session, status: status,
                      title: "Owned read task", progress: progress, result: result)
        }

        func save(_ value: TaskRecords.Observation, in other: Journal? = nil) throws -> Record {
            try (other ?? journal).checkpointTaskObservation(value, mapping: mapping, account: request.account, device: request.mac)
        }

        func read(_ other: Journal? = nil) throws -> TaskRecords.Observation? {
            try (other ?? journal).taskObservation(mapping: mapping, account: request.account, device: request.mac)
        }
    }

    private func sql(_ value: String, _ path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Journal.Failure.open("Owned test database unavailable") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw Journal.Failure.sql("Owned statement failed") }
    }

    @Test func aCommittedCheckpointAndOutboxReopenTogetherAndReplayDoesNotAdvanceTheClock() throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        let running = try owned.observation(1)
        let first = try owned.save(running)
        #expect(try TaskRecords.Observation.read(first, request: owned.request) == running)
        #expect(owned.journal.pending().contains { $0.record == first })
        let reopened = try Journal(path: owned.path, device: "mac")
        #expect(try owned.read(reopened) == running)
        let replay = try owned.save(running, in: reopened)
        #expect(replay == first && reopened.pending().filter { $0.record.key == first.key }.count == 1)
        let waiting = try owned.observation(2, status: .needsYou, progress: "A real page dialog was refused")
        _ = try owned.save(waiting, in: reopened)
        #expect(try owned.read() == waiting)
        #expect(try owned.journal.taskMapping(request: owned.request.id, account: owned.request.account, device: "mac") == owned.mapping)
    }

    @Test func aTerminalActualResultCannotBeReplacedByALateStreamOrAReopen() throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        _ = try owned.save(owned.observation(1))
        let done = try owned.observation(2, status: .done, progress: "Finished reading", result: "Actual owned result")
        let saved = try owned.save(done)
        let again = try Journal(path: owned.path, device: "mac")
        #expect(try owned.read(again) == done)
        let late = try owned.observation(3, progress: "Late partial stream")
        #expect(throws: TaskObservation.Failure.terminal) { try owned.save(late, in: again) }
        #expect(try owned.read() == done && owned.journal.record(saved.key) == saved)
        let retained = try #require(owned.journal.record(.init(collection: TaskRecords.requestCollection, id: owned.request.id)))
        #expect(try owned.journal.reserveTaskCommand(retained,
                         account: owned.request.account, device: "mac", phone: "phone", publicSpace: owned.request.space, cli: "claude") == .consumed)
    }

    @Test func aReplicatedObservationCannotBecomeALocalEngineCheckpointWithoutProvenance() throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        let claimed = try owned.observation(1, progress: "An arbitrary remote body")
        let remote = Record(collection: TaskRecords.observationCollection, id: owned.request.id, fields: try claimed.fields(),
                            stamps: ["body": Stamp(wall: 2, device: "mac")])
        _ = try owned.journal.receive([(record: remote, version: 2)])
        #expect(try owned.read() == nil)
        #expect(throws: TaskObservation.Failure.stale) { try owned.save(claimed) }
        #expect(owned.journal.record(remote.key) == remote)
    }

    @Test func aChangedRetainedRequestAndAWrongSessionNeverProduceAnOutboxCheckpoint() throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        let wrong = try TaskRecords.Observation(request: owned.request, revision: 1, session: UUID().uuidString,
                                               status: .running, title: "Wrong", progress: "Not the reserved session")
        #expect(throws: TaskObservation.Failure.context) { try owned.save(wrong) }
        let changed = try TaskRecords.Request(id: owned.request.id, account: owned.request.account, phone: "phone", mac: "mac",
                                              space: owned.request.space, words: "Different request")
        let raw = Record(collection: TaskRecords.requestCollection, id: owned.request.id, fields: try changed.fields(),
                         stamps: ["body": Stamp(wall: 2, device: "phone")])
        _ = try owned.journal.receive([(record: raw, version: 2)])
        #expect(throws: (any Error).self) { try owned.save(owned.observation(1)) }
        #expect(owned.journal.record(.init(collection: TaskRecords.observationCollection, id: owned.request.id)) == nil)
    }

    @Test func abortAndIgnoreOnEitherDurableWriteRollbackBothCheckpointAndOutbox() throws {
        for table in ["meta", "records"] {
            for action in ["ABORT", "IGNORE"] {
                let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
                let predicate = table == "meta" ? "NEW.key LIKE 'task-observation/v1/%'" : "NEW.collection = 'task'"
                let raise = action == "ABORT" ? "RAISE(ABORT, 'owned observation refusal')" : "RAISE(IGNORE)"
                try sql("CREATE TRIGGER refuse_observation BEFORE INSERT ON \(table) WHEN \(predicate) BEGIN SELECT \(raise); END", owned.path)
                let observation = try owned.observation(1)
                #expect(throws: (any Error).self) { try owned.save(observation) }
                #expect(try owned.read() == nil)
                #expect(owned.journal.record(.init(collection: TaskRecords.observationCollection, id: owned.request.id)) == nil)
                try sql("DROP TRIGGER refuse_observation", owned.path)
                #expect(try TaskRecords.Observation.read(owned.save(observation), request: owned.request) == observation)
            }
        }
    }

    @Test func twoDatabaseConnectionsCannotCommitTwoDifferentFirstRevisions() async throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        let other = try Journal(path: owned.path, device: "mac")
        let observations = [try owned.observation(1, progress: "First actual state"), try owned.observation(1, progress: "Other actual state")]
        let journals = [owned.journal, other]
        let saved = await withTaskGroup(of: TaskRecords.Observation?.self) { group in
            for (journal, observation) in zip(journals, observations) {
                group.addTask {
                    do {
                        _ = try journal.checkpointTaskObservation(observation, mapping: owned.mapping,
                                                                 account: owned.request.account, device: "mac")
                        return observation
                    } catch { return nil }
                }
            }
            var results: [TaskRecords.Observation] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        #expect(saved.count == 1)
        #expect(try owned.read() == saved.first && owned.read(other) == saved.first)
    }

    @Test func wrongAccountDeviceMemoryJournalAndCorruptLocalReceiptRefuse() throws {
        let owned = try Owned(); defer { try? FileManager.default.removeItem(at: owned.folder) }
        let first = try owned.observation(1)
        #expect(throws: (any Error).self) { try owned.journal.checkpointTaskObservation(first, mapping: owned.mapping, account: "different", device: "mac") }
        #expect(throws: (any Error).self) { try owned.journal.checkpointTaskObservation(first, mapping: owned.mapping, account: owned.request.account, device: "different") }
        let memory = try Journal(path: nil, device: "mac")
        #expect(throws: (any Error).self) { try owned.save(first, in: memory) }
        let saved = try owned.save(first)
        try sql("UPDATE meta SET value = '{}' WHERE key LIKE 'task-observation/v1/%'", owned.path)
        #expect(throws: (any Error).self) { try owned.read() }
        #expect(throws: (any Error).self) { try owned.save(owned.observation(2)) }
        #expect(owned.journal.record(saved.key) == saved)
    }
}
