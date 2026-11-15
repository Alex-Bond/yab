import AppKit
import Testing
@testable import Fast

/// Candidate-only lifecycle checks. The recorder and clock do not prove
/// delivery, audible output, or a reporter's authenticated profile.
@MainActor
@Suite(.serialized)
struct AgentHandNoticeTests {
    @MainActor private final class World {
        let notices = AgentNotices.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        let other = Tab(bench: true)
        let session: Agents.Session
        let oldBrowser: Browser?
        let oldActive: Bool?
        let oldPermission: MailNotify.Permission
        let oldSchedule: (TimeInterval, DispatchWorkItem) -> Void
        let oldElsewhere: Any?
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        var extra: [Tab] = []

        init(active: Bool = true, permission: MailNotify.Permission = .allowed, cli: String = "claude") {
            oldBrowser = Agents.shared.browser
            oldActive = notices.testActive
            oldPermission = notices.testPermission
            oldSchedule = notices.scheduleReminder
            oldElsewhere = Store.settings.object(forKey: "agents.ask-elsewhere")
            notices.testActive = active
            notices.testPermission = permission
            let id = "hand-notice-" + UUID().uuidString
            Agents.shared.benchTask(id, state: .running)
            session = Agents.shared.session(id)!
            session.cli = cli
            tab.agent = id
            browser.lay([tab, other])
            browser.activeID = other.id
            browser.prefs.agentsAskElsewhere = false
            Agents.shared.browser = browser
            notices.scheduleReminder = { [weak self] delay, work in self?.scheduled.append((delay, work)) }
        }

        func count(_ event: String, _ id: String) -> Int {
            notices.handReceipts.filter { $0["event"] == event && $0["id"] == id }.count
        }
        func state(_ key: String) -> [String] { notices.handState()[key] as? [String] ?? [] }
        func handoff(_ reason: String = "Sign in", detail: String? = nil, choices: [String] = []) {
            Agents.shared.handoff(tab, reason: reason, detail: detail, choices: choices)
        }
        func dispose() {
            for page in browser.everyTab + extra { page.handoff = nil; page.permit = nil; page.close() }
            notices.testActive = oldActive
            notices.testPermission = oldPermission
            notices.scheduleReminder = oldSchedule
            Store.settings.set(oldElsewhere, forKey: "agents.ask-elsewhere")
            Agents.shared.browser = oldBrowser
        }
    }

    @Test(arguments: ["handoff", "permit", "folder", "direct", "browse"])
    func everyActualArrivalUsesTheNoticePath(_ path: String) throws {
        let w = World(); defer { w.dispose() }
        var page = w.tab
        switch path {
        case "handoff": w.handoff()
        case "permit": Agents.shared.ask(page, AgentPermit(kind: .use, session: w.session.id, detail: "For the task"))
        case "folder":
            let ask = FolderAsk(path: "/safe/Documents/example.txt", place: .documents, file: true, reason: "Read the example", task: "Example")
            Agents.shared.ask(page, AgentPermit(kind: .folder(ask), session: w.session.id, detail: ""))
        case "browse":
            page = try #require(Agents.shared.browse(URL(string: "about:blank")!, for: w.session.id))
        default: page.handoff = "Sign in"
        }
        let id = try #require(page.handoffNotice?.id)
        #expect(w.count("post", id) == 1)
        #expect(w.count("hold", id) == 1)
        #expect(w.count("sound", id) == 1)
        #expect(w.count("scheduled", id) == 1)
        #expect(w.scheduled.last?.0 == 180)
        page.handoff = nil
        #expect(!w.state("held").contains(id))
        #expect(!w.state("reminders").contains(id))
    }

    @Test func sameAskDoesNotRingBounceDeliverOrRescheduleTwice() throws {
        let w = World(active: false); defer { w.dispose() }
        w.handoff()
        let hand = try #require(w.tab.handoffNotice)
        w.handoff()
        let same = w.tab.handoff
        w.tab.handoff = same
        #expect(w.tab.handoffNotice == hand)
        #expect(w.count("post", hand.id) == 1)
        #expect(w.count("say", hand.id) == 1)
        #expect(w.count("bounce", hand.id) == 1)
        #expect(w.count("scheduled", hand.id) == 1)
        #expect(w.notices.asked.filter { $0.info["hand"] == hand.id }.count == 1)
        w.scheduled[0].1.perform()
        #expect(w.count("reminder", hand.id) == 1)
        #expect(w.notices.asked.last?.subtitle.contains("Waiting 3 min") == true)
        w.tab.handoff = nil
        #expect(w.notices.cleared.contains(hand.id))
        #expect(!w.state("held").contains(hand.id))
    }

    @Test func aBannerAfterTheWindowsSoundComesQuietAndOnlyTheReminderRings() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(w.count("sound", id) == 1)
        w.notices.testActive = false
        w.notices.wentBehind()
        #expect(w.notices.asked.last { $0.info["hand"] == id }?.quiet == true)
        w.scheduled[0].1.perform()
        let reminder = try #require(w.notices.asked.last { $0.info["hand"] == id })
        #expect(reminder.subtitle.contains("Waiting 3 min"))
        #expect(!reminder.quiet)
    }

    @Test func aBannerCarriesTheSoundSoTheCornerDoesNotPlayIt() throws {
        let w = World(active: false); defer { w.dispose() }
        w.handoff()
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(w.notices.asked.last { $0.info["hand"] == id }?.quiet == false)
        #expect(AskSound.heard(id))
    }

    @Test func theCornerAndTheQueueNameTheSameQuestion() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(Agents.shared.noticeID(.tab(w.tab.id), in: w.browser) == id)
        #expect(Agents.shared.noticeID(.chat("root"), in: w.browser) == "agent.permit.root")
    }

    @Test func deniedNotificationsStillCallWithSoundAndCancelTheReminder() throws {
        let w = World(active: false, permission: .denied); defer { w.dispose() }
        Agents.shared.ask(w.tab, AgentPermit(kind: .use, session: w.session.id, detail: ""))
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(w.count("sound", id) == 1)
        #expect(w.notices.asked.filter { $0.info["hand"] == id }.isEmpty)
        #expect(w.tab.handoff != nil && w.tab.permit != nil)
        Agents.shared.answer(w.tab, yes: false)
        #expect(w.scheduled[0].1.isCancelled)
        w.scheduled[0].1.perform()
        #expect(!w.state("held").contains(id))
        #expect(w.count("reminder", id) == 0)
    }

    @Test func theActiveWaitingTabStaysQuietForExternalAgentsToo() throws {
        let w = World(cli: "external"); defer { w.dispose() }
        w.browser.activeID = w.tab.id
        w.handoff()
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(w.count("sound", id) == 0)
        #expect(w.count("say", id) == 0)
        #expect(w.count("scheduled", id) == 1)
    }

    @Test func fullReasonAndPayloadChangesReplaceEvenAnIdenticalShortLabel() throws {
        let w = World(); defer { w.dispose() }
        w.handoff("Sign in. First account", detail: "First", choices: ["A"])
        let first = try #require(w.tab.handoffNotice)
        w.handoff("Sign in. Second account", detail: "First", choices: ["A"])
        let second = try #require(w.tab.handoffNotice)
        #expect(w.tab.handoff == "Sign in")
        #expect(first != second && w.notices.cleared.contains(first.id))
        w.handoff("Sign in. Second account", detail: "Second", choices: ["A"])
        let third = try #require(w.tab.handoffNotice)
        #expect(second != third)
        w.handoff("Sign in. Second account", detail: "Second", choices: ["B"])
        #expect(w.tab.handoffNotice != third)
        let permit = AgentPermit(kind: .sendMessage(to: "Synthetic"), session: w.session.id, detail: "", draft: "A")
        Agents.shared.ask(w.tab, permit)
        let draft = try #require(w.tab.handoffNotice)
        var changed = permit
        changed.draft = "B"
        Agents.shared.ask(w.tab, changed)
        #expect(w.tab.handoffNotice != draft)
        #expect(w.notices.cleared.contains(draft.id))
    }

    @Test func aChangedPermitSaysTheNewQuestionAfterItsHandoffIsReady() throws {
        let w = World(active: false); defer { w.dispose() }
        Agents.shared.ask(w.tab, AgentPermit(kind: .use, session: w.session.id, detail: "First task"))
        let first = try #require(w.tab.handoffNotice)
        let permit = AgentPermit(kind: .signIn(host: "synthetic.example.test", users: ["test@example.test"]),
                                 session: w.session.id, detail: "Second task")
        Agents.shared.ask(w.tab, permit)
        let next = try #require(w.tab.handoffNotice)
        let notices = w.notices.asked.filter { $0.info["hand"] == next.id }
        #expect(next != first)
        #expect(notices.count == 1)
        #expect(notices.first?.body == Agents.line(permit.question).0)
    }

    @Test func aFolderPhaseRewriteIsTheOriginalAsk() throws {
        let w = World(); defer { w.dispose() }
        let ask = FolderAsk(path: "/safe/Documents/example.txt", place: .documents, file: true, reason: "Read the example", task: "Example")
        Agents.shared.ask(w.tab, AgentPermit(kind: .folder(ask), session: w.session.id, detail: ""))
        let hand = try #require(w.tab.handoffNotice)
        // The public button follows FolderAccess.put without opening Settings
        // under Store.testing. The private recheck's checking phase is the
        // same normalized cause, even though its display line changes.
        FolderAccess.shared.openSettings(w.tab)
        var checking = ask
        checking.stage = .checking
        checking.sent = true
        checking.error = "Still closed"
        checking.checked = Date().addingTimeInterval(30)
        w.tab.permit = AgentPermit(kind: .folder(checking), session: w.session.id, detail: "")
        w.tab.handoff = checking.question
        #expect(w.tab.handoffNotice == hand)
        #expect(w.count("sound", hand.id) == 1)
        #expect(w.count("scheduled", hand.id) == 1)
    }

    @Test func copiedChildSharesTheCauseAndParentResolutionEndsBoth() throws {
        let w = World(); defer { w.dispose() }
        w.handoff(detail: "Only the source card's detail")
        let hand = try #require(w.tab.handoffNotice)
        let child = Tab(bench: true)
        child.agent = w.session.id
        child.inheritHandoff(from: w.tab)
        w.extra.append(child)
        #expect(child.handoffNotice == hand)
        #expect(child.permit == nil && child.allowed.isEmpty && child.approved == nil)
        #expect(child.handoffDetail == nil && child.choices.isEmpty)
        #expect(w.count("sound", hand.id) == 1)
        #expect(w.count("scheduled", hand.id) == 1)
        let step = UUID().uuidString
        w.session.items.put(ChatItem(id: step, kind: .tool, name: "handoff", text: "Waiting", state: .running), at: Date())
        Agents.shared.handBack(w.tab)
        #expect(w.session.items.first { $0.id == step }?.text == "done")
        #expect(child.handoff == nil && w.tab.handoff == nil)
        #expect(!w.state("held").contains(hand.id))
    }

    @Test func closingOneFamilyMemberKeepsTheQuestionUntilTheLastCloses() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        let hand = try #require(w.tab.handoffNotice)
        let child = Tab(bench: true)
        child.inheritHandoff(from: w.tab)
        w.extra.append(child)
        w.tab.close()
        #expect(w.state("held").contains(hand.id))
        child.close()
        #expect(!w.state("held").contains(hand.id))
        #expect(w.scheduled[0].1.isCancelled)
        // A late FolderAccess.check/put cannot resurrect a closed page.
        w.tab.handoff = "Checking Documents…"
        #expect(w.tab.handoffNotice == nil)
        #expect(w.count("post", hand.id) == 1)
    }

    @Test func sameIDReplacementTransfersTheAskWithoutDuplicatingOrClearingIt() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        let hand = try #require(w.tab.handoffNotice)
        w.browser.replaceBlank(w.tab, with: URL(string: "about:blank")!)
        let replacement = try #require(w.browser.tabs.first { $0.id == w.tab.id })
        #expect(replacement !== w.tab)
        #expect(replacement.handoffNotice == hand)
        w.tab.handoff = "A late old recheck"
        #expect(w.tab.handoffNotice == nil)
        #expect(w.count("post", hand.id) == 1)
        w.tab.close()
        #expect(w.state("held").contains(hand.id))
        #expect(w.count("scheduled", hand.id) == 1)
        replacement.handoff = nil
        #expect(!w.state("held").contains(hand.id))
    }

    @Test func aRetainedOldCallbackCanResolveOnlyItsTransferredAsk() throws {
        let w = World(); defer { w.dispose() }
        Agents.shared.ask(w.tab, AgentPermit(kind: .use, session: w.session.id, detail: ""))
        let hand = try #require(w.tab.handoffNotice)
        w.browser.replaceBlank(w.tab, with: URL(string: "about:blank")!)
        let replacement = try #require(w.browser.tabs.first { $0.id == w.tab.id })
        #expect(replacement.permit == nil) // Existing replacement authorization behavior.
        w.tab.handoff = "Late phase rewrite"
        #expect(replacement.handoffNotice == hand)
        w.tab.permit = nil
        Agents.shared.handBack(w.tab)
        #expect(replacement.handoff == nil)
        #expect(!w.state("held").contains(hand.id))
        Agents.shared.handoff(replacement, reason: "A new question")
        let fresh = replacement.handoffNotice
        w.tab.handoff = nil
        #expect(replacement.handoffNotice == fresh)
        #expect(replacement.handoff == "A new question")
    }

    @Test func stoppingTheSessionCancelsItsNoticeAndQuestionSoundIsTimeSensitive() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        let id = try #require(w.tab.handoffNotice?.id)
        #expect(Agents.shared.stop(w.session.id))
        #expect(!w.state("held").contains(id))
        #expect(w.scheduled[0].1.isCancelled)
        let content = AgentNotices.question(title: "Needs you", body: "Synthetic request", thread: "synthetic", info: [:])
        #expect(content.interruptionLevel == .timeSensitive)
    }

    @Test func anUnrelatedIdenticalQuestionDoesNotJoinTheCopiedFamily() throws {
        let w = World(); defer { w.dispose() }
        w.handoff()
        w.other.agent = w.session.id
        Agents.shared.handoff(w.other, reason: "Sign in")
        #expect(w.other.handoffNotice != w.tab.handoffNotice)
        Agents.shared.handBack(w.tab)
        #expect(w.other.handoff == "Sign in")
    }
}
