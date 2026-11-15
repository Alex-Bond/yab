import XCTest
import SyncKit
@testable import YabPhone

/// A pick the agent asked on the Mac (ChatItem.question, then .chose)
/// reads on the iPhone as the Mac's column draws it: its question, your
/// pick, then its answer, which never takes the question in.
final class ChatQuestionMappingTests: XCTestCase {
    func testAQuestionAndThePickReadAsAConversation() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:q1", fields: [
            "device": "mac-a", "title": "Avengers", "state": "done", "updated": 100, "started": 1,
        ])))
        func item(_ n: Int, _ kind: String, _ text: String, name: String = "") throws -> SyncChatItem {
            try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:q1/\(n)", fields: [
                "chat": "a:q1", "n": .number(Double(n)), "kind": .string(kind), "name": .string(name), "text": .string(text),
            ])))
        }
        let items = [
            try item(1, "asked", "where can I watch the avengers?"),
            try item(2, "message", "Checking Netflix, Disney+ and Hulu."),
            try item(3, "tool", "", name: "ask"),
            try item(4, "message", "Which scenes do you mean?", name: "question"),
            try item(5, "chose", "New scenes 2026"),
            try item(6, "tool", "", name: "open"),
            try item(7, "message", "Found it on IGN."),
        ]
        let chat = SyncMapping.chat(head, items: items, sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer, .answer, .you, .answer])
        XCTAssertEqual(chat.messages.map(\.text), ["where can I watch the avengers?", "Checking Netflix, Disney+ and Hulu.",
                                                  "Which scenes do you mean?", "New scenes 2026", "Found it on IGN."])
        // The answer's actions copy the answer, never the question.
        let actions = try XCTUnwrap(chat.messages.compactMap(\.work).first { $0.kind == .actions })
        XCTAssertFalse(actions.text.contains("Which scenes"))
    }

    func testWhileItWaitsThePickIsACardNotDots() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:q2", fields: [
            "device": "mac-a", "title": "Avengers", "state": "waiting", "updated": 100, "started": 1,
            "choices": .array(["New scenes 2026", "Blu-ray"]),
        ])))
        let asked = try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:q2/1", fields: [
            "chat": "a:q2", "n": 1, "kind": "asked", "text": "where can I watch it?"])))
        let question = try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:q2/2", fields: [
            "chat": "a:q2", "n": 2, "kind": "message", "name": "question", "text": "Which scenes?"])))
        let chat = SyncMapping.chat(head, items: [asked, question], sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.choices, ["New scenes 2026", "Blu-ray"])
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer])
        XCTAssertFalse(chat.working)
        // Done, a stale pick in the merged head is never read.
        var done = head
        done.state = "done"
        XCTAssertEqual(SyncMapping.chat(done, items: [asked, question], sends: [], macAsleep: false, old: nil).choices, [])
    }
}
