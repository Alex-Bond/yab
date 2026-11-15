import Foundation
import Testing
@testable import Fast

/// Real Chat coding, Chats store and Agents revival/follow-up, not a transport stub.
@Suite(.serialized)
@MainActor
struct GeminiContinuationTests {
    private func saved(textOnly: Bool, origin: Chat.Began = .other) throws -> Chat {
        let session = Agents.Session(id: "gemini-resume-" + UUID().uuidString, cli: "gemini", name: "Gemini", prompt: "Remember plum", state: .done)
        session.full = false
        session.textOnly = textOnly
        session.origin = origin
        session.thread = "kept-gemini-conversation"
        session.model = "gemini-3.8-flash-high"
        session.effort = "medium"
        session.result = "plum"
        session.items = [ChatItem(id: "asked", kind: .asked, text: "Remember plum", state: .done),
                         ChatItem(id: "answer", kind: .message, text: "plum", state: .done)]
        return try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(Agents().chat(of: session)))
    }

    private func withGeminiConnected(_ work: () throws -> Void) rethrows {
        let settings = Store.settings
        let keys = ["agents.explicit-connections.v1", "agents.revoked-connections.v1", "agents.consent-migrated.v1", "agents.connection-generation.gemini"]
        let previous = keys.map { settings.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { settings.set(value, forKey: key) } else { settings.removeObject(forKey: key) }
            }
        }
        // Admission only, without cancelling an unrelated connection fixture.
        var allowed = Set(settings.stringArray(forKey: keys[0]) ?? [])
        var revoked = Set(settings.stringArray(forKey: keys[1]) ?? [])
        allowed.insert("gemini"); revoked.remove("gemini")
        settings.set(Array(allowed), forKey: keys[0])
        settings.set(Array(revoked), forKey: keys[1])
        settings.set(UUID().uuidString, forKey: keys[3])
        try work()
    }

    @Test(arguments: [true, false])
    func coldGeminiChatKeepsItsBoundaryAndAcceptsTheNextTurn(textOnly: Bool) throws {
        let chat = try saved(textOnly: textOnly)
        Chats.shared.keep(chat)
        defer { Chats.shared.remove(chat.id) }
        let agents = Agents()
        let revived = try #require(agents.revive(chat.id))
        #expect(!revived.full, "A saved Gemini chat never inherits Mac access")
        #expect(revived.textOnly == textOnly, "A text chat must not gain browser tools on restart")
        #expect(revived.thread == "kept-gemini-conversation")
        #expect(revived.model == "gemini-3.8-flash-high" && revived.effort == "medium")
        #expect(!revived.movable)
        try withGeminiConnected {
            // Synchronous admission only. Stop before the actor can launch any CLI.
            defer { _ = agents.stop(chat.id) }
            agents.followUp(chat.id, "What word did I ask you to remember?")
            #expect(revived.state == .starting)
            #expect(revived.result != GeminiSupport.noMac)
            #expect(revived.textOnly == textOnly && !revived.full)
            #expect(!revived.movable)
            #expect(revived.model == "gemini-3.8-flash-high" && revived.effort == "medium")
            #expect(revived.told.last == "What word did I ask you to remember?")
        }
    }

    @Test(arguments: [Chat.Began.field, .here, .newTabs])
    func olderGeminiChatsInferOnlyTheirOriginalBrowserOrTextScope(origin: Chat.Began) throws {
        let chat = try saved(textOnly: origin == .field, origin: origin)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        object.removeValue(forKey: "textOnly") // A literal pre-migration record.
        object.removeValue(forKey: "effort")
        let legacy = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: object))
        Chats.shared.keep(legacy)
        defer { Chats.shared.remove(legacy.id) }
        let revived = try #require(Agents().revive(legacy.id))
        #expect(!revived.full)
        #expect(revived.textOnly == (origin == .field))
        #expect(revived.thread == legacy.thread)
        #expect(revived.effort == nil)
    }

    @Test(arguments: ["claude", "codex", "cursor"])
    func otherProvidersKeepTheirExistingRevivalBehavior(cli: String) throws {
        var chat = try saved(textOnly: false)
        chat.cli = cli
        Chats.shared.keep(chat)
        defer { Chats.shared.remove(chat.id) }
        let revived = try #require(Agents().revive(chat.id))
        #expect(revived.full && !revived.textOnly)
        #expect(revived.effort == nil)
    }
}
