import Foundation
import Testing
@testable import Fast

/// Another app's agent asks once its session to read mail, not once each
/// connection: Claude Code opens `yab mcp` for itself and again from its
/// shell, every one naming the same CLAUDE_CODE_SESSION_ID
/// (Agents.mailGrants, docs/chat-asks.md).
@MainActor
@Suite(.serialized)
struct MailSessionGrantTests {
    @MainActor private struct World {
        let browser: Browser
        let tab: Tab
        let consent: Any?
        let others: Any?
        var made: [Agents.Session] = []

        init() {
            consent = Store.settings.object(forKey: MailConsent.agentsKey)
            others = Store.settings.object(forKey: MailConsent.othersKey)
            Store.settings.set(true, forKey: MailConsent.agentsKey)
            Store.settings.set(true, forKey: MailConsent.othersKey)
            browser = Browser(windowID: UUID())
            tab = Tab(bench: true)
            tab.restore(url: URL(string: "https://news.example.test/")!, title: "News")
            browser.lay([tab])
            browser.activeID = tab.id
            browser.prefs.agentsAsking = .auto
        }

        /// A `yab mcp` connection, as agent-attach makes one.
        mutating func connect(_ client: String?) -> Agents.Session {
            let session = Agents.shared.attach(name: "claude-code", client: client)
            made.append(session)
            return session
        }

        func call(_ session: Agents.Session, _ verb: String, _ request: [String: Any] = [:]) -> (handled: Bool, said: [String: Any]) {
            var said: [String: Any] = [:]
            var full = request
            full["session"] = session.id
            let handled = Bench().mailAsks(AgentCall(bench: Bench(), verb: verb, request: full, browser: browser) { said = $0 })
            return (handled, said)
        }

        func dispose() {
            for session in made {
                session.permit = nil
                Agents.shared.detach(session.id)
            }
            Store.settings.set(consent, forKey: MailConsent.agentsKey)
            Store.settings.set(others, forKey: MailConsent.othersKey)
            for tab in browser.everyTab { tab.permit = nil; tab.handoff = nil; tab.close() }
        }
    }

    private let reads: [(String, [String: Any])] = [
        ("agent-mail-search", ["query": "invoice"]), ("agent-mail-triage", [:]), ("agent-mail-list", ["list": "kept"]),
        ("agent-mail-recall", ["query": "trip"]), ("agent-mail-read", ["thread": "me@example.com|t9"]),
        ("agent-mail-file", ["thread": "me@example.com|t9", "index": 0]),
    ]

    @Test func aSecondConnectionOfTheSameSessionIsAskedNothing() {
        var w = World(); defer { w.dispose() }
        let id = UUID().uuidString.lowercased()
        let first = w.connect(id)
        #expect(first.client == id)
        let asked = w.call(first, "agent-mail-search", ["query": "invoice"])
        #expect(asked.handled && asked.said["asking"] as? Bool == true)
        // The card says the yes is for the session.
        #expect(first.permit?.forSession == true)
        #expect(first.permit?.answers.map(\.title) == ["Allow for This Session"])
        #expect(first.askedOnce == "once for this session")
        #expect(AgentNotices.shared.asked.last { $0.info["chat"] == first.id }?.category == "agent.mail.read.session")
        #expect(AgentNotices.shared.asked.last { $0.info["chat"] == first.id }?.subtitle.hasSuffix("once for this session") == true)
        Agents.shared.answer(chat: first.id, yes: true)
        #expect(!w.call(first, "agent-mail-search", ["query": "invoice"]).handled)

        // The same Claude Code session's next `yab mcp` (its shell's own,
        // one per call): every read goes on, no card.
        for _ in 0..<3 {
            let next = w.connect(id)
            for (verb, request) in reads {
                #expect(!w.call(next, verb, request).handled, "\(verb)")
            }
            #expect(next.permit == nil && next.mailReading)
        }
        #expect(w.tab.permit == nil && w.tab.approved == nil)
    }

    @Test func anotherSessionIsAskedAgain() {
        var w = World(); defer { w.dispose() }
        let first = w.connect(UUID().uuidString)
        _ = w.call(first, "agent-mail-search", ["query": "x"])
        Agents.shared.answer(chat: first.id, yes: true)
        // Another Claude Code session: its own card.
        let other = w.connect(UUID().uuidString)
        #expect(w.call(other, "agent-mail-search", ["query": "x"]).said["asking"] as? Bool == true)
        #expect(other.permit?.kind == .mailRead)
        // A client that names no session: the connection is the session.
        let bare = w.connect(nil)
        #expect(bare.client == nil)
        #expect(w.call(bare, "agent-mail-triage").said["asking"] as? Bool == true)
    }

    @Test func changesAndSendsStillAskInEachConnection() {
        var w = World(); defer { w.dispose() }
        let id = UUID().uuidString
        let first = w.connect(id)
        _ = w.call(first, "agent-mail-search", ["query": "x"])
        Agents.shared.answer(chat: first.id, yes: true)
        let next = w.connect(id)
        #expect(!w.call(next, "agent-mail-search", ["query": "x"]).handled)
        // A change asks as before, once in this connection.
        let change = w.call(next, "agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"])
        #expect(change.handled && change.said["asking"] as? Bool == true)
        #expect(next.permit?.kind == .mailChange(label: "Archive", act: "archive"))
        // A send isn't answered here: its own card asks every time
        // (Agents.sendMail), and the grant left no yes on a tab for it.
        next.permit = nil
        #expect(!w.call(next, "agent-mail-send", ["thread": "me@example.com|t1"]).handled)
        #expect(w.tab.approved == nil)
    }

    @Test func notNowIsHeardOnceAndGrantsNothing() {
        var w = World(); defer { w.dispose() }
        let id = UUID().uuidString
        let first = w.connect(id)
        _ = w.call(first, "agent-mail-search", ["query": "x"])
        Agents.shared.answer(chat: first.id, yes: false)
        let refused = w.call(first, "agent-mail-search", ["query": "x"])
        #expect(refused.handled && (refused.said["error"] as? String)?.contains("not now") == true)
        #expect(w.call(first, "agent-mail-search", ["query": "x"]).said["asking"] as? Bool == true)
        // Nothing kept for the session: its next connection asks too.
        first.permit = nil
        let next = w.connect(id)
        #expect(w.call(next, "agent-mail-search", ["query": "x"]).said["asking"] as? Bool == true)
    }

    @Test func aGrantLapsesUnused() {
        var w = World(); defer { w.dispose() }
        let session = w.connect(UUID().uuidString)
        let then = Date()
        Agents.shared.grantMail(session, now: then)
        #expect(Agents.shared.mailGranted(session, now: then.addingTimeInterval(3600)))
        // Used an hour in, it lasts from then.
        #expect(Agents.shared.mailGranted(session, now: then.addingTimeInterval(3600 + Agents.mailGrantLife - 60)))
        #expect(!Agents.shared.mailGranted(session, now: then.addingTimeInterval(3600 + 2 * Agents.mailGrantLife)))
    }

    @Test func yabsOwnChatsKeepTheirWords() {
        let own = AgentPermit(kind: .mailRead, session: "s", detail: "")
        #expect(own.answers.map(\.title) == ["Search"])
        #expect(AgentNotices.permitCategory(own) == "agent.mail.read")
        var external = own
        external.forSession = true
        #expect(AgentNotices.permitCategory(external) == "agent.mail.read.session")
        #expect(AgentNotices.permitCategories.contains { $0.identifier == "agent.mail.read.session" })
    }

    @Test func onlyAnIdReadsAsAClientSession() {
        #expect(Agents.clientSession("418c7c08-5916-46a8-bda4-5485c12a6593") == "418c7c08-5916-46a8-bda4-5485c12a6593")
        #expect(Agents.clientSession(" abcdef12 ") == "abcdef12")
        #expect(Agents.clientSession(nil) == nil)
        #expect(Agents.clientSession("") == nil)
        #expect(Agents.clientSession("short") == nil)
        #expect(Agents.clientSession("a b c d e f g h") == nil)
        #expect(Agents.clientSession(String(repeating: "a", count: 81)) == nil)
    }
}
