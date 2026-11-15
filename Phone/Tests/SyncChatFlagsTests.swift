import Foundation
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class SyncChatFlagsTests: XCTestCase {
    private var folder: URL!
    private let id = "a:fixture"
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-chat-flags-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func engine(_ server: SyncMemoryServer, _ seal: Seal, allow: Bool? = nil) throws -> PhoneSync {
        var options = PhoneSync.Options(base: URL(string: "https://sync.test")!, folder: folder,
                    device: .init(id: "phone", name: "Test iPhone", model: "iPhone"), transport: server)
        if let allow { options.chatFlagsGoUp = allow }
        return try PhoneSync(seal: seal, options: options)
    }

    private func joined(supported: Bool, allow: Bool? = nil) async throws -> (PhoneSync, TestMac, SyncMemoryServer, Seal) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        mac.client.start()
        let completed1 = await until { mac.client.state == .live }
        XCTAssertTrue(completed1)
        try mac.write(OpenOnMac.capability, "mac", ["device": "mac", "open": 1,
                                                  "chatMetadata": supported ? 1 : .null])
        try mac.write(SyncCollection.chat, id, ["device": "mac", "kind": "agent", "title": "Generated",
                                              "answer": "Same answer", "unread": true, "state": "done"])
        let phone = try engine(server, seal, allow: allow)
        phone.start()
        let completed2 = await until { phone.chat(id) != nil && phone.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(completed2)
        return (phone, mac, server, seal)
    }

    func testOlderMacKeepsChoicesLocalAndFreshSupportedChoicesClearOnlyTheirOwnOverrides() async throws {
        let (phone, mac, _, _) = try await joined(supported: false)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertFalse(phone.canSetChat(id))
        try phone.setChat(id, pinned: true, archived: true, unread: false, title: "Local name")
        XCTAssertEqual(phone.chat(id)?.title, "Local name")
        XCTAssertEqual(phone.chat(id)?.pinned, true)
        XCTAssertEqual(phone.chat(id)?.archived, true)
        XCTAssertEqual(phone.chat(id)?.unread, false)
        XCTAssertEqual(phone.journal.record(.init(collection: SyncCollection.chat, id: id))?["title"]?.string, "Generated")
        XCTAssertFalse(phone.journal.pending().contains { $0.record.collection == SyncCollection.chat })
        try mac.write(OpenOnMac.capability, "mac", ["chatMetadata": 1])
        let completed3 = await until { phone.canSetChat(id) }
        XCTAssertTrue(completed3)
        XCTAssertEqual(phone.chat(id)?.title, "Local name", "an upgrade does not silently throw away a pending rename")
        try phone.setChat(id, pinned: false)
        XCTAssertEqual(phone.chat(id)?.archived, true, "unrelated local pending choices remain until their next action")
        XCTAssertEqual(phone.chat(id)?.title, "Local name")
        try phone.setChat(id, archived: false, unread: true, title: "Fresh name")
        let completed4 = await until { mac.journal.record(.init(collection: SyncCollection.chat, id: id))?["title"]?.string == "Fresh name" }
        XCTAssertTrue(completed4)
        let sent = try XCTUnwrap(mac.journal.record(.init(collection: SyncCollection.chat, id: id)))
        XCTAssertNil(sent["pinned"])
        XCTAssertNil(sent["archived"])
        XCTAssertEqual(sent["unread"]?.bool, true)
        XCTAssertTrue(phone.canOpen(on: "mac"), "chat support must preserve the existing open capability")
        try mac.write(SyncCollection.chat, id, ["title": "Later Mac name", "pinned": true])
        let completed5 = await until { phone.chat(id)?.title == "Later Mac name" && phone.chat(id)?.pinned == true }
        XCTAssertTrue(completed5)
    }

    func testARevokedOwnerCannotReceiveChoicesDespiteItsCachedCapability() async throws {
        let (phone, mac, server, _) = try await joined(supported: true)
        defer { phone.stop(); mac.client.stop() }
        let completed6 = await until { phone.canSetChat(id) }
        XCTAssertTrue(completed6)
        server.revoke("mac")
        phone.refreshMacs()
        let completed7 = await until { !phone.macs.contains { $0.id == "mac" } }
        XCTAssertTrue(completed7)
        XCTAssertFalse(phone.canSetChat(id))
        let before = phone.journal.record(.init(collection: SyncCollection.chat, id: id))
        try phone.setChat(id, unread: false, title: "Still local")
        XCTAssertEqual(phone.chat(id)?.title, "Still local")
        XCTAssertEqual(phone.journal.record(.init(collection: SyncCollection.chat, id: id)), before)
    }

    func testUnknownOwnerAndTheExplicitOptOutCannotBypassTheGate() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let unknown = try engine(server, seal)
        defer { unknown.stop() }
        try unknown.journal.change(.init(collection: SyncCollection.chat, id: id), ["device": "mac", "kind": "agent", "title": "Original"])
        try unknown.journal.change(.init(collection: OpenOnMac.capability, id: "mac"), ["device": "mac", "chatMetadata": 1])
        XCTAssertFalse(unknown.canSetChat(id))
        let before = unknown.journal.record(.init(collection: SyncCollection.chat, id: id))
        try unknown.setChat(id, pinned: true)
        XCTAssertEqual(unknown.journal.record(.init(collection: SyncCollection.chat, id: id)), before)

        // A separate folder ensures this is not the unknown engine's journal.
        let originalFolder = folder!
        defer { folder = originalFolder }
        folder = folder.appendingPathComponent("opt-out")
        let (phone, mac, _, _) = try await joined(supported: true, allow: false)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertFalse(phone.canSetChat(id))
        let original = phone.journal.record(.init(collection: SyncCollection.chat, id: id))
        try phone.setChat(id, archived: true)
        XCTAssertEqual(phone.journal.record(.init(collection: SyncCollection.chat, id: id)), original)
    }

    @MainActor private final class Heard {
        var changes: [SyncChange] = []
    }

    func testAnOlderLocalReadSurvivesRestartAndMetadataButReleasesAnIdenticalFutureAnswer() async throws {
        let (phone, mac, server, seal) = try await joined(supported: false)
        defer { mac.client.stop() }
        for (n, kind) in [(1, "asked"), (2, "message")] {
            try mac.write(SyncCollection.chatItem, id + "/i\(n)", ["chat": .string(id), "n": .number(Double(n)), "kind": .string(kind), "text": "Same words"])
        }
        let completed8 = await until { phone.messages(in: id).count == 2 }
        XCTAssertTrue(completed8)
        try phone.setChat(id, unread: false)
        try mac.write(SyncCollection.chat, id, ["title": "Metadata rename", "updated": .number(Date().timeIntervalSince1970)])
        let completed9 = await until { phone.chat(id)?.title == "Metadata rename" }
        XCTAssertTrue(completed9)
        XCTAssertEqual(phone.chat(id)?.unread, false)
        phone.stop()
        let again = try engine(server, seal)
        defer { again.stop() }
        XCTAssertEqual(again.chat(id)?.unread, false)
        let heard = Heard()
        again.onChanges = { batch in MainActor.assumeIsolated { heard.changes += batch.changes } }
        again.start()
        for (n, kind) in [(3, "asked"), (4, "message")] {
            try mac.write(SyncCollection.chatItem, id + "/i\(n)", ["chat": .string(id), "n": .number(Double(n)), "kind": .string(kind), "text": "Same words"])
        }
        let completed10 = await until {
            again.messages(in: id).count == 4 && heard.changes.contains {
                if case .chat(let head) = $0 { return head.id == id && head.unread }; return false
            }
        }
        XCTAssertTrue(completed10)
        XCTAssertEqual(again.chat(id)?.unread, true)
        XCTAssertTrue(heard.changes.contains { if case .chat(let head) = $0 { return head.id == id && head.unread }; return false },
                      "new items must refresh the bridge's head even without a changed head record")
    }
}
