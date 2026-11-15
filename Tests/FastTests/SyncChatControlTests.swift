import Foundation
import SyncKit
import Testing
@testable import Fast

/// Stop and Delete for a chat from the iPhone (ChatControl), and who began
/// a chat (SyncChat.origin): what the Mac reads and says.
@MainActor
struct SyncChatControlTests {
    @Test func anActionWithoutWordsIsReadAsAnAction() throws {
        for action in [SyncSend.Action.stop, .delete] {
            let fields = SyncSend.fields(device: "mac", chat: "a:one", text: nil, choice: nil, kind: nil, project: nil, at: 1, action: action)
            let record = Record(collection: SyncChats.send, id: "send-\(action.rawValue)", fields: fields)
            let words = try #require(SyncChats.waiting([record], device: "mac").first)
            #expect(words.action == action)
            #expect(words.text.isEmpty)
            #expect(SyncSend(record)?.action == action)
        }
        // Empty words and no action are still nothing to take.
        let empty = Record(collection: SyncChats.send, id: "empty", fields: ["device": "mac", "chat": "a:one"])
        #expect(SyncChats.waiting([empty], device: "mac").isEmpty)
    }

    @Test func anActionOnAChatThisMacDoesntHaveFails() {
        let words = SyncChats.Words(id: "x", chat: "a:missing-\(UUID().uuidString)", text: "", kind: "agent", project: nil,
                                    choice: nil, at: Date(), action: .delete)
        let result = SyncCenter().say(words)
        #expect(result.reason == "That chat isn't on this Mac any more.")
        // Words and an action together, or a chat of another kind, aren't one.
        #expect(SyncChats.control(.stop, chat: "a:x", text: "hello").reason != nil)
        #expect(SyncChats.control(.stop, chat: "c:x", text: "").reason != nil)
    }

    @Test func theMacSaysItTakesStopAndDelete() {
        let fields = SyncChats.capability(device: "mac")
        let record = Record(collection: OpenOnMac.capability, id: "mac", fields: fields)
        #expect(ChatControl.supports(record, device: "mac"))
        var older = fields
        older["chatControl"] = nil
        #expect(!ChatControl.supports(Record(collection: OpenOnMac.capability, id: "mac", fields: older), device: "mac"))
    }

    @Test func aChatsHeadSaysWhoBeganIt() throws {
        var chat = SyncChat(id: "a:r", device: "mac", title: "Rent", state: "done", answer: "", cli: "claude",
                            started: 1, updated: 2, origin: "routine", routine: "13lyf")
        let read = try #require(SyncChat(Record(collection: SyncCollection.chat, id: chat.id, fields: chat.fields)))
        #expect(read.origin == "routine")
        #expect(read.routine == "13lyf")
        chat.origin = nil
        chat.routine = nil
        let yours = try #require(SyncChat(Record(collection: SyncCollection.chat, id: chat.id, fields: chat.fields)))
        #expect(yours.origin == nil)
        #expect(yours.routine == nil)
    }
}
