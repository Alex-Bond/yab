import Foundation
import Testing
import UserNotifications
@testable import Fast
@testable import MailCore

// Mail's notifications (docs/mail.md, Notifications and the Dock badge):
// who is told about and who isn't, several at once as one, the badge in each
// mode, and macOS never asked by itself, whatever it said before.
@MainActor
@Suite(.serialized)
struct MailNotifyTests {
    let now = Date()

    func mail(_ id: String, thread: String, from: String, subject: String, _ text: String, ago: TimeInterval = 60,
              labels: Set<String> = ["INBOX", "UNREAD"], list: Bool = false) -> MailMessage {
        MailMessage(id: id, thread: thread, from: MailPerson.one(from)!, to: [MailPerson(name: "", address: "me@example.com")],
                    subject: subject, snippet: String(text.prefix(80)), date: now.addingTimeInterval(-ago), labels: labels,
                    listUnsubscribe: list, text: text)
    }

    /// One account's store with these mails, sorted by the rules as a sync
    /// leaves it.
    func store(_ mails: [MailMessage]) async -> MailStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notify-\(UUID().uuidString).sqlite")
        let store = MailStore(file: file)
        store.set("me", "me@example.com")
        store.put(mails)
        await MailSense.run(store, now: now, model: false) {}
        return store
    }

    /// A morning's new mail: a person who asks, a newsletter, a code, a
    /// thread where you had the last word, and one from before.
    func morning() async -> MailStore {
        await store([
            mail("a1", thread: "anna", from: "Anna Lindqvist <anna@fold.studio>", subject: "Thursday works?",
                 "Can we do the review Thursday? The deck is attached."),
            mail("d1", thread: "digest", from: "Weekly Digest <news@digest.io>", subject: "Ten links this week",
                 "Ten links worth your time.", list: true),
            mail("c1", thread: "code", from: "Acme <no-reply@acme.com>", subject: "Your sign-in code", "Your code is 604418."),
            mail("t1", thread: "tim", from: "Tim Okafor <tim@okafor.co>", subject: "Logo files", "Could you check the SVGs?", ago: 300),
            mail("t2", thread: "tim", from: "me@example.com", subject: "Re: Logo files", "Looks great, thanks!", ago: 120, labels: ["SENT"]),
            mail("o1", thread: "old", from: "Priya Nair <priya@nair.dev>", subject: "Senior iOS role", "Who else joins the next round?",
                 ago: 1200),
        ])
    }

    @Test func aPersonWhoAsksIsSaidAndNothingElse() async {
        let store = await morning()
        let fresh = MailNotify.fresh(in: store, mode: .needs, since: now.addingTimeInterval(-600), now: now)
        // Not the newsletter, the code, your own last word, nor what came before.
        #expect(fresh.map(\.thread) == ["anna"])
        let anna = fresh.first
        #expect(anna?.who == "Anna Lindqvist")
        #expect(anna?.subject == "Thursday works?")
        #expect(anna?.message == "a1")
        // The rules' line is the mail's own start.
        #expect(anna?.line == "Can we do the review Thursday? The deck is attached.")
    }

    @Test func onceForEachMailOfAThread() async {
        let store = await morning()
        let since = now.addingTimeInterval(-600)
        store.noteNotified([("anna", "a1")])
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).isEmpty)
        // Anna writes again in the same thread: said again, for that mail, once it is sorted.
        store.put([mail("a2", thread: "anna", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Thursday works?",
                        "Or Friday morning, if that's easier?", ago: 10)])
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).isEmpty)
        await MailSense.run(store, now: now, model: false) {}
        let again = MailNotify.fresh(in: store, mode: .needs, since: since, now: now)
        #expect(again.map(\.message) == ["a2"])
    }

    @Test func aMailTheRulesHaventReadWaits() async {
        let store = await morning()
        let since = now.addingTimeInterval(-600)
        let said = { MailNotify.fresh(in: store, mode: .needs, since: since, now: self.now).map(\.thread) }
        // Stored by a sync while another was being sorted: a code mail the
        // rules haven't read yet looks like a person's.
        store.put([mail("c2", thread: "code2", from: "Acme <no-reply@acme.com>", subject: "Your sign-in code", "Your code is 771204.", ago: 5),
                   mail("p9", thread: "slides", from: "Lena Ito <lena@ito.jp>", subject: "Slides", "Can you look at slide 4?", ago: 5)])
        #expect(!said().contains("code2"))
        #expect(!said().contains("slides"))
        // Read: the code in Other, never said; the person's mail said.
        await MailSense.run(store, now: now, model: false) {}
        #expect(!said().contains("code2"))
        #expect(said().contains("slides"))
    }

    @Test func aMutedThreadSaysNothing() async {
        let store = await morning()
        let since = now.addingTimeInterval(-600)
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now, muted: ["anna"]).isEmpty)
        // ⇧M: muted in its store, in no list and in no notification, Everything in Inbox's either.
        store.mute("anna")
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).isEmpty)
        #expect(!MailNotify.fresh(in: store, mode: .inbox, since: since, now: now).map(\.thread).contains("anna"))
    }

    @Test func everythingInInboxSaysListsAndCodesToo() async {
        let store = await morning()
        let fresh = MailNotify.fresh(in: store, mode: .inbox, since: now.addingTimeInterval(-600), now: now)
        #expect(Set(fresh.map(\.thread)) == ["anna", "digest", "code"])
        #expect(MailNotify.fresh(in: store, mode: .off, since: now.addingTimeInterval(-600), now: now).isEmpty)
    }

    @Test func anHourOldIsNotNews() async {
        let store = await store([
            mail("p1", thread: "late", from: "Mark Chen <mark@northwind.vc>", subject: "Numbers", "Could you send them?", ago: 2 * 3600),
            mail("p2", thread: "soon", from: "Lena Ito <lena@ito.jp>", subject: "Slides", "Can you look at slide 4?", ago: 30 * 60),
        ])
        // Notifications began a day ago; the Mac slept since.
        store.set("notify-since", String(now.addingTimeInterval(-86_400).timeIntervalSince1970))
        let since = MailNotify.since(store, now: now)
        #expect(since == now.addingTimeInterval(-MailNotify.window))
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).map(\.thread) == ["soon"])
        // Never asked before: from now on, nothing that is already here.
        let first = await self.store([mail("x1", thread: "x", from: "Lena Ito <lena@ito.jp>", subject: "Hi", "Are you around?")])
        #expect(MailNotify.fresh(in: first, mode: .needs, since: MailNotify.since(first, now: now), now: now).isEmpty)
    }

    @Test func moreThanThreeAreOne() {
        let notes = ["Anna Lindqvist", "Mark Chen", "Priya Nair", "Tim Okafor", "Lena Ito"].enumerated().map { n, who in
            MailNotify.Note(thread: "t\(n)", message: "m\(n)", who: who, subject: "Subject \(n)", line: "Line \(n)",
                            at: now.addingTimeInterval(Double(n)))
        }
        let one = MailNotify.posts(notes, account: "me@example.com", mode: .needs, accounts: 1)
        #expect(one.count == 1)
        #expect(one.first?.title == "5 new in Needs you")
        #expect(one.first?.body == "Lena Ito, Tim Okafor, Priya Nair and 2 more")
        #expect(one.first?.subtitle == "")
        #expect(one.first?.threads.count == 5)
        #expect(one.first?.batch == true)
        #expect(MailNotify.posts(notes, account: "me@example.com", mode: .inbox, accounts: 2).first?.title == "5 new in Inbox")
        #expect(MailNotify.posts(notes, account: "me@example.com", mode: .inbox, accounts: 2).first?.subtitle == "me@example.com")
        // Three are three, each saying who, the subject and the line.
        let three = MailNotify.posts(Array(notes.prefix(3)), account: "me@example.com", mode: .needs, accounts: 1)
        #expect(three.map(\.title) == ["Anna Lindqvist", "Mark Chen", "Priya Nair"])
        #expect(three.first?.subtitle == "Subject 0")
        #expect(three.first?.body == "Line 0")
        #expect(three.first?.id == "mail|me@example.com|t0")
        #expect(three.allSatisfy { !$0.batch })
    }

    @Test func theBadgeInEachMode() {
        #expect(MailNotify.label(.off, needs: 4, unread: 9) == nil)
        #expect(MailNotify.label(.needs, needs: 4, unread: 9) == "4")
        #expect(MailNotify.label(.unread, needs: 4, unread: 9) == "9")
        #expect(MailNotify.label(.needs, needs: 0, unread: 9) == nil)
        #expect(MailNotify.label(.unread, needs: 4, unread: 0) == nil)
    }

    /// One account whose store has one fresh mail from a person.
    func engine() async -> MailCenter.Engine {
        let store = await store([mail("a1", thread: "anna", from: "Anna Lindqvist <anna@fold.studio>", subject: "Thursday works?",
                                      "Can we do the review Thursday?")])
        store.set("notify-since", String(now.addingTimeInterval(-600).timeIntervalSince1970))
        let gmail = MailGmail(token: { "token" })
        return MailCenter.Engine(account: "notify-\(UUID().uuidString)@example.com", store: store, gmail: gmail,
                                 sync: MailSync(store: store, gmail: gmail))
    }

    /// A sender you blocked writes in a thread others write in: their mail
    /// goes to Trash as it comes, the thread stays in the inbox for the
    /// rest, and no notification says it; nor one in spam, nor theirs
    /// before Gmail's Trash came back.
    @Test func aBlockedSendersMailIsNeverSaid() async {
        let store = await morning()
        let since = now.addingTimeInterval(-600)
        store.noteNotified([("anna", "a1")])
        store.block("spam.example", at: now.addingTimeInterval(-3600))
        // Kept out, not in Trash yet (keepBlocked hasn't run): not said.
        store.put([mail("x1", thread: "anna", from: "Promo <deals@spam.example>", subject: "Re: Thursday works?", "Cheap pills?", ago: 20)])
        await MailSense.run(store, now: now, model: false) {}
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).isEmpty)
        // Into Trash as keepBlocked puts it: still nothing, the thread in the inbox for Anna's mail.
        MailOps.keepBlocked(store)
        #expect(store.message("x1")?.labels.contains("TRASH") == true)
        #expect(store.thread("anna")?.labels.contains("INBOX") == true)
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).isEmpty)
        #expect(MailNotify.fresh(in: store, mode: .inbox, since: since, now: now).filter { $0.thread == "anna" }.isEmpty)
        // Anna again: hers is said.
        store.put([mail("a3", thread: "anna", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Thursday works?", "Or Friday?", ago: 5)])
        await MailSense.run(store, now: now, model: false) {}
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).map(\.message) == ["a3"])
    }

    /// A stranger's mail the Mac's model may yet call a sales pitch waits for
    /// its reading (`holding`); everything else is said as soon as the
    /// rules have read it, the model or not (MailSense.run's `ruled`).
    @Test func whatTheRulesTellIsSaidFirst() async {
        let store = await morning()
        let since = now.addingTimeInterval(-600)
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now, holding: ["anna"]).isEmpty)
        #expect(MailNotify.fresh(in: store, mode: .needs, since: since, now: now).map(\.thread) == ["anna"])
        // Without the model, the rules' word comes with nothing held.
        actor Heard { var held: [Set<String>] = []; func add(_ one: Set<String>) { held.append(one) } }
        let heard = Heard()
        store.put([mail("p1", thread: "pitch", from: "Sam <sam@studio.example>", subject: "Your launch",
                        "We run a film studio doing launch distribution. Could we talk?", ago: 30)])
        await MailSense.run(store, now: now, model: false, ruled: { await heard.add($0) }) {}
        #expect(await heard.held == [[]])
    }

    /// Mail of yours nobody answered by its reminder: back in the inbox, and
    /// said in one line, as the new tab says it, its subject under it.
    @Test func aReminderComeDueIsSaid() async {
        let record = MailNotify.Record()
        let notify = MailNotify(center: record)
        notify.frontForced = false
        let engine = await engine()
        let store = engine.store
        let me = MailPerson(name: "Me", address: "me@example.com")
        store.put([MailMessage(id: "v1", thread: "venue", from: me, to: [MailPerson(name: "Mila Novak", address: "mila@novak.studio")],
                               subject: "Venue for the offsite", snippet: "The loft, please.", date: now.addingTimeInterval(-4 * 86_400),
                               labels: ["SENT"], rfcID: "<venue@example.com>", text: "The loft, please.")])
        store.follow(MailFollowup(thread: "venue", message: "<venue@example.com>", until: now.addingTimeInterval(-60),
                                  sent: now.addingTimeInterval(-4 * 86_400)))
        let came = MailFollowups.check(store, now: now)
        #expect(came.fired == ["venue"])
        await notify.reminded(engine, threads: came.fired)
        let said = record.posts.last
        #expect(said?.title == "Mila hasn’t answered" && said?.subtitle == "Venue for the offsite" && said?.body == "")
        #expect(said?.id == "mail|\(engine.account)|venue")
        // Off for the account, or mail in front: nothing.
        notify.setMode(.off, for: engine.account)
        await notify.reminded(engine, threads: ["venue"])
        #expect(record.posts.count == 1)
        notify.setMode(.needs, for: engine.account)
        notify.frontForced = true
        await notify.reminded(engine, threads: ["venue"])
        #expect(record.posts.count == 1)
    }

    @Test func macOSIsNeverAskedByItself() async {
        for state in [MailNotify.Permission.allowed, .denied, .unasked] {
            let record = MailNotify.Record()
            record.state = state
            let notify = MailNotify(center: record)
            notify.frontForced = false
            let engine = await engine()
            await notify.look(engine, now: now)
            #expect(record.asks == 0, "asked with \(state)")
            #expect(record.settingsOpened == 0)
            // Shown only where macOS allows it; said either way, so nothing
            // comes in a heap once it does.
            #expect(record.posts.map(\.title) == (state == .allowed ? ["Anna Lindqvist"] : []))
            #expect(engine.store.notified()["anna"] == "a1")
            #expect(notify.permission == state)
            await notify.look(engine, now: now)
            #expect(record.posts.count == (state == .allowed ? 1 : 0))
        }
    }

    /// macOS asked to let Yab show notifications from one place only:
    /// Allow… (MailNotifySystem.ask), never as an agent, an extension or
    /// mail posts one.
    @Test func onlyAllowAsksMacOS() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/Fast")
        var asking: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let code = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for (n, line) in code.components(separatedBy: "\n").enumerated() where line.contains(".requestAuthorization(options") {
                asking.append("\(name):\(n + 1)")
            }
        }
        #expect(asking.count == 1 && asking.first?.hasPrefix("MailNotify.swift:") == true, "macOS is asked from \(asking)")
    }

    @Test func allowAsksOnlyWhenPressed() async {
        let record = MailNotify.Record()
        record.state = .unasked
        let notify = MailNotify(center: record)
        await notify.allow()
        #expect(record.asks == 1)
        #expect(notify.permission == .allowed)
        // Said no before: only System Settings can turn them on again.
        let refused = MailNotify.Record()
        refused.state = .denied
        let other = MailNotify(center: refused)
        await other.allow()
        #expect(refused.asks == 0)
        #expect(refused.settingsOpened == 1)
        #expect(other.permission == .denied)
    }

    @Test func disconnectTakesItsNotificationsAway() async {
        let record = MailNotify.Record()
        let notify = MailNotify(center: record)
        notify.frontForced = false
        let engine = await engine()
        await notify.look(engine, now: now)
        #expect(record.posts.map(\.id) == ["mail|\(engine.account)|anna"])
        // Posted by a Yab before this one, and still in Notification Center.
        record.earlier = ["mail|\(engine.account)|batch", "mail|other@example.com|tim"]
        await notify.forget(engine.account)
        #expect(Set(record.removed) == ["mail|\(engine.account)|anna", "mail|\(engine.account)|batch"])
        // Another account's stay.
        #expect(await record.delivered() == ["mail|other@example.com|tim"])
    }

    @Test func nothingWhileMailIsInFront() async {
        let record = MailNotify.Record()
        let notify = MailNotify(center: record)
        notify.frontForced = true
        let engine = await engine()
        await notify.look(engine, now: now)
        #expect(record.posts.isEmpty)
        #expect(engine.store.notified()["anna"] == "a1")
        // Looked away: what came while you looked doesn't come after.
        notify.frontForced = false
        await notify.look(engine, now: now)
        #expect(record.posts.isEmpty)
    }

    @Test func anAnswerKnowsItsButton() {
        #expect(MailNotify.Act(action: UNNotificationDefaultActionIdentifier) == .open)
        #expect(MailNotify.Act(action: "done") == .done)
        #expect(MailNotify.Act(action: "remind") == .remind)
        #expect(MailNotify.Act(action: "reply") == .reply)
        #expect(MailNotify.Act(action: UNNotificationDismissActionIdentifier) == nil)
    }
}
