import Combine
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct EnergyIdleTests {
    private func cursor() -> (Agents.Session, CursorServerTests.Wire) {
        let wire = CursorServerTests.Wire()
        wire.ready()
        wire.server.say("read")
        let session = Agents.Session(id: "energy-" + UUID().uuidString, cli: "cursor", name: "Cursor", prompt: "read", state: .running)
        session.cursor = wire.server
        return (session, wire)
    }

    private func token(_ text: String, _ session: Agents.Session, thinking: Bool = false) {
        Agents.shared.hear(["method": "session/update", "params": ["sessionId": "C1", "update": [
            "sessionUpdate": thinking ? "agent_thought_chunk" : "agent_message_chunk",
            "content": ["type": "text", "text": text]]]], on: session)
    }

    @Test func cursorBurstKeepsAllWordsWithoutPublishingEveryToken() async throws {
        let (session, wire) = cursor()
        defer { Chats.shared.remove(session.id); _ = wire }
        for _ in 0..<1000 { token("字🙂", session) }
        #expect(session.result == String(repeating: "字🙂", count: 1000))
        #expect(session.items.last?.text == session.result)
        // Before the publication deadline, the global transcript store should
        // still be untouched. Old Cursor copied and published it 1000 times.
        #expect(Chats.shared.chat(session.id) == nil)
        try await Task.sleep(for: .milliseconds(180))
        #expect(Chats.shared.chat(session.id)?.items.last?.text == session.result)
        let saved = Chats.shared.chat(session.id)?.updated
        try await Task.sleep(for: .milliseconds(150))
        #expect(Chats.shared.chat(session.id)?.updated == saved)
    }

    @Test func toolPublishesPendingTextImmediatelyAndRetiresDelayedPublication() async throws {
        let (session, wire) = cursor()
        defer { Chats.shared.remove(session.id); _ = wire }
        token("The answer", session)
        token("A thought", session, thinking: true)
        Agents.shared.hear(["method": "session/update", "params": ["sessionId": "C1", "update": [
            "sessionUpdate": "tool_call", "toolCallId": "read", "title": "Read page", "status": "in_progress"]]], on: session)
        #expect(Chats.shared.chat(session.id)?.items.first?.text == "The answer")
        #expect(Chats.shared.chat(session.id)?.items.last?.name == "Read page")
        let saved = Chats.shared.chat(session.id)?.updated
        try await Task.sleep(for: .milliseconds(180))
        #expect(Chats.shared.chat(session.id)?.updated == saved)
    }

    @Test func replacedProviderCannotPublishOldTokens() async throws {
        let (session, wire) = cursor()
        defer { Chats.shared.remove(session.id); _ = wire }
        token("old provider", session)
        session.providerRun = UUID()
        try await Task.sleep(for: .milliseconds(180))
        #expect(Chats.shared.chat(session.id) == nil)
        token(" new provider", session)
        try await Task.sleep(for: .milliseconds(180))
        #expect(Chats.shared.chat(session.id)?.items.last?.text == session.result)
    }

    @Test func newProviderFirstTokenDoesNotWaitForAnOldPublication() async throws {
        let (session, wire) = cursor()
        defer { Chats.shared.remove(session.id); _ = wire }
        token("old provider", session)
        session.providerRun = UUID()
        session.items = []
        session.result = ""
        token("new provider", session)
        try await Task.sleep(for: .milliseconds(180))
        #expect(Chats.shared.chat(session.id)?.items.last?.text == "new provider")
    }

    @Test func feedSeesSameLengthEditsAndChangesBeforeTheLastItem() {
        let session = LiveStreamTests.session("codex")
        session.items = [ChatItem(id: "a", kind: .message, text: "old"),
                         ChatItem(id: "b", kind: .message, text: "tail")]
        Agents.shared.withSessionFixture([session]) {
            let feed = ChatFeed()
            feed.follow(session.id)
            defer { feed.leave() }
            #expect(feed.chat?.items.first?.text == "old")
            session.items[0].text = "new"
            feed.look()
            #expect(feed.chat?.items.first?.text == "new")
            session.items[1].text = "next"
            feed.look()
            #expect(feed.chat?.items.last?.text == "next")
        }
    }
}
