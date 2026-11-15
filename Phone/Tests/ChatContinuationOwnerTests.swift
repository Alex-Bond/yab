import SyncKit
import XCTest
@testable import YabPhone

/// Real sealed records in owned stores. The Mac transport starts no provider.
@MainActor
final class ChatContinuationOwnerTests: XCTestCase {
    private var folder: URL!
    private var apps: [AppModel] = []
    private var macs: [TestMac] = []
    private var leases: [Lease] = []

    private final class Lease {
        weak var engine: PhoneSync?
        weak var client: SyncClient?
        weak var journal: Journal?
        init(_ engine: PhoneSync) { self.engine = engine; client = engine.client; journal = engine.journal }
        init(_ client: SyncClient) { self.client = client; journal = client.journal }
        var released: Bool { engine == nil && client == nil && journal == nil }
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatContinuationOwnerTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        stopOwnedClients()
        let released = await until { self.leases.allSatisfy(\.released) }
        guard released else {
            XCTFail("Owned continuation journals are retained; preserving their directory without unlinking active SQLite files")
            return
        }
        leases = []
        try FileManager.default.removeItem(at: folder)
    }

    private func stopOwnedClients() {
        for app in apps { app.sync.end() }
        for mac in macs { mac.client.stop() }
        apps = []; macs = []
    }

    private func until(_ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func joined(existing: AppModel? = nil, capable: Bool = false) async throws
        -> (AppModel, PhoneSync, TestMac, SyncMemoryServer) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac", agentSelection: capable)
        macs.append(mac); leases.append(Lease(mac.client))
        try mac.write(SyncCollection.space, SyncCollection.firstSpace,
                      SyncSpace(id: SyncCollection.firstSpace, name: "Owned public space", icon: "").fields)
        try mac.write(SyncCollection.chat, "a:owned", ["device": "mac", "kind": "agent", "title": "Owned remote conversation",
            "state": "done", "cli": "claude", "answer": "Earlier owned answer", "updated": .number(Date().timeIntervalSince1970)])
        mac.client.start()
        let macReady = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(macReady)
        let owned = folder.appendingPathComponent(UUID().uuidString)
        let keys = owned.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let app: AppModel
        if let existing { app = existing }
        else {
            let world = World(name: "owned-continuation", space: "public", spaces: [
                Space(id: "public", name: "Public", emoji: "", tint: RGB(240, 240, 240))
            ])
            app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
            apps.append(app)
        }
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: .testing(folder: keys),
            folder: owned.appendingPathComponent("journal"), seed: false, makesKey: false,
            deviceName: "Owned continuation iPhone", transport: server, ownWorld: true))
        let engine = try XCTUnwrap(app.sync.engine)
        leases.append(Lease(engine))
        let ready = await until {
            app.sync.ready && app.sync.line == .live && engine.macs.contains { $0.id == "mac" }
                && engine.chat("a:owned") != nil && app.chats.chat("a:owned") != nil
        }
        XCTAssertTrue(ready)
        return (app, engine, mac, server)
    }

    func testRetainedHeadsWithUnknownOwnersCannotWriteOrdinaryContinuation() async throws {
        let (app, engine, mac, _) = try await joined()
        let id = "a:unknown"
        try mac.write(SyncCollection.chat, id, ["device": "unknown-mac", "kind": "agent", "state": "done"])
        let arrived = await until { engine.chat(id) != nil }
        XCTAssertTrue(arrived)
        XCTAssertFalse(engine.macs.contains { $0.id == "unknown-mac" })
        XCTAssertThrowsError(try engine.say("Owned refused words", in: id)) { error in
            XCTAssertEqual(error as? PhoneSync.ChatSendFailure, .ownerUnavailable)
        }
        XCTAssertThrowsError(try app.sync.sendQuestion(.init(question: "Owned refused context", page: nil, history: []), in: id))
        XCTAssertTrue(engine.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(mac.journal.all(SyncCollection.send).isEmpty)
    }

    func testRevokedOwnerKeepsReadableHistoryButShowsARealErrorWithoutWriting() async throws {
        let (app, engine, mac, server) = try await joined()
        app.openChat("a:owned")
        server.revoke("mac")
        engine.refreshMacs()
        let revoked = await until { !engine.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(revoked)
        XCTAssertNotNil(engine.chat("a:owned"), "Retained readable history cannot authorize a new send")
        XCTAssertEqual(app.chats.chat("a:owned")?.lastAnswer?.text, "Earlier owned answer")
        XCTAssertThrowsError(try engine.say("Owned direct refused words", in: "a:owned"))
        app.chatSheet.draft = "Owned refused continuation"
        app.send(app.chatSheet.draft)
        let failed = await until { app.chats.chat("a:owned")?.messages.last?.role == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(app.chats.chat("a:owned")?.messages.last?.text, PhoneSync.ChatSendFailure.ownerUnavailable.localizedDescription)
        XCTAssertTrue(app.chats.chat("a:owned")?.messages.contains { $0.role == .you && $0.text == "Owned refused continuation" } == true)
        XCTAssertFalse(app.chats.chat("a:owned")?.messages.contains { $0.role == .typing || $0.role == .wait } == true)
        XCTAssertTrue(engine.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(mac.journal.all(SyncCollection.send).isEmpty)
    }

    func testKnownSleepingLegacyOwnerMayQueueWordsWithoutChangingItsProvider() async throws {
        let (app, engine, mac, _) = try await joined()
        XCTAssertFalse(engine.canStartAgent(on: "mac"), "Legacy continuation must not require the new-provider capability")
        mac.asleep = true
        mac.client.sayPresence()
        let sleeping = await until { engine.macs.first { $0.id == "mac" }?.front?.asleep == true }
        XCTAssertTrue(sleeping)
        XCTAssertFalse(try XCTUnwrap(engine.macs.first { $0.id == "mac" }).online)
        mac.client.stop()
        let sent = try app.sync.sendQuestion(.init(question: "Owned sleeping continuation", page: nil, history: []),
                                           in: "a:owned", agent: .codex)
        XCTAssertEqual(sent.device, "mac")
        XCTAssertEqual(sent.chat, "a:owned")
        XCTAssertEqual(sent.state, .waiting)
        let raw = try XCTUnwrap(engine.journal.record(.init(collection: SyncCollection.send, id: sent.id)))
        XCTAssertEqual(raw["text"]?.string, "Owned sleeping continuation")
        XCTAssertNil(raw["cli"])
        XCTAssertNil(raw["agentText"])
        XCTAssertEqual(app.chats.chat("a:owned")?.macCLI, "claude")
        XCTAssertEqual(engine.journal.all(SyncCollection.send).count, 1)
        XCTAssertTrue(mac.journal.all(SyncCollection.send).isEmpty, "An offline Mac has not acknowledged or answered")
    }

    func testCapturedPriorEngineCannotRetargetPreparedContextToAReplacementAccount() async throws {
        let (app, prior, earlierMac, _) = try await joined()
        app.sync.end()
        let (_, current, newMac, _) = try await joined(existing: app, capable: true)
        XCTAssertFalse(prior === current)
        XCTAssertNotEqual(prior.seal.account, current.seal.account)
        XCTAssertTrue(current.macs.contains { $0.id == "mac" }, "The same device name/id in a different account must not make an old context valid")
        app.chatSheet.draft = "Owned not-yet-sent draft"
        let prepared = AskContext(question: "Owned prepared question", page: .init(title: "Owned prior page",
            address: "http://127.0.0.1/owned-prior-page", text: "Owned prior page context"), history: [])
        XCTAssertThrowsError(try app.sync.sendQuestion(prepared, in: "local-prepared", agent: .codex, expectedEngine: prior)) { error in
            XCTAssertEqual((error as? SyncBridge.QuestionFailure)?.errorDescription, SyncBridge.QuestionFailure.syncChanged.errorDescription)
        }
        XCTAssertEqual(app.chatSheet.draft, "Owned not-yet-sent draft")
        XCTAssertTrue(prior.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(current.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(earlierMac.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(newMac.journal.all(SyncCollection.send).isEmpty)
        let fresh = try app.sync.sendQuestion(prepared, in: "local-fresh", agent: .codex, expectedEngine: current)
        let arrived = await until { newMac.journal.record(.init(collection: SyncCollection.send, id: fresh.id)) != nil }
        XCTAssertTrue(arrived, "Fresh explicit intent may use the current joined account")
        let raw = try XCTUnwrap(newMac.journal.record(.init(collection: SyncCollection.send, id: fresh.id)))
        XCTAssertEqual(raw["cli"]?.string, "codex")
        XCTAssertTrue(raw["agentText"]?.string?.contains("Owned prior page context") == true)
        XCTAssertNil(raw["text"])
        XCTAssertTrue(earlierMac.journal.all(SyncCollection.send).isEmpty)
    }
}
