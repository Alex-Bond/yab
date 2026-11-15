import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

/// mail_send: what an agent may send is what is in the mail page already,
/// built as the page's own Send builds it, refused where that Send refuses,
/// and every permission mode approves one immutable outgoing operation
/// (MailAgent.outgoing, send; Agents.queueMail).
extension MailSyncAppTests {
    @MainActor private func engine(_ store: MailStore, _ gmail: MailGmail) -> MailCenter.Engine {
        MailCenter.Engine(account: "me@example.com", store: store, gmail: gmail, sync: MailSync(store: store, gmail: gmail))
    }

    @MainActor @Test func theReplyReadyUnderTheThreadGoesAsTheAgentWroteIt() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        let written = "\u{1F}Paid it today, sorry for the wait.\u{1F}sender"
        store.keepAhead("tb", message: store.sensed("tb")?.message ?? "", replies: [written, "Thanks, on it."])
        let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "me@example.com|tb"])
        let out = try #require(made, Comment(rawValue: why))
        #expect(out.draft.to.map(\.address) == ["billing@ledgerly.io"])
        #expect(out.draft.body == "Paid it today, sorry for the wait.")
        #expect(out.draft.subject == "Re: Invoice #4471 is past due")
        #expect(!out.draft.inReplyTo.isEmpty)
        #expect(out.to == "Ledgerly")
        #expect(out.detail.contains("To billing@ledgerly.io") && out.detail.contains("Re: Invoice #4471"))
        // A yes is for these words to these people: the same mail, the same
        // key; another word, another key.
        let (again, _) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb"])
        #expect(again?.key == out.key)
        let (other, _) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb", "body": "Paid."])
        #expect(other != nil && other?.key != out.key)

        let said = await MailAgent.send(out)
        #expect(said["sent"] as? Bool == true, "\(said)")
        #expect(fake.sent.count == 1)
        let raw = try #require(fake.sent.first)
        #expect(MailComposeTests.head(raw).contains("billing@ledgerly.io"))
        #expect(MailComposeTests.words(raw).hasPrefix("Paid it today, sorry for the wait."))
        // Out of the thread's place, the store's journal empty, the reply
        // it was gone from under the thread, the other one still there.
        #expect(store.pendingOps == 0 && store.draft(place: "reply:tb") == nil)
        let message = store.sensed("tb")?.message ?? ""
        let left = store.ahead("tb", message: message)
        #expect(!left.contains(written))
        #expect(left.contains("Thanks, on it."))
    }

    @MainActor @Test func thePersonsOwnDraftGoesAsTheyLeftItOrNotAtAll() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var mine = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        mine.id = "reply:tb"
        mine.body = "Card updated, charge it again please."
        store.save(mine)
        let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb"])
        #expect(made?.draft.body == "Card updated, charge it again please.", Comment(rawValue: why))
        let (changed, refused) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb", "body": "Something else."])
        #expect(changed == nil && refused.contains("their own draft"))
        #expect(fake.sent.isEmpty)
    }

    @MainActor @Test func nothingReadyOrSomethingLeftToFillGoesNowhere() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        let (none, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tc"])
        #expect(none == nil && why.contains("nothing is ready"))
        let (gap, left) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tc", "body": "See you {{date}}."])
        #expect(gap == nil && left.contains("{{date}}"))
        let (stranger, _) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "nope"])
        #expect(stranger == nil)
        let (bare, asked) = await MailAgent.outgoing([engine(store, gmail)], [:])
        #expect(bare == nil && asked.contains("needs a thread"))
        #expect(fake.sent.isEmpty)
    }

    @MainActor @Test func aNewMailMailDraftKeptGoesByItsID() async throws {
        let (store, gmail, fake) = world()
        try await MailSync(store: store, gmail: gmail).sync()
        store.save(MailDraft(id: "new:deck", to: [MailPerson(name: "Anna", address: "anna@fold.studio")], subject: "Deck v4", body: "Here it is."))
        let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["draft": "me@example.com|new:deck"])
        let out = try #require(made, Comment(rawValue: why))
        #expect(out.to == "Anna")
        // A kept draft goes as it is.
        let (changed, _) = await MailAgent.outgoing([engine(store, gmail)], ["draft": "new:deck", "body": "Other words."])
        #expect(changed == nil)
        let said = await MailAgent.send(out)
        #expect(said["sent"] as? Bool == true, "\(said)")
        #expect(fake.sent.count == 1 && store.draft("new:deck") == nil)
    }

    @Test func theCardAsksForThisMailAndTakesASend() {
        let permit = AgentPermit(kind: .sendMail(to: "Ledgerly", mail: "abc"), session: "s", detail: "To billing@ledgerly.io · Re: Invoice", draft: "Paid.")
        #expect(permit.question == "Send this mail to Ledgerly?")
        #expect(permit.key == "mail:abc")
        #expect(permit.answers.map(\.title) == ["Send"])
        #expect(permit.weighty)
        #expect(permit.ruleLabel == nil)
    }

    /// Every mode waits for Send, Bypass too: a sent mail can't come back
    /// (docs/casa.md, Consent).
    @MainActor @Test func everyModeWaitsForSendBypassToo() async throws {
        for mode in AgentAsking.allCases {
            let (store, gmail, fake) = world()
            seed(fake)
            try await MailSync(store: store, gmail: gmail).sync()
            let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb", "body": "Paid today."])
            let out = try #require(made, Comment(rawValue: why))
            let agents = Agents(), tab = Tab(bench: true), session = "mail-send-test"
            defer { tab.close() }

            let first = await agents.sendMail(out, in: tab, session: session, mode: mode)
            #expect(first["asking"] as? Bool == true)
            #expect(fake.sent.isEmpty && store.pendingOps == 0)
            let card = try #require(agents.mailRequests.first?.permit)
            #expect(card.kind == .sendMail(to: out.to, mail: out.key))
            #expect(card.detail == out.detail && card.draft == out.draft.body)
            agents.answerMail(try #require(agents.mailRequests.first?.id), yes: true)
            let sent = await agents.sendMail(out, in: tab, session: session, mode: mode)
            #expect(sent["sent"] as? Bool == true)
            #expect(tab.permit == nil && tab.approved == nil)
            #expect(fake.sent.count == 1)
            let raw = try #require(fake.sent.first)
            #expect(MailComposeTests.head(raw).contains("billing@ledgerly.io"))
            #expect(MailComposeTests.words(raw).hasPrefix("Paid today."))
            #expect(store.pendingOps == 0 && store.draft(place: "reply:tb") == nil)
        }
    }

    /// Several mails on one card: every address and word of each on it,
    /// one Send All sends them all, each through its own send.
    @MainActor @Test func severalMailsGoOnOneCardWithOneYes() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var outs: [MailAgent.Outgoing] = []
        for (thread, body) in [("tb", "Paid today."), ("ta", "Thursday works, see you then.")] {
            let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": thread, "body": body])
            outs.append(try #require(made, Comment(rawValue: why)))
        }
        let agents = Agents(), tab = Tab(bench: true), session = "mail-send-many"
        defer { tab.close() }

        let first = await agents.sendMails(outs, in: tab, session: session)
        #expect(first["asking"] as? Bool == true)
        #expect(fake.sent.isEmpty)
        let card = try #require(agents.mailRequests.first?.permit)
        #expect(card.kind == .sendMails(count: 2, mail: MailAgent.batchKey(outs)))
        #expect(card.question == "Send these 2 mails?")
        #expect(card.answers.map(\.title) == ["Send All"])
        #expect(card.weighty)
        for out in outs {
            #expect(card.draft.contains(out.detail))
            #expect(card.draft.contains(out.draft.body))
        }
        agents.answerMail(try #require(agents.mailRequests.first?.id), yes: true)
        let sent = await agents.sendMails(outs, in: tab, session: session)
        #expect(sent["error"] == nil)
        #expect(sent["count"] as? Int == 2)
        #expect(fake.sent.count == 2)
        #expect(tab.permit == nil && tab.approved == nil)
    }

    /// A yes for one set of mails is not a yes for another: a changed word in
    /// any of them asks again.
    @MainActor @Test func aChangedMailInTheSetAsksAgain() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        let one = try #require(await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb", "body": "Paid today."]).0)
        let two = try #require(await MailAgent.outgoing([engine(store, gmail)], ["thread": "ta", "body": "Thursday works."]).0)
        let changed = try #require(await MailAgent.outgoing([engine(store, gmail)], ["thread": "ta", "body": "Friday works."]).0)
        let agents = Agents(), tab = Tab(bench: true), session = "mail-send-many"
        defer { tab.close() }
        _ = await agents.sendMails([one, two], in: tab, session: session)
        agents.answerMail(try #require(agents.mailRequests.first?.id), yes: true)
        // The accepted immutable operation goes once even without a second
        // CLI call. Its receipt is not consent for different words.
        _ = await agents.sendMails([one, two], in: tab, session: session)
        let again = await agents.sendMails([one, changed], in: tab, session: session)
        #expect(again["asking"] as? Bool == true)
        #expect(fake.sent.count == 2)
    }

    @MainActor @Test func everyModeRejectsChangedExpiredAndOtherTasksApprovals() async throws {
        for mode in AgentAsking.allCases {
            let (store, gmail, fake) = world()
            seed(fake)
            try await MailSync(store: store, gmail: gmail).sync()
            let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb", "body": "Paid today."])
            let out = try #require(made, Comment(rawValue: why))
            let agents = Agents(), tab = Tab(bench: true), session = "mail-send-test"
            defer { tab.close() }
            for approval in [(session, "mail:changed", Date()),
                             ("another-task", "mail:" + out.key, Date()),
                             (session, "mail:" + out.key, Date().addingTimeInterval(-121))] {
                tab.approved = approval
                let waiting = await agents.sendMail(out, in: tab, session: session, mode: mode)
                #expect(waiting["asking"] as? Bool == true)
                #expect(agents.mailRequests.first?.permit.key == "mail:" + out.key)
                #expect(fake.sent.isEmpty)
            }
            agents.answerMail(try #require(agents.mailRequests.first?.id), yes: false)
            let refused = await agents.sendMail(out, in: tab, session: session, mode: mode)
            #expect((refused["error"] as? String)?.contains("not now") == true)
            #expect(refused["asking"] == nil && fake.sent.isEmpty)
        }
    }

    /// A thread named "account|id" is that account's, whichever account a
    /// dictionary gives first: two accounts can hold the same id (one
    /// mailbox connected twice, an IMAP server's numbers), and the reply
    /// went from the other one.
    @MainActor @Test func aThreadNamedForAnAccountIsThatAccountsWhoeverHoldsTheSameID() async throws {
        let (meStore, meGmail, meFake) = world()
        seed(meFake)
        try await MailSync(store: meStore, gmail: meGmail).sync()
        let (workStore, workGmail, workFake) = world()
        seed(workFake)
        try await MailSync(store: workStore, gmail: workGmail).sync()
        let me = engine(meStore, meGmail)
        let work = MailCenter.Engine(account: "work@example.com", store: workStore, gmail: workGmail,
                                     sync: MailSync(store: workStore, gmail: workGmail))
        for engines in [[me, work], [work, me]] {
            #expect(MailAgent.engine(holding: "work@example.com|tb", in: engines)?.engine.account == "work@example.com")
            #expect(MailAgent.engine(holding: "Me@Example.com|tb", in: engines)?.engine.account == "me@example.com")
            // An account named that isn't connected: none, never another's.
            #expect(MailAgent.engine(holding: "else@example.com|tb", in: engines) == nil)
            #expect(MailAgent.engine(holding: "work@example.com|tb", in: engines)?.id == "tb")
        }
        // mail_send keeps to it: the reply ready in work's thread goes from work.
        workStore.keepAhead("tb", message: workStore.sensed("tb")?.message ?? "", replies: ["\u{1F}From work.\u{1F}sender"])
        let (made, why) = await MailAgent.outgoing([me, work], ["thread": "work@example.com|tb"])
        let out = try #require(made, Comment(rawValue: why))
        #expect(out.engine.account == "work@example.com" && out.draft.body == "From work.")
    }

    /// mail_send's `at`: a local time, one with its zone, or words; never
    /// one already past.
    @Test func aSendLaterTimeIsReadAheadOfNow() throws {
        let now = Date()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let tomorrow = now.addingTimeInterval(86_400)
        let said = local.string(from: tomorrow)
        let at = try #require(MailAgent.when(said, now: now))
        #expect(abs(at.timeIntervalSince(tomorrow)) < 60)
        #expect(MailAgent.when(ISO8601DateFormatter().string(from: tomorrow), now: now) != nil)
        #expect(MailAgent.when(local.string(from: now.addingTimeInterval(-3600)), now: now) == nil)
        #expect(MailAgent.when("in 2 hours", now: now) != nil)
        #expect(MailAgent.when("whenever", now: now) == nil)
    }

    /// A reply mail_draft kept with Cc, Bcc and a file goes with all of
    /// them, and the card's line says each, and when it goes.
    @MainActor @Test func aKeptReplyGoesWithItsCcBccAndFiles() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var kept = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        kept.id = "reply:tb"
        kept.body = "Paid, Lee copied."
        kept.cc = [MailPerson(name: "Lee", address: "lee@42nd.dev")]
        kept.bcc = [MailPerson(name: "", address: "books@example.com")]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-\(UUID().uuidString).txt")
        try "Paid 120 EUR".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        kept.files = MailAttach.take([file], draft: kept.id, store: store)
        store.save(kept)
        #expect(MailAgent.kept([engine(store, gmail)], "me@example.com|reply:tb")?.draft.cc.map(\.address) == ["lee@42nd.dev"])

        let (made, why) = await MailAgent.outgoing([engine(store, gmail)], ["thread": "tb"])
        var out = try #require(made, Comment(rawValue: why))
        #expect(out.draft.cc.map(\.address) == ["lee@42nd.dev"] && out.draft.bcc.map(\.address) == ["books@example.com"])
        #expect(out.draft.files.map(\.name) == [file.lastPathComponent])
        #expect(out.detail.contains("Cc lee@42nd.dev") && out.detail.contains("Bcc books@example.com") && out.detail.contains("Files " + file.lastPathComponent))
        out.at = Date().addingTimeInterval(86_400)
        #expect(out.detail.contains("Sends "))
        out.at = nil
        let sent = await MailAgent.send(out)
        #expect(sent["sent"] as? Bool == true, "\(sent)")
        let raw = try #require(fake.sent.first)
        #expect(MailComposeTests.head(raw).contains("lee@42nd.dev"))
        #expect(raw.contains(file.lastPathComponent))
    }
}
