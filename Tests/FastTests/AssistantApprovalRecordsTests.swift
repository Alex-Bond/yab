import Foundation
import SyncKit
import Testing
@testable import SyncKit

struct AssistantApprovalRecordsTests {
    private func until(_ client: SyncClient, _ done: @escaping () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if client.queue.sync(execute: done) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test func seenChangesNoApprovedFactAndOldReadersRejectChatPlaces() throws {
        var request = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: "account", mac: "mac", assistant: "local.external",
            session: "child", tab: "chat:root", permit: "mail.read", title: "Claude: Search your mail?",
            lines: ["Travel", "once for this chat"], expires: Date().addingTimeInterval(300))
        // This is the legacy reader's actual place check. It refuses a chat
        // rather than ever delivering its answer to an unrelated tab.
        #expect(UUID(uuidString: request.tab) == nil)
        #expect(!AssistantApprovalRecords.Request.validPlace("chat:"))
        #expect(!AssistantApprovalRecords.Request.validPlace("other:root"))
        let answer = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true)
        let digest = try request.digest()
        request.seen = .init(device: "mac")
        #expect(try request.digest() == digest)
        try answer.validate(request: request)
        let record = Record(collection: AssistantApprovalRecords.requestCollection, id: request.id,
                            fields: try request.fields(), stamps: ["body": Stamp(wall: 1, device: "mac")])
        #expect(try AssistantApprovalRecords.Request.read(record, account: "account", mac: "mac").seen == request.seen)
        request.seen = .init(device: "stranger")
        #expect(throws: AssistantApprovalRecords.Failure.invalid) { try request.validate() }
    }

    @Test func sealedRequestAndAnswerAreBoundToFactsAndWriters() throws {
        SyncCollection.register()
        let id = UUID().uuidString.lowercased()
        let tab = UUID().uuidString.lowercased()
        let request = try AssistantApprovalRecords.Request(
            id: id, account: "account", mac: "mac", assistant: "dots",
            session: "session", tab: tab, permit: "send-key", title: "Send message?",
            lines: ["example.test", "To: friend@example.test", "Hello"],
            expires: Date().addingTimeInterval(300))
        let sealed = Record(collection: AssistantApprovalRecords.requestCollection, id: id,
                            fields: try request.fields(), stamps: ["body": Stamp(wall: 1, device: "mac")])
        #expect(try AssistantApprovalRecords.Request.read(sealed, account: "account", mac: "mac") == request)
        #expect(throws: AssistantApprovalRecords.Failure.owner) {
            _ = try AssistantApprovalRecords.Request.read(sealed, account: "account", mac: "other-mac")
        }
        let answer = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true)
        let sealedAnswer = Record(collection: AssistantApprovalRecords.answerCollection, id: id,
                                  fields: try answer.fields(), stamps: ["body": Stamp(wall: 2, device: "phone")])
        #expect(try AssistantApprovalRecords.Answer.read(sealedAnswer, request: request, device: "phone") == answer)
        #expect(throws: AssistantApprovalRecords.Failure.owner) {
            _ = try AssistantApprovalRecords.Answer.read(sealedAnswer, request: request, device: "assistant")
        }
        let changed = try AssistantApprovalRecords.Request(
            id: id, account: "account", mac: "mac", assistant: "dots",
            session: "session", tab: tab, permit: "send-key", title: "Send message?",
            lines: ["example.test", "To: stranger@example.test", "Hello"],
            expires: Date().addingTimeInterval(300))
        #expect(throws: AssistantApprovalRecords.Failure.changed) {
            _ = try AssistantApprovalRecords.Answer.read(sealedAnswer, request: changed, device: "phone")
        }
    }

    /// The person at the Mac: its question still goes up, quiet (opened),
    /// so the iPhone has it in its tray but doesn't ring, and the push
    /// spends neither an alert nor the question's one withdrawal. Away, it
    /// rings: `seen` comes off, an alert goes, and an answer given to the
    /// quiet one still holds (bug 2026-10-22: nothing reached the iPhone).
    @Test func aQuestionAskedAtTheMacGoesUpQuietAndRingsOnceAway() async throws {
        SyncCollection.register()
        let server = MemoryServer(), seal = Seal.make()
        func client(_ device: String) throws -> SyncClient {
            try SyncClient(base: URL(string: "https://sync.test")!, journal: Journal(path: nil, device: device),
                           seal: seal, device: .init(id: device, name: device, model: "test"), transport: server)
        }
        let mac = try client("mac"), phone = try client("phone")
        defer { mac.stop(); phone.stop() }
        mac.start(); phone.start()
        #expect(await until(mac) { mac.state == .live })
        #expect(await until(phone) { phone.state == .live })

        let id = UUID().uuidString.lowercased()
        let request = try AssistantApprovalRecords.Request(
            id: id, account: seal.account, mac: "mac", assistant: "local.external", session: "s",
            tab: UUID().uuidString.lowercased(), permit: "mail.send:k", title: "Claude: Send this mail?",
            lines: ["To ann@example.com"], expires: Date().addingTimeInterval(900))
        let key = Record.Key(collection: AssistantApprovalRecords.requestCollection, id: id)
        func onPhone() -> AssistantApprovalRecords.Request? {
            phone.journal.record(key).flatMap { try? AssistantApprovalRecords.Request.read($0, account: seal.account, mac: "mac") }
        }

        try AssistantApprovalRecords.publish(request, .quiet, by: mac)
        #expect(await until(phone) { onPhone() != nil })
        let quiet = try #require(onPhone())
        #expect(quiet.seen?.device == "mac", "it reaches the phone, opened")
        #expect(await until(mac) { mac.journal.pending().isEmpty })
        server.lock.lock(); var alerts = server.alertIDs, withdrawals = server.withdrawals; server.lock.unlock()
        #expect(alerts.isEmpty && withdrawals.isEmpty, "a quiet question rings nothing and spends no withdrawal")
        // Answered on the phone while quiet: the Mac takes it.
        let early = try AssistantApprovalRecords.Answer(request: quiet, device: "phone", yes: true)

        #expect(try AssistantApprovalRecords.ring(id, by: mac, mac: "mac"))
        #expect(await until(phone) { onPhone()?.seen == nil })
        #expect(await until(mac) { mac.journal.pending().isEmpty })
        server.lock.lock(); alerts = server.alertIDs; server.lock.unlock()
        #expect(alerts == [id], "away, it rings once")
        let rung = try #require(onPhone())
        try early.validate(request: rung)
        #expect(try rung.digest() == request.digest())
        // Rung already: nothing more. Not in Sync: false, so the Mac publishes it.
        #expect(try AssistantApprovalRecords.ring(id, by: mac, mac: "mac"))
        #expect(!(try AssistantApprovalRecords.ring(UUID().uuidString.lowercased(), by: mac, mac: "mac")))
        #expect(await until(mac) { mac.journal.pending().isEmpty })
        server.lock.lock(); alerts = server.alertIDs; server.lock.unlock()
        #expect(alerts == [id])

        // Opened on the Mac: its withdrawal goes, once.
        try AssistantApprovalRecords.publish(rung, .opened, by: mac)
        #expect(await until(phone) { onPhone()?.seen != nil })
        #expect(await until(mac) { mac.journal.pending().isEmpty })
        server.lock.lock(); withdrawals = server.withdrawals; server.lock.unlock()
        #expect(withdrawals == [id])
    }

    @Test func aSecondDeviceCanAnswerThroughSealedSync() async throws {
        SyncCollection.register()
        let server = MemoryServer(), seal = Seal.make()
        func client(_ device: String) throws -> SyncClient {
            try SyncClient(base: URL(string: "https://sync.test")!, journal: Journal(path: nil, device: device),
                           seal: seal, device: .init(id: device, name: device, model: "test"), transport: server)
        }
        let mac = try client("mac"), phone = try client("phone")
        defer { mac.stop(); phone.stop() }
        mac.start(); phone.start()
        #expect(await until(mac) { mac.state == .live })
        #expect(await until(phone) { phone.state == .live })

        let id = UUID().uuidString.lowercased()
        let request = try AssistantApprovalRecords.Request(
            id: id, account: seal.account, mac: "mac", assistant: "dots", session: "task",
            tab: UUID().uuidString.lowercased(), permit: "send-key", title: "Send message?",
            lines: ["To: friend@example.test", "Hello"], expires: Date().addingTimeInterval(300))
        let key = Record.Key(collection: AssistantApprovalRecords.requestCollection, id: id)
        try mac.journal.change(key, request.fields())
        mac.kick()
        #expect(await until(phone) { phone.journal.record(key) != nil })
        let received = try #require(phone.journal.record(key))
        #expect(try AssistantApprovalRecords.Request.read(received, account: seal.account, mac: "mac") == request)
        #expect(!server.everything.contains("friend@example.test"))

        let answer = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true)
        let answerKey = Record.Key(collection: AssistantApprovalRecords.answerCollection, id: id)
        try phone.journal.change(answerKey, answer.fields())
        phone.kick()
        #expect(await until(mac) { mac.journal.record(answerKey) != nil })
        let delivered = try #require(mac.journal.record(answerKey))
        #expect(try AssistantApprovalRecords.Answer.read(delivered, request: request, device: "phone") == answer)
        try mac.journal.remove(key)
        mac.kick()
        #expect(await until(phone) { phone.journal.record(key)?.alive() == false })
        #expect(throws: AssistantApprovalRecords.Failure.owner) {
            _ = try AssistantApprovalRecords.Request.read(try #require(phone.journal.record(key)), account: seal.account, mac: "mac")
        }
    }
}
