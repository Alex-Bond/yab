import Foundation
import Testing
@testable import MailCore
import MailCoreFakes

// The mail engine against a Gmail kept in memory (docs/mail.md, The
// engine): the first sync, what changed since, what you did going out after
// the list showed it, and Gmail's history running out.

@Suite(.serialized)
struct MailSyncTests {
    let now = Date()

    func world() -> (MailStore, MailGmail, FakeGmail) { MailWorld.make() }

    func seed(_ fake: FakeGmail) { MailWorld.seed(fake, now: now) }

    @Test func firstSyncBringsTheListAndTheBodies() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()

        let inbox = store.threads(label: "INBOX")
        #expect(inbox.map(\.id) == ["ta", "tb", "tc"])
        let anna = try #require(inbox.first)
        #expect(anna.subject == "Thursday works?")
        #expect(anna.unread)
        #expect(anna.count == 2)
        #expect(anna.lastIsMine)
        #expect(anna.people.map(\.address) == ["anna@fold.studio"])
        // The first screen's page of the inbox; after the newest of the
        // inbox and of sent, four mails two to a page, twice: the last month
        // whole, then the inbox and sixty days; then which of them carry
        // files (has:attachment): none.
        #expect(fake.calls.filter { $0 == "GET messages" }.count == 8)
        #expect(store.messages(thread: "ta").allSatisfy { $0.text != nil })
        #expect(store.messages(thread: "ta").first?.text == "Can we do the review Thursday? Deck v3 attached.")
        #expect(store.value("history") == "100")
        #expect(store.search("deck").map(\.id) == ["ta"])
        #expect(store.search("ledgerly").map(\.id) == ["tb"])
    }

    @Test func thenOnlyWhatChanged() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        fake.calls = []

        fake.add(.init(id: "d1", thread: "td", from: "Linear <no-reply@linear.app>", subject: "Your login code",
                       body: "Your code is 481902", at: now, labels: ["INBOX", "UNREAD"]))
        fake.history += 1
        fake.messages["b1"]?.labels.remove("INBOX")
        fake.records.append((fake.history, [], [], [("b1", ["INBOX"], false)]))
        fake.history += 1
        fake.messages["c1"] = nil
        fake.records.append((fake.history, [], ["c1"], []))
        try await sync.sync()

        #expect(store.threads(label: "INBOX").map(\.id) == ["td", "ta"])
        #expect(store.messages(thread: "td").first?.text == "Your code is 481902")
        #expect(store.message("c1") == nil)
        #expect(!fake.calls.contains("GET threads"))
        #expect(store.value("history") == String(fake.history))
    }

    @Test func archiveShowsAtOnceAndGoesOut() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()

        MailOps.act(.archive, thread: "tb", in: store)
        #expect(store.threads(label: "INBOX").map(\.id) == ["ta", "tc"])
        // A sync before the op went out doesn't bring it back.
        fake.add(.init(id: "b2", thread: "tb", from: "Ledgerly <billing@ledgerly.io>", subject: "Invoice #4471 is past due",
                       body: "Second notice.", at: now, labels: ["INBOX"]))
        try await sync.sync()
        #expect(!store.threads(label: "INBOX").map(\.id).contains("tb"))

        try await MailOps.flush(store, gmail: gmail)
        #expect(store.pendingOps == 0)
        #expect(fake.messages["b1"]?.labels.contains("INBOX") == false)
        #expect(fake.messages["b2"]?.labels.contains("INBOX") == false)
        try await sync.sync()
        #expect(!store.threads(label: "INBOX").map(\.id).contains("tb"))
    }

    @Test func undoBeforeItWent() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()

        let seq = MailOps.act(.read, thread: "ta", after: 5, in: store)
        #expect(store.thread("ta")?.unread == false)
        // Held for the undo: not due yet.
        try await MailOps.flush(store, gmail: gmail)
        #expect(!fake.calls.contains("POST threads/ta/modify"))
        #expect(MailOps.undo(seq, in: store))
        #expect(store.thread("ta")?.unread == true)
        #expect(store.pendingOps == 0)
    }

    @Test func aFailingOpWaitsAndGoesAgain() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()

        MailOps.act(.archive, thread: "tc", in: store)
        fake.failures = [503, 503, 503]
        try await MailOps.flush(store, gmail: gmail)
        #expect(store.pendingOps == 1)
        #expect(store.dueOps().isEmpty)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(60) })
        #expect(store.pendingOps == 0)
        #expect(fake.messages["c1"]?.labels.contains("INBOX") == false)
    }

    @Test func aRetryAfter429IsQuiet() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        fake.failures = [429]
        try await MailSync(store: store, gmail: gmail).sync()
        #expect(store.threads(label: "INBOX").count == 3)
    }

    @Test func aSlowDownIsWaitedOut() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        fake.tooFast["profile"] = 2
        try await MailSync(store: store, gmail: gmail).sync()
        #expect(fake.calls.filter { $0 == "GET profile" }.count == 3)
        #expect(store.threads(label: "INBOX").count == 3)
        // A 403 for anything else is a refusal, not a wait.
        fake.failures = [403]
        await #expect(throws: MailTrouble.status(403)) { try await gmail.profile() }
    }

    @Test func thePaceHalvesWhenRefusedAndComesBack() async throws {
        let pace = MailPace(rate: 600)
        await pace.cool(0)
        await pace.cool(0)
        // Refused together: halved once, then back over a minute.
        let halved = await pace.rate
        #expect(halved > 299 && halved < 305)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(await pace.rate > halved + 5)
        let start = Date()
        for _ in 0..<5 { await pace.take(30) }
        // 150 units at about 310 a second: the last waits about 0.4 s.
        #expect(Date().timeIntervalSince(start) > 0.3)
        #expect(MailGmail.cost("threads/t1", method: "GET") == 40)
        #expect(MailGmail.cost("messages/m1", method: "GET") == 20)
        #expect(MailGmail.cost("messages/send", method: "POST") == 100)
        #expect(MailGmail.cost("threads/t1/modify", method: "POST") == 10)
    }

    @Test func aFirstSyncGoesOnWhereItStopped() async throws {
        let (store, base, fake) = world()
        var gmail = base
        gmail.limitTries = 2
        seed(fake)
        fake.tooFast["messages/c1"] = 99
        await #expect(throws: MailTrouble.limited) { try await MailSync(store: store, gmail: gmail).sync() }
        #expect(store.value("boot") == "100")
        #expect(store.value("history") == nil)
        #expect(store.messageIDs() == ["a1", "a2", "b1"])

        fake.tooFast = [:]
        fake.calls = []
        fake.add(.init(id: "d1", thread: "td", from: "Linear <no-reply@linear.app>", subject: "Your login code",
                       body: "Your code is 481902", at: now, labels: ["INBOX", "UNREAD"]))
        try await MailSync(store: store, gmail: gmail).sync()
        // Not asked again: who the account is, and the mail already here.
        #expect(!fake.calls.contains("GET profile"))
        #expect(!fake.calls.contains("GET messages/a1"))
        #expect(fake.calls.filter { $0 == "GET messages/c1" }.count == 1)
        #expect(fake.calls.contains("GET messages/d1"))
        // History from where the first try began, so nothing between is lost.
        #expect(store.value("history") == "100")
        #expect(store.value("boot") == nil)
        #expect(store.threads(label: "INBOX").map(\.id) == ["td", "ta", "tb", "tc"])
    }

    @Test func aSlowDownIsntATry() async throws {
        let (store, base, fake) = world()
        var gmail = base
        gmail.limitTries = 2
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        MailOps.act(.archive, thread: "tc", in: store)
        fake.tooFast["*"] = 99
        await #expect(throws: MailTrouble.limited) { try await MailOps.flush(store, gmail: gmail) }
        #expect(store.pendingOps == 1)
        #expect(store.allOps().first?.tries == 0)
        #expect(store.dueOps().isEmpty)
        // Still archived here: nothing was given up.
        #expect(!store.threads(label: "INBOX").map(\.id).contains("tc"))
        fake.tooFast = [:]
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(61) })
        #expect(store.pendingOps == 0)
        #expect(fake.messages["c1"]?.labels.contains("INBOX") == false)
    }

    @Test func historyTooOldStartsAgain() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        MailOps.act(.archive, thread: "tc", after: 60, in: store)

        fake.add(.init(id: "e1", thread: "te", from: "Priya <priya@nair.dev>", subject: "Re: Senior iOS role",
                       body: "Who else joins?", at: now, labels: ["INBOX"]))
        fake.oldest = fake.history
        try await sync.sync()
        #expect(store.threads(label: "INBOX").map(\.id) == ["te", "ta", "tb"])
        // The op waiting for its undo survived the fresh start.
        #expect(store.pendingOps == 1)
    }

    @Test func aRefusedTokenStopsTheSync() async throws {
        let (store, gmail, fake) = world()
        fake.failures = [401]
        await #expect(throws: MailTrouble.signedOut) { try await MailSync(store: store, gmail: gmail).sync() }
    }

    @Test func aReplyToTheThread() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()

        // The last word was yours: the reply goes to who you wrote to.
        let draft = try #require(MailCompose.reply(to: store.messages(thread: "ta"), me: "me@example.com"))
        #expect(draft.to.map(\.address) == ["anna@fold.studio"])
        #expect(draft.subject == "Re: Thursday works?")
        #expect(draft.inReplyTo == "<a2@example.com>")
        #expect(draft.references.hasSuffix("<a2@example.com>"))

        var reply = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: "me@example.com"))
        #expect(reply.to.map(\.address) == ["billing@ledgerly.io"])
        reply.body = "Paid, thanks.\nDanke schön."
        reply.messageID = MailCompose.messageID(from: "me@example.com")
        let raw = MailCompose.raw(reply, from: MailPerson(name: "Sérafim", address: "me@example.com"))
        #expect(raw.contains("From: =?UTF-8?B?"))
        #expect(raw.contains("In-Reply-To: <b1@example.com>"))
        #expect(raw.contains("Content-Transfer-Encoding: base64"))
        let body = raw.components(separatedBy: "\r\n\r\n").last!.replacingOccurrences(of: "\r\n", with: "")
        // The words, then the mail they answer, quoted (MailComposeTests).
        let words = String(data: Data(base64Encoded: body)!, encoding: .utf8) ?? ""
        #expect(words.hasPrefix("Paid, thanks.\r\nDanke schön.\r\n\r\nOn "))
        #expect(words.hasSuffix("Ledgerly <billing@ledgerly.io> wrote:\r\n> Your card was declined."))
    }

    @Test func sendWaitsForItsUndoThenGoesOnce() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()

        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: "me@example.com"))
        draft.body = "Paid."
        draft.messageID = MailCompose.messageID(from: "me@example.com")
        store.save(draft)
        let seq = MailOps.act(.send, thread: draft.id, after: 5, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.isEmpty)
        // Two flushes at once, after the wait: one send.
        let later = { Date().addingTimeInterval(6) }
        async let one: Void = MailOps.flush(store, gmail: gmail, now: later)
        async let two: Void = MailOps.flush(store, gmail: gmail, now: later)
        _ = try await (one, two)
        #expect(fake.sent.count == 1)
        #expect(fake.messages["s1"]?.thread == "tb")
        #expect(store.draft(draft.id) == nil)
        #expect(!MailOps.undo(seq, in: store))
    }

    @Test func undoKeepsTheDraft() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: "me@example.com"))
        draft.body = "Paid."
        store.save(draft)
        let seq = MailOps.act(.send, thread: draft.id, after: 5, in: store)
        #expect(MailOps.undo(seq, in: store))
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(6) })
        #expect(fake.sent.isEmpty)
        #expect(store.draft(draft.id)?.body == "Paid.")
    }

    @Test func aTimedOutSendIsntSentTwice() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: "me@example.com"))
        draft.body = "Paid."
        draft.messageID = MailCompose.messageID(from: "me@example.com")
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        // Gmail took it, and the answer never came back.
        fake.dropAnswers = 3
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1)
        #expect(store.pendingOps == 1)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(60) })
        #expect(fake.sent.count == 1)
        #expect(store.pendingOps == 0)
        #expect(store.draft(draft.id) == nil)
    }

    @Test func snoozeUntilATime() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()

        MailOps.snooze("tb", until: now.addingTimeInterval(3600), why: "In an hour", in: store)
        #expect(!store.threads(label: "INBOX").map(\.id).contains("tb"))
        try await MailOps.flush(store, gmail: gmail)
        // Gmail: out of the inbox, under yab/Snoozed, made once.
        #expect(fake.labels.values.sorted() == ["yab/Snoozed"])
        #expect(fake.messages["b1"]?.labels == ["Label_1"])
        MailOps.snooze("tc", until: now.addingTimeInterval(7200), why: "Later", in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.labels.count == 1)

        #expect(MailOps.due(store, now: now.addingTimeInterval(1800)).isEmpty)
        #expect(MailOps.due(store, now: now.addingTimeInterval(3700)) == ["tb"])
        MailOps.wake("tb", in: store)
        #expect(store.thread("tb")?.labels.contains("INBOX") == true)
        #expect(store.thread("tb")?.unread == true)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.messages["b1"]?.labels == ["INBOX", "UNREAD"])
        #expect(store.snoozes().map(\.thread) == ["tc"])
    }

    @Test func snoozeUntilTheyWrite() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        MailOps.snooze("ta", until: nil, why: "Until Anna replies", in: store)
        try await MailOps.flush(store, gmail: gmail)
        try await sync.sync()
        #expect(MailOps.due(store).isEmpty)
        fake.add(.init(id: "a3", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Thursday works?",
                       body: "Great, see you then.", at: now, labels: ["INBOX", "UNREAD"]))
        try await sync.sync()
        #expect(MailOps.due(store) == ["ta"])
    }

    @Test func pkceAsTheRFCWritesIt() {
        // SHA-256 in base64url without padding, as Python's hashlib and
        // urlsafe_b64encode make it.
        #expect(MailClient.challenge("dBjftJeZ4CVP-mJ92K9qOnLuQUVrMNnd3kxwGqzzJ9k") == "fG3EZkV0gZUcn3LAUtHx_XdMQFolVhrlekLDhhxs4Vc")
        let pair = MailClient.pkce()
        #expect(pair.verifier.count == 43)
        #expect(MailClient.challenge(pair.verifier) == pair.challenge)
    }

    @Test func consentAsksForMailAndMeetingsAndOffline() {
        let url = MailClient(id: "id.apps.googleusercontent.com", secret: "")
            .consent(redirect: "http://127.0.0.1:5000/oauth", challenge: "c", state: "s")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["scope"] == "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events.readonly"
            + " https://www.googleapis.com/auth/calendar.calendarlist.readonly")
        #expect(items["include_granted_scopes"] == "true")
        #expect(items["access_type"] == "offline")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000/oauth")
    }

    /// Mail kept before the store had a column for Reply-To (MailStore.late):
    /// asked for again by its headers, a tenth of the quota at a time.
    @Test func olderMailGetsItsHeadersSlowly() async throws {
        let (store, gmail, fake) = world()
        let start = Date()
        for n in 0..<30 {
            fake.add(.init(id: "m\(n)", thread: "t\(n)", from: "Shop \(n) <news@shop\(n).example>", subject: "Order \(n)", body: "Shipped.",
                           at: start.addingTimeInterval(Double(n - 30) * 60), labels: ["INBOX"],
                           replyTo: n == 29 ? "Support <help@shop29.example>" : nil), record: false)
        }
        // Kept before the store had Reply-To: not known.
        store.put(fake.messages.values.compactMap { m in
            var message = MailGmail.message(fake.json(m, full: false), full: false)
            message?.replyTo = nil
            return message
        })
        #expect(store.unknownHeaders(limit: 100).count == 30)

        let sync = MailSync(store: store, gmail: gmail)
        try await sync.fillHeaders(now: start)
        // A minute's share at a tenth of the quota, newest first.
        #expect(fake.calls.filter { $0.hasPrefix("GET messages/") }.count == 24)
        #expect(store.message("m29")?.replyTo == [MailPerson(name: "Support", address: "help@shop29.example")])
        #expect(store.message("m28")?.replyTo == [])
        #expect(store.unknownHeaders(limit: 100) == (0..<6).reversed().map { "m\($0)" })
        // A second later: not even one more.
        try await sync.fillHeaders(now: start.addingTimeInterval(1))
        #expect(fake.calls.filter { $0.hasPrefix("GET messages/") }.count == 24)
        // Half a minute on, the rest; one gone from Gmail since is known to have none.
        fake.messages["m0"] = nil
        try await sync.fillHeaders(now: start.addingTimeInterval(30))
        #expect(store.unknownHeaders(limit: 100).isEmpty)
        #expect(store.message("m0")?.replyTo == [])
        // Nothing left to ask.
        let asked = fake.calls.count
        try await sync.fillHeaders(now: start.addingTimeInterval(120))
        #expect(fake.calls.count == asked)
    }

    // MARK: - the whole inbox, search by the server, bodies kept

    /// A mailbox of years: the inbox reaches two years back, archived mail
    /// too, and Anna's invoice of a year ago long archived.
    func years(_ fake: FakeGmail) {
        let day = 86_400.0
        fake.add(.init(id: "n1", thread: "tn", from: "Priya Nair <priya@nair.dev>", subject: "Offer letter", body: "Attached.",
                       at: now.addingTimeInterval(-3600), labels: ["INBOX", "UNREAD"]), record: false)
        fake.add(.init(id: "r1", thread: "tr", from: "Lena Brandt <lena@acme.com>", subject: "Recent, archived", body: "Twenty days ago.",
                       at: now.addingTimeInterval(-20 * day), labels: []), record: false)
        fake.add(.init(id: "h1", thread: "th", from: "Lena Brandt <lena@acme.com>", subject: "Older, archived", body: "Forty-five days ago.",
                       at: now.addingTimeInterval(-45 * day), labels: []), record: false)
        fake.add(.init(id: "x1", thread: "tx", from: "Lena Brandt <lena@acme.com>", subject: "Past sixty", body: "Seventy days ago.",
                       at: now.addingTimeInterval(-70 * day), labels: []), record: false)
        fake.add(.init(id: "o1", thread: "to", from: "Tim Okafor <tim@okafor.co>", subject: "Lease renewal", body: "Sign by the first.",
                       at: now.addingTimeInterval(-730 * day), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "v1", thread: "tv", from: "Anna Lindqvist <anna@fold.studio>", subject: "Invoice for March",
                       body: "The invoice for March is attached.", at: now.addingTimeInterval(-365 * day), labels: []), record: false)
    }

    @Test func firstSyncTakesAnInboxThreadTwoYearsOld() async throws {
        let (store, gmail, fake) = world()
        years(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        // The whole inbox, whatever its age: in Needs you, and nothing left to fill.
        #expect(store.thread("to")?.subject == "Lease renewal")
        #expect(store.value("inbox") == "whole")
        #expect(MailSplit.threads(.needs, in: store, policy: MailSplit.Policy(asks: true, days: nil)).map(\.0.id) == ["tn", "to"])
        // A week's window: the two-year-old one waits in Archive.
        #expect(MailSplit.threads(.older, in: store, policy: MailSplit.Policy(asks: true, days: 7)).map(\.0.id).contains("to"))
        // The last month whole, sixty days by their headers, nothing older outside the inbox.
        #expect(store.message("r1")?.text == "Twenty days ago.")
        #expect(store.message("h1") != nil && store.message("h1")?.text == nil)
        #expect(store.message("x1") == nil && store.message("v1") == nil)
        // Where the Mac's mail reaches back to: sixty days before now.
        let since = try #require(store.value("since").flatMap(Double.init))
        #expect(abs(since - (Date().timeIntervalSince1970 - 60 * 86_400)) < 60)
    }

    @Test func gmailFindsOldMailAndOpeningBringsItsBody() async throws {
        let (store, gmail, fake) = world()
        years(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        let query = MailQuery.parse("from:anna invoice")
        // On this Mac: nothing, so Gmail is asked.
        #expect(store.find(query).total == 0)
        fake.calls = []
        let found = try await sync.search(query)
        #expect(found.threads == ["tv"] && !found.more)
        // Listed, fetched by its headers, kept and marked; then which of
        // what came carries files.
        #expect(fake.calls == ["GET messages", "GET messages/v1", "GET messages"])
        let thread = try #require(store.thread("tv"))
        #expect(thread.backfilled && thread.subject == "Invoice for March")
        #expect(store.message("v1")?.text == nil)
        // At most 510 units: a list, 25 messages by their headers, and
        // which of them carry files.
        let units = fake.calls.map { call -> Int in
            let parts = call.split(separator: " ", maxSplits: 1).map(String.init)
            return MailGmail.cost(parts[1], method: parts[0])
        }.reduce(0, +)
        #expect(units == 30 && units <= 510)
        // Found now on this Mac too.
        #expect(store.find(query).threads.map(\.id) == ["tv"])
        // Opening it brings its body; opened, it is kept (MailStore.prune).
        try await sync.open(thread: "tv")
        #expect(store.message("v1")?.text == "The invoice for March is attached.")
        #expect(fake.calls.last == "GET threads/tv")
    }

    @Test func gmailGivesTwentyFiveAtATime() async throws {
        let (store, gmail, fake) = world()
        for n in 0..<30 {
            fake.add(.init(id: "q\(n)", thread: "tq\(n)", from: "Stripe <receipts@stripe.com>", subject: "Receipt \(n)", body: "Paid.",
                           at: now.addingTimeInterval(Double(-400 - n) * 86_400), labels: []), record: false)
        }
        fake.pageSize = 500
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        fake.calls = []
        let first = try await sync.search(MailQuery.parse("from:stripe receipt"))
        #expect(first.threads.count == 25 && first.more)
        #expect(first.threads.first == "tq0")
        #expect(fake.calls.filter { $0.hasPrefix("GET messages/") }.count == 25)
        // Asked again: the next ones not here, and no more after them.
        let next = try await sync.search(MailQuery.parse("from:stripe receipt"))
        #expect(next.threads.count == 30 && !next.more)
        #expect(fake.calls.filter { $0.hasPrefix("GET messages/") }.count == 30)
    }

    @Test func aLabelByItsNameIsLearnedOnce() async throws {
        let (store, gmail, fake) = world()
        fake.labels = ["Label_7": "Work/Clients"]
        fake.add(.init(id: "w1", thread: "tw", from: "Mark Chen <mark@northwind.vc>", subject: "Contract", body: "Signed.",
                       at: now.addingTimeInterval(-500 * 86_400), labels: ["Label_7"]), record: false)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        // Gmail's labels came with the sync (MailSync.keepLabels): the store
        // answers for this one, and finds nothing of its sixty days.
        let query = MailQuery.parse("label:work/clients")
        #expect(store.find(query).answered && store.find(query).threads.isEmpty)
        fake.calls = []
        #expect(try await sync.search(query).threads == ["tw"])
        #expect(!fake.calls.contains("GET labels"))
        #expect(store.find(query).threads.map(\.id) == ["tw"])
        // One made in Gmail since: learned once, by the search that names it.
        fake.labels["Label_8"] = "Receipts"
        fake.add(.init(id: "r1", thread: "tr", from: "Stripe <receipts@stripe.com>", subject: "Your receipt", body: "Paid.",
                       at: now.addingTimeInterval(-400 * 86_400), labels: ["Label_8"]), record: false)
        let receipts = MailQuery.parse("label:receipts")
        #expect(!store.find(receipts).answered)
        fake.calls = []
        #expect(try await sync.search(receipts).threads == ["tr"])
        #expect(fake.calls.first == "GET labels")
        fake.calls = []
        _ = try await sync.search(receipts)
        #expect(!fake.calls.contains("GET labels"))
    }

    /// Bodies kept ahead, in the background: not on battery, stopped by
    /// Gmail saying slow down, and going on where they stood after a
    /// restart, read from the store.
    @Test func bodiesComeAheadOnPowerAndGoOnAfterARestart() async throws {
        let (store, base, fake) = world()
        var gmail = base
        gmail.limitTries = 2
        // Thirty old threads in the inbox, by their headers only.
        for n in 0..<30 {
            fake.add(.init(id: "k\(n)", thread: "tk\(n)", from: "Person \(n) <p\(n)@example.org>", subject: "Question \(n)",
                           body: "Body \(n).", at: now.addingTimeInterval(Double(-100 - n) * 86_400), labels: ["INBOX"]), record: false)
        }
        do {
            let sync = MailSync(store: store, gmail: gmail)
            try await sync.sync()
        }
        // The newest of the inbox came whole with the first sync; the rest by headers.
        store.prune(keeping: [], before: now.addingTimeInterval(86_400))
        #expect(store.unbodied((0..<30).map { "tk\($0)" }).count == 30)
        let later = now.addingTimeInterval(3600)
        do {
            let sync = MailSync(store: store, gmail: gmail)
            await sync.set(plugged: { false })
            fake.calls = []
            try await sync.keepAhead(now: later)
            #expect(fake.calls.isEmpty)
            await sync.set(plugged: { true })
            // A minute's share: forty threads a minute, newest first; Gmail says slow down at the third.
            fake.tooFast["messages/k2"] = 99
            await #expect(throws: MailTrouble.limited) { try await sync.keepAhead(now: later) }
            #expect(store.message("k0")?.text == "Body 0." && store.message("k2")?.text == nil)
        }
        // After a restart: what is still missing, from the store.
        fake.tooFast = [:]
        fake.calls = []
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.keepAhead(now: later)
        #expect(store.unbodied((0..<30).map { "tk\($0)" }).isEmpty)
        #expect(!fake.calls.contains("GET messages/k0"))
        // Nothing missing: nothing asked.
        fake.calls = []
        try await sync.keepAhead(now: later.addingTimeInterval(120))
        #expect(fake.calls.isEmpty)
    }

    /// A store an older Yab synced, sixty days of it: the rest of its inbox
    /// comes a page of Gmail's list at a time, not on battery, stopped by
    /// Gmail saying slow down, and goes on from the page it stood at after
    /// a restart.
    @Test func anInboxSyncedBeforeComesWholeAPageAtATime() async throws {
        let (store, base, fake) = world()
        var gmail = base
        gmail.limitTries = 2
        fake.pageSize = 4
        for n in 0..<12 {
            fake.add(.init(id: "i\(n)", thread: "ti\(n)", from: "Person \(n) <p\(n)@example.org>", subject: "Old \(n)", body: "Long ago.",
                           at: now.addingTimeInterval(Double(-90 - n * 30) * 86_400), labels: ["INBOX"]), record: false)
        }
        // As 0.0.3 kept it: its history, none of these, no word of the whole inbox.
        store.set("me", "me@example.com")
        store.set("history", "100")
        let later = now.addingTimeInterval(3600)
        do {
            let sync = MailSync(store: store, gmail: gmail)
            await sync.set(plugged: { false })
            try await sync.fillInbox(now: later)
            #expect(fake.calls.isEmpty)
            await sync.set(plugged: { true })
            await sync.set(inboxPerMinute: 3)
            // Three a minute: the page's newest three, the page kept until all of it is here.
            try await sync.fillInbox(now: later)
            #expect(store.messageIDs() == ["i0", "i1", "i2"] && store.value("inbox.page") == nil)
            try await sync.fillInbox(now: later.addingTimeInterval(60))
            #expect(store.messageIDs().count == 4 && store.value("inbox.page") == "4")
            fake.tooFast["messages/i5"] = 99
            await #expect(throws: MailTrouble.limited) { try await sync.fillInbox(now: later.addingTimeInterval(120)) }
            #expect(store.value("inbox.page") == "4" && store.value("inbox") == nil)
        }
        // After a restart: on from the page it stood at, to the end.
        fake.tooFast = [:]
        fake.calls = []
        let sync = MailSync(store: store, gmail: gmail)
        await sync.set(plugged: { true })
        for minute in 1...4 { try await sync.fillInbox(now: later.addingTimeInterval(Double(minute) * 600)) }
        #expect(store.value("inbox") == "whole" && store.value("inbox.page") == nil)
        #expect(store.messageIDs() == Set((0..<12).map { "i\($0)" }))
        #expect(!fake.calls.contains("GET messages/i0"))
        #expect(MailSplit.counts(in: store, policy: MailSplit.Policy(asks: true, days: nil))[.needs] == 12)
        // Whole: nothing asked any more.
        fake.calls = []
        try await sync.fillInbox(now: later.addingTimeInterval(3600))
        #expect(fake.calls.isEmpty)
    }

    @Test func bodiesPastKeepingGoOnceADay() async throws {
        let (store, gmail, fake) = world()
        let day = 86_400.0
        for (n, age) in [10.0, 40, 50, 59].enumerated() {
            fake.add(.init(id: "p\(n)", thread: "tp\(n)", from: "Lena Brandt <lena@acme.com>", subject: "Plan \(n)",
                           body: "Words of plan \(n), written long before the zebra came.", at: now.addingTimeInterval(-age * day), labels: []),
                     record: false)
        }
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        for n in 0..<4 { try await sync.open(thread: "tp\(n)") }
        #expect(store.messageIDs(withBodies: true).count == 4)
        // Every one of them opened: they stay.
        #expect(store.prune(keeping: [], before: now.addingTimeInterval(-30 * day)) == 0)
        // Of the same mail where only tp1 was opened, a search found one,
        // and tp3 is among a split's newest: tp2 alone goes.
        let fresh = MailStore(file: MailStore.memory)
        fresh.set("me", "me@example.com")
        fresh.put(["p0", "p1", "p2", "p3"].compactMap { store.message($0) })
        fresh.opened("tp1")
        fresh.put([MailMessage(id: "s1", thread: "ts", from: MailPerson(name: "", address: "x@y.z"), subject: "Found",
                               date: now.addingTimeInterval(-90 * day), labels: [], replyTo: [], text: "Found by a search, zebra and all.")],
                  backfilled: true)
        #expect(fresh.search("zebra").count == 5)
        #expect(fresh.prune(keeping: ["tp3"], before: now.addingTimeInterval(-30 * day)) == 1)
        #expect(fresh.message("p0")?.text != nil && fresh.message("p1")?.text != nil && fresh.message("p3")?.text != nil)
        #expect(fresh.message("p2")?.text == nil && fresh.message("s1")?.text != nil)
        // Its words go back to what its head and snippet say.
        #expect(fresh.search("plan 2").map(\.id) == ["tp2"])
        #expect(!fresh.search("zebra").map(\.id).contains("tp2"))
        // Once a day.
        store.set("pruned", String(now.timeIntervalSince1970 - 2 * day))
        await sync.prune(now: now)
        #expect(store.value("pruned") == String(now.timeIntervalSince1970))
        await sync.prune(now: now.addingTimeInterval(3600))
        #expect(store.value("pruned") == String(now.timeIntervalSince1970))
    }

    @Test func bodiesGoAShareAtATime() async throws {
        let (store, gmail, _) = world()
        let day = 86_400.0
        store.put((0..<5).map { n in
            MailMessage(id: "q\(n)", thread: "tq\(n)", from: MailPerson(name: "Lena Brandt", address: "lena@acme.com"), subject: "Old \(n)",
                        date: now.addingTimeInterval(-Double(40 + n) * day), labels: [], replyTo: [], text: "Old words \(n).")
        })
        let sync = MailSync(store: store, gmail: gmail)
        await sync.set(pruneShare: 2)
        // The oldest two at a sync, the day's prune not done yet.
        await sync.prune(now: now)
        #expect(store.messageIDs(withBodies: true) == ["q0", "q1", "q2"])
        #expect(store.value("pruned") == nil)
        await sync.prune(now: now)
        #expect(store.messageIDs(withBodies: true) == ["q0"])
        // Fewer than a share left: done for the day.
        await sync.prune(now: now)
        #expect(store.messageIDs(withBodies: true).isEmpty)
        #expect(store.value("pruned") == String(now.timeIntervalSince1970))
    }

    @Test func theNextThreadsComeWholeWhileOneIsRead() async throws {
        let (store, gmail, fake) = world()
        years(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        #expect(store.message("h1")?.text == nil)
        await sync.prefetch(threads: ["th", "tn"])
        #expect(store.message("h1")?.text == "Forty-five days ago.")
        // One missing mail by itself, not its thread; nothing asked for what was here.
        #expect(fake.calls.contains("GET messages/h1") && !fake.calls.contains("GET threads/tn"))
    }

    @Test func aSplitIsReadAPageAtATime() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        store.put((0..<250).map { n in
            MailMessage(id: "m\(n)", thread: "t\(n)", from: MailPerson(name: "Person \(n)", address: "p\(n)@example.org"),
                        subject: "Question \(n)", date: now.addingTimeInterval(Double(-n) * 3 * 86_400), labels: ["INBOX"], replyTo: [])
        })
        // Every age, as paging is what this is about (a week's window keeps three).
        let every = MailSplit.Policy(asks: true, days: nil)
        #expect(MailSplit.counts(in: store, policy: MailSplit.Policy(asks: true, days: 7))[.needs] == 3)
        let page = MailSplit.threads(.needs, in: store, policy: every)
        #expect(page.count == MailSplit.page && page.first?.0.id == "t0" && page.last?.0.id == "t99")
        #expect(MailSplit.counts(in: store, policy: every)[.needs] == 250)
        #expect(MailSplit.threads(.needs, in: store, limit: 300, policy: every).count == 250)
        // A snoozed one is left out; one archived is out of the inbox.
        store.snooze(MailSnooze(thread: "t0", until: nil, why: "Later", message: "m0"))
        store.relabel(thread: "t1", add: [], remove: ["INBOX"])
        #expect(MailSplit.counts(in: store, policy: every)[.needs] == 248)
        #expect(MailSplit.threads(.needs, in: store, limit: 1, policy: every).first?.0.id == "t2")
        // What ⇧U, ⇧S and ⇧R narrow by, read with the rest, before a page is taken.
        store.relabel(thread: "t200", add: ["STARRED", "UNREAD"], remove: [])
        let facts = store.facts()
        #expect(facts.filter(\.starred).map(\.id) == ["t200"] && facts.filter(\.unread).map(\.id) == ["t200"])
        #expect(!facts.contains { $0.replied })
    }

    @Test func aQuietPaceSpendsItsBurstAtOnce() async {
        let pace = MailPace(rate: 100, burst: 200)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        for _ in 0..<5 { await pace.take(40) }
        // 200 units at once, then the even pace again.
        #expect(Date().timeIntervalSince(start) < 0.2)
        await pace.take(50)
        await pace.take(10)
        #expect(Date().timeIntervalSince(start) > 0.4)
    }

    @Test func peopleInHeaders() {
        #expect(MailPerson.list("\"Lindqvist, Anna\" <Anna@Fold.studio>, tim@okafor.co") ==
                [MailPerson(name: "Lindqvist, Anna", address: "anna@fold.studio"), MailPerson(name: "", address: "tim@okafor.co")])
    }
}
