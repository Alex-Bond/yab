import Foundation
import SQLite3
import SyncKit
import Testing
@testable import Fast

struct SyncChatCommandTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-chat-command-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sql(_ query: String, path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Journal.Failure.open("Owned test database unavailable") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw Journal.Failure.sql("Owned test SQL failed") }
    }

    private func request(_ journal: Journal, id: String = "question", fields: [String: Value] = [:]) throws -> Record {
        let base: [String: Value] = ["device": "mac", "clientDevice": "phone", "clientChat": "local",
                                    "question": "Owned human question", "text": "Owned prompt",
                                    "at": .number(now.timeIntervalSince1970)]
        return try journal.change(.init(collection: "send", id: id), base.merging(fields) { _, b in b })
    }

    @Test func checkedReceiptPrecedesDispatchAndAssociationIsPreserved() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal)
        let capability = try journal.change(.init(collection: OpenOnMac.capability, id: "mac"),
                                            ["device": "mac", "open": .number(1), "chatMetadata": .number(1), "chatAgent": .number(1)])
        var calls = 0
        let consumed = try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { original in
            #expect(journal.record(record.key)?["state"]?.string == "processing")
            #expect(original.visible == record.visible)
            calls += 1
            return .taken(chat: "a:accepted")
        }
        #expect(consumed)
        let taken = try #require(journal.record(record.key))
        #expect(taken["state"]?.string == "taken" && taken["chat"]?.string == "a:accepted")
        #expect(taken["clientChat"] == record["clientChat"] && taken["clientDevice"] == record["clientDevice"])
        #expect(taken["question"] == record["question"] && taken["text"] == record["text"])
        #expect(journal.record(capability.key) == capability)
        #expect(try ChatCommand.consume(taken, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() } == false)
        #expect(calls == 1)
    }

    @Test func explicitAgentEnvelopeUsesTheSameCommittedAttemptContract() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal, fields: ["kind": "agent", "text": .null, "agentText": "Owned selected prompt", "cli": "codex"])
        var calls = 0
        try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { original in
            #expect(original["text"] == nil && original["agentText"]?.string == "Owned selected prompt")
            #expect(original["cli"]?.string == "codex")
            calls += 1; return .taken(chat: "a:codex")
        }
        #expect(calls == 1 && journal.record(record.key)?["state"]?.string == "taken")
    }

    @Test func malformedExpiredUnknownAndForeignRequestsHaveNoDispatch() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let cases: [[String: Value]] = [
            ["kind": "task"], ["kind": .bool(true)], ["at": .null],
            ["at": .number(now.timeIntervalSince1970 + 3600)],
            ["at": .number(now.timeIntervalSince1970 - ChatCommand.lifetime - 1)],
            ["choice": .number(1e100)], ["choice": .number(0), "chat": "a:wrong"],
            ["kind": "agent", "cli": "codex"], ["text": .bool(true)],
            ["kind": "agent", "cli": "codex", "agentText": "Mixed prompt"],
            ["project": .bool(true)], ["device": "other-mac"]
        ]
        var calls = 0
        for (i, fields) in cases.enumerated() {
            let record = try request(journal, id: "invalid-\(i)", fields: fields)
            try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
            if fields["device"] != nil { #expect(journal.record(record.key)?["state"] == nil) }
            else { #expect(journal.record(record.key)?["state"]?.string == (i == 4 ? "expired" : "failed")) }
        }
        #expect(calls == 0)
        let open = try journal.change(.init(collection: "send", id: "open"),
                                      OpenOnMac.fields(device: "mac", sender: "phone", url: URL(string: "https://example.test")!, at: now))
        #expect(try ChatCommand.consume(open, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() } == false)
        #expect(calls == 0 && journal.record(open.key)?["state"] == nil)
    }

    @Test func memoryJournalCannotAuthorizeAnEffect() throws {
        let journal = try Journal(path: nil, device: "mac"), record = try request(journal)
        var calls = 0
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        }
        #expect(calls == 0 && journal.record(record.key)?["state"] == nil)
    }

    @Test func claimedAttemptSurvivesReopenAndIsInterruptedWithoutDispatch() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        var first: Journal? = try Journal(path: path, device: "mac")
        let record = try request(try #require(first))
        do {
            let journal = try #require(first)
            guard case .claimed = try journal.claimChatCommand(record, account: "owned-account", device: "mac") else {
                Issue.record("Expected a committed attempt"); return
            }
        }
        first = nil
        let reopened = try Journal(path: path, device: "mac")
        let processing = try #require(reopened.record(record.key))
        var calls = 0
        try ChatCommand.consume(processing, in: reopened, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        #expect(calls == 0 && reopened.record(record.key)?["state"]?.string == "failed")
        #expect(reopened.record(record.key)?["reason"]?.string == ChatCommand.interrupted)
    }

    @Test func replayCannotResetReceiptOrSwitchItIntoOpenOnMac() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal)
        var calls = 0
        try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        let reset = try journal.change(record.key, ["state": .null, "text": "Changed remote prompt"])
        try ChatCommand.consume(reset, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        #expect(calls == 1 && journal.record(record.key)?["state"]?.string == "failed")
        let open = try journal.change(record.key, ["state": .null, "kind": "open", "text": .null, "url": "https://example.test"])
        try OpenOnMac.consume(open, in: journal, device: "mac", at: now) { _ in calls += 1 }
        #expect(calls == 1, "the existing Open consumer sees the shared consumed command ID")
    }

    @Test func changedPayloadBeforeClaimCannotDispatchTheStaleSnapshot() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal)
        try journal.change(record.key, ["text": "Owned newer question"])
        var calls = 0
        #expect(try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() } == false)
        #expect(calls == 0 && journal.record(record.key)?["state"] == nil)
    }

    @Test func accountAndDeviceCannotRebindAnExistingLedger() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        let journal = try Journal(path: path, device: "mac"), record = try request(journal)
        try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in .taken() }
        let next = try request(journal, id: "next")
        var calls = 0
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(next, in: journal, account: "other-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        }
        #expect(throws: (any Error).self) { try journal.claimChatCommand(next, account: "owned-account", device: "other-mac") }
        let otherDevice = try Journal(path: path, device: "other-mac")
        let addressed = try request(otherDevice, id: "other", fields: ["device": "other-mac"])
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(addressed, in: otherDevice, account: "owned-account", device: "other-mac", at: now) { _ in calls += 1; return .taken() }
        }
        #expect(calls == 0 && journal.record(next.key)?["state"] == nil)
    }

    @Test func twoConcurrentConnectionsClaimOnlyOneAttempt() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        let first = try Journal(path: path, device: "mac"), second = try Journal(path: path, device: "mac")
        let record = try request(first)
        let winners = await withTaskGroup(of: Bool.self) { group in
            for journal in [first, second] {
                group.addTask {
                    do {
                        if case .claimed = try journal.claimChatCommand(record, account: "owned-account", device: "mac") { return true }
                        return false
                    } catch { return false }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        #expect(winners == 1)
        #expect(first.record(record.key)?["state"]?.string == "processing")
    }

    @Test func abortAndIgnoreReceiptOrRecordWritesHaveNoDispatchAndCanRecover() throws {
        for operation in ["ABORT", "IGNORE"] {
            for target in ["receipt", "record", "scope", "clock"] {
                let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
                let path = folder.appendingPathComponent("journal.sqlite").path
                let journal = try Journal(path: path, device: "mac"), record = try request(journal)
                let predicate: String
                switch target {
                case "receipt": predicate = "ON meta WHEN NEW.key LIKE 'command/%'"
                case "scope": predicate = "ON meta WHEN NEW.key = 'chat-command-scope/v1'"
                case "clock": predicate = "ON meta WHEN NEW.key = 'clock'"
                default: predicate = "ON records WHEN NEW.collection = 'send'"
                }
                let raise = operation == "ABORT" ? "RAISE(ABORT, 'owned test refusal')" : "RAISE(IGNORE)"
                try sql("CREATE TRIGGER refuse_chat BEFORE INSERT \(predicate) BEGIN SELECT \(raise); END", path: path)
                var calls = 0
                #expect(throws: (any Error).self) {
                    try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
                }
                #expect(calls == 0 && journal.record(record.key)?["state"] == nil)
                try sql("DROP TRIGGER refuse_chat", path: path)
                try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
                #expect(calls == 1 && journal.record(record.key)?["state"]?.string == "taken")
            }
        }
    }

    @Test func failedFinalWriteCannotDispatchAgainAfterReopen() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("journal.sqlite").path
        var first: Journal? = try Journal(path: path, device: "mac")
        let record = try request(try #require(first))
        var calls = 0
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(record, in: try #require(first), account: "owned-account", device: "mac", at: now) { _ in
                calls += 1
                try sql("CREATE TRIGGER refuse_final BEFORE INSERT ON records WHEN NEW.collection = 'send' BEGIN SELECT RAISE(ABORT, 'owned final refusal'); END", path: path)
                return .taken(chat: "a:actual-attempt")
            }
        }
        #expect(calls == 1 && first?.record(record.key)?["state"]?.string == "processing")
        first = nil
        try sql("DROP TRIGGER refuse_final", path: path)
        let reopened = try Journal(path: path, device: "mac")
        try ChatCommand.consume(try #require(reopened.record(record.key)), in: reopened, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        #expect(calls == 1 && reopened.record(record.key)?["state"]?.string == "failed")
        #expect(reopened.record(record.key)?["chat"] == nil, "do not invent a recovered accepted session after uncertain outcome")
    }

    @Test func dispatchErrorIsOutcomeUnknownAndNeverAutomaticallyRepeated() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal)
        var calls = 0
        try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in
            calls += 1; throw Journal.Failure.sql("Owned unknown outcome")
        }
        let failed = try #require(journal.record(record.key))
        #expect(failed["state"]?.string == "failed" && failed["reason"]?.string == ChatCommand.interrupted)
        #expect(try ChatCommand.consume(failed, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() } == false)
        #expect(calls == 1)
    }
    @Test func changedPayloadAfterDispatchCannotReceiveAStaleSuccessOrRunAgain() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let record = try request(journal)
        var calls = 0
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { _ in
                calls += 1
                try journal.change(record.key, ["text": "Newer remote payload"])
                return .taken(chat: "a:old-effect")
            }
        }
        let changed = try #require(journal.record(record.key))
        #expect(changed["state"]?.string == "processing" && changed["chat"] == nil)
        try ChatCommand.consume(changed, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        #expect(calls == 1 && journal.record(record.key)?["state"]?.string == "failed")
        #expect(journal.record(record.key)?["text"]?.string == "Newer remote payload")
    }

    @Test func aProcessingRecordWithoutLocalReceiptCannotAuthorizeOrInventAnOutcome() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let forged = try request(journal, fields: ["state": "processing"])
        var calls = 0
        #expect(throws: (any Error).self) {
            try ChatCommand.consume(forged, in: journal, account: "owned-account", device: "mac", at: now) { _ in calls += 1; return .taken() }
        }
        #expect(calls == 0 && journal.record(forged.key)?["state"]?.string == "processing")
    }

    @Test func anUnclaimedProcessingRecordDoesNotBlockAnIndependentQuestion() throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
        let forged = try request(journal, id: "unclaimed", fields: ["state": "processing"])
        let legitimate = try request(journal, id: "legitimate")
        var attempted: [String] = []
        for record in [forged, legitimate] {
            do {
                try ChatCommand.consume(record, in: journal, account: "owned-account", device: "mac", at: now) { original in
                    attempted.append(original.id)
                    return .taken(chat: "a:accepted")
                }
            } catch Journal.ChatRefusal.missingReceipt { continue }
        }
        #expect(attempted == [legitimate.id])
        #expect(journal.record(forged.key) == forged, "No local receipt means no invented refusal or accepted outcome")
        #expect(journal.record(legitimate.key)?["state"]?.string == "taken")
        #expect(journal.record(legitimate.key)?["chat"]?.string == "a:accepted")
    }

}
