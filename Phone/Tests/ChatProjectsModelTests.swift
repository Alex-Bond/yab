import Foundation
import SyncKit
import XCTest
@testable import YabPhone

/// Projects of chats on the iPhone: how the Chats page sorts them, what a
/// chat keeps, and what goes to a Mac (only one that names chatProjects).
@MainActor
final class ChatProjectsModelTests: XCTestCase {
    private var folder: URL!
    private let id = "a:fixture"
    private let lisbon = "prj-1a2b3c4d"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-chat-projects-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: - the Chats page

    private func chat(_ id: String, project: String? = nil, pinned: Bool = false) -> Chat {
        Chat(id: id, title: id, pinned: pinned, project: project)
    }

    func testAProjectsChatsLeaveTheCardsAndItsCardStandsAtItsNewestChat() {
        let projects = [ChatProject(id: lisbon, name: "Lisbon Trip", emoji: "x"),
                        ChatProject(id: "prj-pinned", name: "Pinned", emoji: "y", pinned: true),
                        ChatProject(id: "prj-empty", name: "Empty", emoji: "z"),
                        ChatProject(id: "prj-old", name: "Archived", emoji: "w", archived: true)]
        let listed = [chat("pin", pinned: true), chat("a"), chat("l1", project: lisbon), chat("b"), chat("l2", project: lisbon),
                      chat("p1", project: "prj-pinned"), chat("gone", project: "prj-unknown"), chat("old", project: "prj-old")]
        let split = ChatSectioning.byProject(listed, projects: projects)
        XCTAssertEqual(split.loose.map(\.id), ["pin", "a", "b", "gone", "old"], "an unknown or archived project's chat stays in sight")
        XCTAssertEqual(split.within[lisbon]?.map(\.id), ["l1", "l2"])
        XCTAssertEqual(split.within["prj-pinned"]?.map(\.id), ["p1"])
        let cards = ChatSectioning.cards(split.loose, listed: listed, projects: projects, within: split.within)
        XCTAssertEqual(cards.map(\.id), ["pin", "a", lisbon, "b", "gone", "old", "prj-empty"],
                       "a pinned project is a circle, not a card; one with no chats comes last")
    }

    func testAChatKeepsItsProjectAndAnOlderOneReadsWithout() throws {
        let old = #"{"id":"c1","title":"Old","pinned":false,"unread":false,"archived":false,"day":"today","time":"","by":"claude","taskLike":false,"messages":[]}"#
        XCTAssertNil(try JSONDecoder().decode(Chat.self, from: Data(old.utf8)).project)
        let kept = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat("c2", project: lisbon)))
        XCTAssertEqual(kept.project, lisbon)
    }

    func testAMacsHeadSaysItsProject() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:k3", fields: [
            "device": "mac-a", "title": "Hotels", "state": "done", "updated": .number(1_759_700_000), "project": .string(lisbon),
        ])))
        XCTAssertEqual(SyncMapping.chat(head, items: [], sends: [], macAsleep: false, old: nil).project, lisbon)
        let plain = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:k4", fields: ["device": "mac-a", "title": "Plain"])))
        XCTAssertNil(SyncMapping.chat(plain, items: [], sends: [], macAsleep: false, old: nil).project)
    }

    func testTheStoreKeepsTheMacsOrderAndClosesAProjectThatLeft() {
        let store = ProjectStore()
        store.adopt([ChatProject(id: lisbon, name: "Lisbon Trip", emoji: "x", pinned: true),
                     ChatProject(id: "prj-b", name: "B", emoji: "y", archived: true)])
        XCTAssertEqual(store.pinned.map(\.id), [lisbon])
        XCTAssertEqual(store.listed.map(\.id), [lisbon])
        store.page = ProjectPresentation(id: UUID(), project: lisbon)
        store.info = true
        store.adopt([])
        XCTAssertNil(store.page)
        XCTAssertFalse(store.info)
    }

    // MARK: - sync

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func joined(projects: Bool) async throws -> (PhoneSync, TestMac) {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        mac.client.start()
        let live = await until { mac.client.state == .live }
        XCTAssertTrue(live)
        try mac.write(OpenOnMac.capability, "mac", ["device": "mac", "open": 1, "chatMetadata": 1,
                                                  "chatAgent": .number(Double(ChatAgent.version)),
                                                  ChatProjects.field: projects ? .number(Double(ChatProjects.version)) : .null])
        try mac.write(SyncCollection.chat, id, ["device": "mac", "kind": "agent", "title": "Hotels", "state": "done"])
        try mac.write(SyncCollection.project, lisbon, SyncProject(id: lisbon, name: "Lisbon Trip", emoji: "x", tint: "orange",
                                                                  instructions: "Short lists.", pinned: true, order: "a",
                                                                  created: 1, updated: 2).fields)
        let options = PhoneSync.Options(base: URL(string: "https://sync.test")!, folder: folder,
                                        device: .init(id: "phone", name: "Test iPhone", model: "iPhone"), transport: server)
        let phone = try PhoneSync(seal: seal, options: options)
        phone.start()
        let ready = await until { phone.chat(id) != nil && phone.macs.contains { $0.id == "mac" } && !phone.projects().isEmpty }
        XCTAssertTrue(ready)
        return (phone, mac)
    }

    func testAMacThatTakesProjectsGetsTheMoveAndTheNewChatInOne() async throws {
        let (phone, mac) = try await joined(projects: true)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertEqual(phone.projects().map(\.name), ["Lisbon Trip"])
        XCTAssertEqual(phone.projects().first?.instructions, "Short lists.")
        XCTAssertTrue(phone.canMoveToProject(id))
        XCTAssertTrue(phone.canStartInProject(on: "mac"))

        try phone.moveChat(id, to: lisbon)
        let moved = await until { mac.journal.record(.init(collection: SyncCollection.chat, id: id))?["project"]?.string == lisbon }
        XCTAssertTrue(moved, "the head's project, stamped by the iPhone")
        XCTAssertEqual(phone.chat(id)?.project, lisbon)
        try phone.moveChat(id, to: nil)
        let out = await until { mac.journal.record(.init(collection: SyncCollection.chat, id: id))?["project"]?.string == nil }
        XCTAssertTrue(out, "out of its project")
        XCTAssertThrowsError(try phone.moveChat(id, to: "not-a-project"))

        let send = try phone.startChat("Is the 7:05 return worth it?", on: "mac", clientChat: "local", agent: .claude, project: lisbon)
        let record = try XCTUnwrap(phone.journal.record(.init(collection: SyncCollection.send, id: send.id)))
        XCTAssertEqual(record["project"]?.string, lisbon)
        XCTAssertNil(record["chat"])
        XCTAssertNil(ChatCommand.refusal(record), "the Mac takes it")
    }

    func testAMacThatDoesntTakeProjectsIsOfferedNothingAndGetsNothing() async throws {
        let (phone, mac) = try await joined(projects: false)
        defer { phone.stop(); mac.client.stop() }
        XCTAssertFalse(phone.canMoveToProject(id))
        XCTAssertFalse(phone.canStartInProject(on: "mac"))
        let before = phone.journal.record(.init(collection: SyncCollection.chat, id: id))
        XCTAssertThrowsError(try phone.moveChat(id, to: lisbon))
        XCTAssertEqual(phone.journal.record(.init(collection: SyncCollection.chat, id: id)), before)
        XCTAssertThrowsError(try phone.startChat("words", on: "mac", clientChat: "local", agent: .claude, project: lisbon))
        XCTAssertTrue(phone.sends().isEmpty)
    }
}
