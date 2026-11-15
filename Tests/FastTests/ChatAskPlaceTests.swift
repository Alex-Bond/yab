import Foundation
import SyncKit
import Testing
@testable import Fast

/// A question for the whole chat, its mail, is asked of the chat: by the
/// Mac's notification with its buttons, or in the chat's field, never on
/// whatever tab is in front (docs/chat-asks.md).
@MainActor
@Suite(.serialized)
struct ChatAskPlaceTests {
    @MainActor private struct World {
        let browser: Browser
        /// The page in front, one of yours: x.com.
        let x: Tab
        let other: Tab
        let session: Agents.Session

        /// Mail you hand to Claude as it was: on for these, put back after.
        let consent: Any?

        init(cli: String = "claude") {
            consent = Store.settings.object(forKey: MailConsent.agentsKey)
            Store.settings.set(true, forKey: MailConsent.agentsKey)
            browser = Browser(windowID: UUID())
            x = Tab(bench: true)
            x.restore(url: URL(string: "https://x.com/home")!, title: "Home / X")
            other = Tab(bench: true)
            other.restore(url: URL(string: "https://news.example.test/")!, title: "News")
            browser.lay([x, other])
            browser.activeID = x.id
            browser.prefs.agentsAsking = .auto
            let id = "chat-ask-" + UUID().uuidString
            Agents.shared.benchTask(id, state: .running)
            session = Agents.shared.session(id)!
            session.cli = cli
        }

        func call(_ verb: String, _ request: [String: Any] = [:]) -> (handled: Bool, said: [String: Any]) {
            var said: [String: Any] = [:]
            var full = request
            full["session"] = session.id
            let handled = Bench().mailAsks(AgentCall(bench: Bench(), verb: verb, request: full, browser: browser) { said = $0 })
            return (handled, said)
        }

        /// Nothing of the chat's question is on x.com.
        func untouched(_ tab: Tab) -> Bool {
            tab.permit == nil && tab.guest == nil && tab.handoff == nil && tab.unread == nil && tab.answer == nil
        }

        var asked: [AgentNotices.Asked] {
            AgentNotices.shared.asked.filter { $0.info["chat"] == session.id }
        }

        func dispose() {
            session.permit = nil
            Store.settings.set(consent, forKey: MailConsent.agentsKey)
            for tab in browser.everyTab { tab.permit = nil; tab.handoff = nil; tab.close() }
        }
    }

    private func denying(_ body: () async throws -> Void) async rethrows {
        let kept = AgentNotices.shared.testPermission
        AgentNotices.shared.testPermission = .denied
        defer { AgentNotices.shared.testPermission = kept }
        try await body()
    }

    private func synced(_ w: World) throws -> (AssistantApprovals.Record, AssistantApprovalRecords.Request) {
        let permit = try #require(w.session.permit)
        // Publish directly so this unit test needs no account or APNs access.
        AssistantApprovals.shared.opened(chat: w.session, permit, by: .init(id: "local.external", name: "Claude", local: true))
        let record = try #require(AssistantApprovals.shared.current(tab: nil, session: permit.session))
        return (record, try AssistantApprovalRecords.Request(
            id: record.id, account: "account", mac: "mac", assistant: record.assistant, session: record.session,
            tab: "chat:" + w.session.id, permit: permit.key, title: record.title, lines: record.lines, expires: record.expires))
    }

    @Test func aSyncedChatAnswerSettlesOnceAndClearsTheMacNotice() throws {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search", ["query": "private search words"])
        let (record, request) = try synced(w)
        #expect(record.place == .chat(w.session.id))
        #expect(!record.lines.joined().contains("private search words"))
        AssistantApprovals.shared.answerFromSync(request, yes: true)
        #expect(w.session.mailReading && w.session.permit == nil)
        #expect(AssistantApprovals.shared.records[record.id]?.state == .approved)
        #expect(AgentNotices.shared.cleared.contains("agent.permit." + w.session.id))
        w.session.mailReading = false
        AssistantApprovals.shared.answerFromSync(request, yes: true)
        #expect(!w.session.mailReading)
    }

    @Test func renamingTheChatDoesNotInvalidateItsPendingAnswer() throws {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search")
        let (_, request) = try synced(w)
        w.session.title = "Renamed travel plans"
        AssistantApprovals.shared.answerFromSync(request, yes: true)
        #expect(w.session.permit == nil && w.session.mailReading)
    }

    @Test func aStaleSyncedAnswerCannotAnswerAReplacement() throws {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search")
        let (record, request) = try synced(w)
        w.session.permit = AgentPermit(kind: .mailChange(label: "Archive", act: "archive"), session: w.session.id, detail: "")
        AssistantApprovals.shared.answerFromSync(request, yes: true)
        #expect(!w.session.mailReading && w.session.permit != nil)
        AssistantApprovals.shared.left(session: w.session.id)
        #expect(AssistantApprovals.shared.records[record.id]?.state == .skipped)
    }

    @Test func openingAQuestionMarksItOnceAndKeepsItAnswerable() throws {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search")
        let (record, request) = try synced(w)
        AssistantApprovals.shared.seen(.chat(w.session.id), key: "another-question")
        #expect(AssistantApprovals.shared.records[record.id]?.seen == false)
        AssistantApprovals.shared.seen(.chat(w.session.id), key: request.permit)
        AssistantApprovals.shared.seen(.chat(w.session.id), key: request.permit)
        #expect(AssistantApprovals.shared.records[record.id]?.seen == true)
        #expect(AssistantApprovals.shared.records[record.id]?.state == .open)
        AssistantApprovals.shared.answerFromSync(request, yes: false)
        #expect(w.session.permit == nil)
        #expect(AssistantApprovals.shared.records[record.id]?.state == .denied)
    }

    @Test func openingAChatQuestionOnItsFallbackTabKeepsItsChatPlace() throws {
        let w = World(cli: "external"); defer { w.dispose() }
        _ = w.call("agent-mail-search")
        let (record, _) = try synced(w)
        w.x.permit = w.session.permit
        AssistantApprovals.shared.seen(on: w.x)
        #expect(AssistantApprovals.shared.records[record.id]?.seen == true)
        #expect(AssistantApprovals.shared.records[record.id]?.state == .open)
        #expect(w.session.permit != nil)
    }

    @Test func everyQuestionHasItsPlace() {
        func place(_ kind: AgentPermit.Kind, amount: String = "") -> AgentPermit.Place {
            AgentPermit(kind: kind, session: "s", detail: "", amount: amount).place
        }
        #expect(place(.mailRead) == .chat)
        #expect(place(.mailChange(label: "Archive", act: "archive")) == .chat)
        #expect(place(.mailSite(host: "a.io")) == .chat)
        #expect(place(.press(label: "Like", ref: "e1")) == .page)
        #expect(place(.press(label: "Pay", ref: "e1"), amount: "$12.00") == .send)
        #expect(place(.sendMail(to: "Ann", mail: "k")) == .send)
        #expect(place(.sendMessage(to: "Ann")) == .send)
        #expect(place(.computer) == .mac)
        #expect(place(.use) == .page)
        // Only what can be taken back gets buttons in the notification.
        for kind: AgentPermit.Kind in [.sendMail(to: "Ann", mail: "k"), .sendMessage(to: "Ann"), .computer, .press(label: "Pay", ref: "e")] {
            #expect(AgentNotices.permitCategory(kind) == nil)
        }
    }

    @Test func aMailQuestionLeavesTheTabInFrontAlone() {
        let w = World(); defer { w.dispose() }
        let first = w.call("agent-mail-search", ["query": "boarding pass"])
        #expect(first.handled && first.said["asking"] as? Bool == true)
        #expect(first.said["chat"] as? String == w.session.id)
        #expect(first.said["tab"] == nil)
        #expect(w.untouched(w.x))
        #expect(w.session.permit?.kind == .mailRead)
        #expect(w.session.state == .waiting)
        let note = w.asked.last
        #expect(note?.category == "agent.mail.read")
        #expect(note?.id == "agent.permit.\(w.session.id)")
        #expect(note?.body.hasPrefix("Search your mail?") == true)
        #expect(note?.subtitle.hasSuffix("once for this chat") == true)
        #expect(note?.info["permit"] == "mail.read")
    }

    @Test func theNotificationsButtonAnswersOnceAndTheCallGoesOn() {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search", ["query": "boarding pass"])
        let notes = w.asked.count
        // A button for another question, or a later one, does nothing.
        AgentNotices.answer(AgentNotices.permitYes, chat: w.session.id, key: "mail.change:archive")
        #expect(w.session.permit != nil && !w.session.mailReading)
        AgentNotices.answer(AgentNotices.permitYes, chat: w.session.id, key: "mail.read")
        #expect(w.session.permit == nil && w.session.mailReading)
        #expect(AgentNotices.shared.cleared.contains("agent.permit.\(w.session.id)"))
        #expect(w.session.state != .waiting)
        // Another tab in front meanwhile: the call that comes again goes on, asked nothing.
        w.browser.activeID = w.other.id
        #expect(!w.call("agent-mail-search", ["query": "boarding pass"]).handled)
        #expect(w.asked.count == notes)
        #expect(w.untouched(w.x) && w.untouched(w.other))
    }

    @Test func notNowIsHeardOnce() {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-triage")
        AgentNotices.answer(AgentNotices.permitNo, chat: w.session.id, key: "mail.read")
        let refused = w.call("agent-mail-triage")
        #expect(refused.handled)
        #expect((refused.said["error"] as? String)?.contains("not now") == true)
        #expect(!w.session.mailReading)
        // Heard once: asked again later, it is a question again.
        #expect(w.call("agent-mail-triage").said["asking"] as? Bool == true)
    }

    @Test func oneQuestionAChatAtATime() {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search", ["query": "x"])
        let next = w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"])
        #expect(next.said["asking"] as? Bool == true)
        // The first stays; the change waits for it.
        #expect(w.session.permit?.kind == .mailRead)
        Agents.shared.answer(chat: w.session.id, yes: true)
        _ = w.call("agent-mail-act", ["act": "archive", "thread": "me@example.com|t1"])
        #expect(w.session.permit?.kind == .mailChange(label: "Archive", act: "archive"))
        #expect(w.asked.last?.category == "agent.mail.change")
    }

    @Test func withoutNotificationsTheCornerHoldsIt() async {
        await denying {
            let w = World(); defer { w.dispose() }
            _ = w.call("agent-mail-search", ["query": "x"])
            await AgentNotices.shared.asking?.value
            // No column pulled out, nothing on x.com: the window's corner.
            #expect(w.browser.chatShown == nil)
            #expect(w.asked.isEmpty)
            #expect(w.untouched(w.x))
            #expect(Agents.shared.cornered(in: w.browser) == .chat(w.session.id))
            // The column out with that chat: its field says it, the corner doesn't.
            w.browser.chatOpen = true
            w.browser.chatShown = w.session.id
            #expect(Agents.shared.cornered(in: w.browser) != .chat(w.session.id))
            w.browser.chatOpen = false
            w.browser.chatShown = nil
            Agents.shared.answer(chat: w.session.id, yes: true)
            #expect(Agents.shared.cornered(in: w.browser) != .chat(w.session.id))
        }
    }

    @Test func neverAskedMacOSIsAskedOnceAndTheNotificationComes() async {
        let kept = AgentNotices.shared.testPermission
        AgentNotices.shared.testPermission = .unasked
        defer { AgentNotices.shared.testPermission = kept }
        let w = World(); defer { w.dispose() }
        let asks = AgentNotices.shared.permissionAsks
        _ = w.call("agent-mail-search", ["query": "x"])
        await AgentNotices.shared.asking?.value
        #expect(AgentNotices.shared.permissionAsks == asks + 1)
        #expect(w.asked.count == 1)
        #expect(w.browser.chatShown == nil)
        #expect(w.untouched(w.x))
    }

    @Test func anotherAppsAgentWithoutNotificationsAsksInTheCorner() async {
        await denying {
            let w = World(cli: "external"); defer { w.dispose() }
            _ = w.call("agent-mail-search", ["query": "x"])
            await AgentNotices.shared.asking?.value
            // Never on the page in front: the corner, answered there.
            #expect(w.untouched(w.x))
            #expect(Agents.shared.cornered(in: w.browser) == .chat(w.session.id))
            Agents.shared.answer(chat: w.session.id, yes: true)
            #expect(w.session.mailReading && w.session.permit == nil)
        }
    }

    @Test func aSendOnYourTabStandsInTheCornerNotOnThePage() {
        let w = World(); defer { w.dispose() }
        Agents.shared.ask(w.x, AgentPermit(kind: .sendMessage(to: "Ann"), session: w.session.id, detail: "", draft: "hi"))
        #expect(Agents.inCorner(w.x))
        #expect(Agents.shared.cornered(in: w.browser) == .tab(w.x.id))
        // A tab the agent works in keeps it at its foot.
        w.x.agent = w.session.id
        #expect(!Agents.inCorner(w.x))
        w.x.agent = nil
        Agents.shared.answer(w.x, yes: false)
        #expect(Agents.shared.cornered(in: w.browser) == nil)
    }

    @Test func theIPhoneHearsOnlyOnceYouAreAway() throws {
        let w = World(); defer { w.dispose(); AskPresence.shared.testAway = nil }
        AskPresence.shared.testAway = false
        _ = w.call("agent-mail-search", ["query": "x"])
        let permit = try #require(w.session.permit)
        AssistantApprovals.shared.opened(chat: w.session, permit, by: .init(id: "local.claude", name: "Claude", local: true))
        // At the Mac: held here.
        #expect(AssistantApprovals.shared.holdsAtMac)
        AskPresence.shared.testAway = true
        #expect(!AssistantApprovals.shared.holdsAtMac)
        Agents.shared.answer(chat: w.session.id, yes: true)
    }

    @Test func theQuestionSoundRisesAndNeverClips() {
        let samples = AskSound.samples()
        #expect(samples.count > 20_000)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.1 && peak < 1)
    }

    @Test func aSendAskedOnYourTabDoesNotLetTheAgentIn() {
        let w = World(); defer { w.dispose() }
        Agents.shared.ask(w.x, AgentPermit(kind: .sendMessage(to: "Ann"), session: w.session.id, detail: "", draft: "hi"))
        #expect(w.x.permit != nil)
        #expect(w.x.guest == nil)
    }

    @Test func aSendStaysOnTheTabItWasAskedOn() {
        let w = World(); defer { w.dispose() }
        Agents.shared.ask(w.x, AgentPermit(kind: .sendMessage(to: "Ann"), session: w.session.id, detail: "", draft: "hi"))
        #expect(w.session.state == .waiting)
        // Another tab in front before the answer: the call that comes
        // again still finds its question, and then its yes, on x.com.
        w.browser.activeID = w.other.id
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) === w.x)
        Agents.shared.answer(w.x, yes: true)
        #expect(w.session.state != .waiting)
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) === w.x)
        // Taken and sent: its Sending card gone too, nothing of it left,
        // so the next question goes to the tab in front.
        w.x.approved = nil
        w.x.sending = nil
        #expect(Agents.shared.askTab(for: w.session.id, in: w.browser) === w.other)
        #expect(w.x.guest == nil)
    }

    @Test func aPickAsksWithoutLettingTheAgentIn() {
        let w = World(); defer { w.dispose() }
        var said: [String: Any] = [:]
        Bench().handleAgentAsk(AgentCall(bench: Bench(), verb: "agent-ask",
                                         request: ["session": w.session.id, "question": "Which flight?", "options": ["AA 12", "UA 9"], "pick": true],
                                         browser: w.browser) { said = $0 })
        #expect(said["ok"] as? Bool == true)
        #expect(w.x.asker == w.session.id && w.x.askedBy == w.session.id)
        #expect(w.x.guest == nil && w.x.worker == nil)
        #expect(w.x.choices == ["AA 12", "UA 9"])
        Agents.shared.choose(w.x, "UA 9")
        #expect(w.x.asker == nil && w.x.handoff == nil)
        #expect(w.x.chosen == "UA 9")
    }

    @Test func aStoppedChatTakesItsQuestionAway() {
        let w = World(); defer { w.dispose() }
        _ = w.call("agent-mail-search", ["query": "x"])
        Agents.shared.leave(w.session)
        #expect(w.session.permit == nil)
        #expect(AgentNotices.shared.cleared.contains("agent.permit.\(w.session.id)"))
    }
}
