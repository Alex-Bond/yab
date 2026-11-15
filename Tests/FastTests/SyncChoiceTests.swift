import Foundation
import SyncKit
import Testing
@testable import Fast

@MainActor
struct SyncChoiceTests {
    @Test func malformedRemoteChoicesAreFailedBeforeEitherChatOrNewAgentDispatch() throws {
        let values: [Value] = [.number(.nan), .number(.infinity), .number(-1), .number(0.5),
                               .number(Double(Int.max)), .number(1e100), "1", .bool(true)]
        let center = SyncCenter()
        for (n, value) in values.enumerated() {
            for chat in [nil, "a:existing", "c:existing"] as [String?] {
                var fields: [String: Value] = ["device": "mac", "kind": "code", "choice": value, "text": "ordinary words"]
                if let chat { fields["chat"] = .string(chat) }
                let record = Record(collection: SyncChats.send, id: "bad-\(n)", fields: fields)
                let waiting = try #require(SyncChats.waiting([record], device: "mac").first)
                #expect(waiting.invalidChoice)
                #expect(waiting.choice == nil)
                let result = center.say(waiting)
                #expect(result.reason == SyncChoice.invalidReason)
                #expect(result.made == nil)
            }
        }
    }

    @Test func validChoiceKeepsItsExactIndexAndMissingChoiceKeepsOrdinaryWords() throws {
        for n in [0, 1, 42] {
            let record = Record(collection: SyncChats.send, id: "valid", fields: ["device": "mac", "choice": .number(Double(n))])
            let words = try #require(SyncChats.waiting([record], device: "mac").first)
            #expect(words.choice == n)
            #expect(words.invalidChoice == false)
        }
        let text = Record(collection: SyncChats.send, id: "text", fields: ["device": "mac", "text": "hello"])
        let words = try #require(SyncChats.waiting([text], device: "mac").first)
        #expect(words.choice == nil)
        #expect(words.invalidChoice == false)
        #expect(words.text == "hello")
        #expect(words.kind == "agent")
        #expect(SyncChoice.index(.number(Double(Int.max))) == nil)
        let legacy = Record(collection: SyncChats.send, id: "legacy-code", fields: ["device": "mac", "chat": "c:known", "choice": 2])
        let continuation = try #require(SyncChats.waiting([legacy], device: "mac").first)
        #expect(continuation.chat == "c:known")
        #expect(continuation.choice == 2)
        #expect(continuation.invalidChoice == false)
    }

    @Test func malformedChoiceWithNoTextIsStillReturnedForTerminalFailure() throws {
        let record = Record(collection: SyncChats.send, id: "invalid", fields: ["device": "mac", "choice": .number(1e100)])
        #expect(SyncChats.waiting([record], device: "mac").count == 1)
    }

    @Test func obsoleteChoicesAndChatKindsCannotDispatchAnAgent() {
        let center = SyncCenter()
        for chat in [nil, "a:existing", "c:existing"] as [String?] {
            let words = SyncChats.Words(id: "choice", chat: chat, text: "ordinary words", kind: "agent", project: nil, choice: 0, at: Date())
            let result = center.say(words)
            #expect(result.reason == SyncChoice.targetReason && result.made == nil)
        }
        let removed = SyncChats.Words(id: "removed", chat: nil, text: "ordinary words", kind: "code", project: "old", choice: nil, at: Date())
        #expect(center.say(removed).reason != nil)
    }
}
