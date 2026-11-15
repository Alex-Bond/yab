import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// "Remind me if no reply" (docs/mail.md, Reminders if nobody answers): a
// mail of yours comes back to Needs you, unread, saying "No reply · 3d",
// when nobody answered it by its time; their answer ends the reminder,
// another mail of yours moves it as far on; a draft keeps its reminder
// until it goes, Send Later too; `yab mail flush` wakes what is due with Yab
// closed, and never what the app woke; nudges are written for threads that
// wait on someone else.
@Suite(.serialized)
struct MailFollowupTests {
    static let calendar = zone("Europe/Lisbon")

    static func zone(_ name: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: name)!
        return calendar
    }

    /// A day of September or October 2026, in Lisbon unless said:
    /// Monday is Sep 28.
    static func day(_ day: Int, _ hour: Int, minute: Int = 0, month: Int = 9, in calendar: Calendar = calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static let me = MailPerson(name: "Me", address: "me@example.com")
    static let mila = MailPerson(name: "Mila Novak", address: "mila@novak.studio")
    static let mine = "<yab-1@example.com>"

    func mail(_ id: String, thread: String = "venue", from: MailPerson, to: MailPerson, at: Date, labels: Set<String>,
              rfc: String = "") -> MailMessage {
        MailMessage(id: id, thread: thread, from: from, to: [to], subject: "Venue for the offsite", snippet: "Loft or boathouse?",
                    date: at, labels: labels, rfcID: rfc.isEmpty ? "<\(id)@example.com>" : rfc, text: "Loft or boathouse?")
    }

    /// Mila asked Monday at 10:00; your answer went at 10:30, and the
    /// thread was done (out of the inbox); a reminder in three days, on
    /// Thursday morning.
    func asked() -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put([mail("q1", from: Self.mila, to: Self.me, at: Self.day(28, 10), labels: []),
                   mail("a1", from: Self.me, to: Self.mila, at: Self.day(28, 10, minute: 30), labels: ["SENT"], rfc: Self.mine)])
        store.follow(MailFollowup(thread: "venue", message: Self.mine, until: Self.day(1, 9, month: 10), sent: Self.day(28, 10, minute: 30)))
        return store
    }

    func kinds(_ store: MailStore) -> [MailOp.Kind] { store.allOps().map(\.kind) }

    // MARK: - back, ended, moved

    @MainActor @Test func noReplyByTheDateBringsItBack() throws {
        let store = asked()
        // Wednesday: nothing yet; in Waiting, as any mail of yours nobody answered.
        #expect(MailFollowups.check(store, now: Self.day(30, 12), calendar: Self.calendar).isEmpty)
        #expect(MailSplit.of(try #require(store.thread("venue")), now: Self.day(30, 12)) == .waiting)
        // Thursday, a minute past nine: back in the inbox, unread, in Needs you.
        let change = MailFollowups.check(store, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar)
        #expect(change.fired == ["venue"])
        let thread = try #require(store.thread("venue"))
        #expect(thread.labels.contains("INBOX") && thread.unread)
        #expect(thread.followup?.fired == Self.day(1, 9, minute: 1, month: 10))
        #expect(MailSplit.of(thread, now: Self.day(1, 9, minute: 1, month: 10)) == .needs)
        #expect(MailSplit.threads(.needs, in: store, now: Self.day(1, 12, month: 10)).map(\.0.id) == ["venue"])
        #expect(MailSplit.threads(.waiting, in: store, now: Self.day(1, 12, month: 10)).isEmpty)
        // Said in words, as Waiting's are.
        #expect(MailFollowups.status(sent: thread.followup!.sent, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar) == "No reply · 3d")
        // Gmail hears it as an unarchive and an unread.
        #expect(kinds(store) == [.unarchive, .unread])
        // Looked at again, by this app or `yab mail flush`: never twice.
        #expect(MailFollowups.check(store, now: Self.day(1, 9, minute: 2, month: 10), calendar: Self.calendar).isEmpty)
        #expect(kinds(store) == [.unarchive, .unread])
        // The new tab's row says nobody answered, three days or not.
        let rows = MailCenter.noticed(in: store, account: Self.me.address, now: Self.day(1, 9, minute: 2, month: 10))
        #expect(rows.map(\.why) == [.noAnswer])
        #expect(Noticing.mail(rows, now: Self.day(1, 9, minute: 2, month: 10)).map(\.title) == ["Mila hasn’t answered"])
    }

    /// A reminder still waiting, as a row in Waiting or Sent says it before
    /// its time: by the calendar, in words.
    @Test func aReminderWaitingIsSaidInWords() {
        let calendar = Self.calendar
        let now = Self.day(28, 10)
        #expect(MailFollowups.pending(Self.day(28, 18), now: now, calendar: calendar) == "Remind today")
        #expect(MailFollowups.pending(Self.day(29, 9), now: now, calendar: calendar) == "Remind tomorrow")
        #expect(MailFollowups.pending(Self.day(1, 9, month: 10), now: now, calendar: calendar) == "Remind in 3d")
    }

    @Test func theirReplyEndsIt() {
        let store = asked()
        // A mail of hers from before your answer, kept late, ends nothing.
        store.put([mail("q0", from: Self.mila, to: Self.me, at: Self.day(28, 10, minute: 20), labels: [])])
        #expect(MailFollowups.check(store, now: Self.day(29, 12), calendar: Self.calendar).isEmpty)
        #expect(store.followup("venue") != nil)
        // Her answer on Tuesday: no reminder, nothing for Gmail.
        store.put([mail("q2", from: Self.mila, to: Self.me, at: Self.day(29, 15), labels: ["INBOX", "UNREAD"])])
        let change = MailFollowups.check(store, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar)
        #expect(change.ended == ["venue"] && change.fired.isEmpty)
        #expect(store.followup("venue") == nil)
        #expect(store.allOps().isEmpty)
        // Her answer needs you on its own.
        #expect(MailSplit.of(store.thread("venue")!, now: Self.day(1, 9, month: 10)) == .needs)
    }

    @Test func yourLaterMailMovesIt() throws {
        let store = asked()
        // Another of yours on Tuesday at 11 (from the phone, say): as far on, Friday morning.
        store.put([mail("a2", from: Self.me, to: Self.mila, at: Self.day(29, 11), labels: ["SENT"], rfc: "<phone-2@example.com>")])
        let change = MailFollowups.check(store, now: Self.day(29, 12), calendar: Self.calendar)
        #expect(change.moved == ["venue"])
        let moved = try #require(store.followup("venue"))
        #expect(moved.until == Self.day(2, 9, month: 10))
        #expect(moved.sent == Self.day(29, 11))
        #expect(moved.message == "<phone-2@example.com>")
        // Thursday morning is no longer its time; Friday's is.
        #expect(MailFollowups.check(store, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar).isEmpty)
        #expect(MailFollowups.check(store, now: Self.day(2, 9, minute: 1, month: 10), calendar: Self.calendar).fired == ["venue"])
        // Come due, then a nudge of yours sent from here: waiting again, as far on.
        var nudge = MailDraft(id: "reply:venue", thread: "venue", to: [Self.mila])
        nudge.messageID = "<yab-3@example.com>"
        MailFollowups.sent(nudge, thread: "venue", at: Self.day(2, 10, month: 10), in: store, calendar: Self.calendar)
        let again = try #require(store.followup("venue"))
        #expect(again.fired == nil && again.message == "<yab-3@example.com>")
        #expect(again.until == Self.day(5, 9, month: 10))
    }

    @Test func aReminderOnlyHoursOffMovesByTheHour() {
        let store = asked()
        store.follow(MailFollowup(thread: "venue", message: Self.mine, until: Self.day(28, 14, minute: 30), sent: Self.day(28, 10, minute: 30)))
        store.put([mail("a2", from: Self.me, to: Self.mila, at: Self.day(28, 11, minute: 30), labels: ["SENT"])])
        MailFollowups.check(store, now: Self.day(28, 12), calendar: Self.calendar)
        #expect(store.followup("venue")?.until == Self.day(28, 15, minute: 30))
    }

    @Test func putAwayMutedOrTrashedItIsntBroughtBack() throws {
        // Snoozed past its time: woken by it, the snooze taken.
        let store = asked()
        MailOps.snooze("venue", until: Self.day(5, 9, month: 10), why: "Next week", in: store)
        #expect(MailFollowups.check(store, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar).fired == ["venue"])
        #expect(store.snoozes().isEmpty)
        #expect(try #require(store.thread("venue")).labels.contains("INBOX"))
        // Come due in Trash: ended there, nothing brought back.
        let trashed = asked()
        _ = MailOps.trash(["venue"], in: trashed)
        let change = MailFollowups.check(trashed, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar)
        #expect(change.ended == ["venue"] && change.fired.isEmpty)
        // Muted: the same.
        let muted = asked()
        muted.mute("venue")
        #expect(MailFollowups.check(muted, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar).ended == ["venue"])
        // Brought back, then archived on the phone: done with.
        let archived = asked()
        MailFollowups.check(archived, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar)
        archived.relabel(thread: "venue", add: [], remove: ["INBOX"])
        #expect(MailFollowups.check(archived, now: Self.day(1, 10, month: 10), calendar: Self.calendar).ended == ["venue"])
    }

    @Test func doneWithOneBroughtBackAndTakenBack() throws {
        let store = asked()
        MailFollowups.check(store, now: Self.day(1, 9, minute: 1, month: 10), calendar: Self.calendar)
        let now = Self.day(1, 10, month: 10)
        // E: out of Needs you, and not into Waiting either; the reminder ends.
        let acted = MailOps.done(["venue"], in: store, now: now)
        #expect(acted.unfollowed.map(\.thread) == ["venue"] && acted.stoppedWaiting == ["venue"])
        #expect(store.followup("venue") == nil)
        #expect(MailSplit.of(try #require(store.thread("venue")), now: now) == nil)
        // ⌘Z: back in Needs you, its reminder as it was.
        MailOps.takeBack(acted, in: store)
        #expect(store.followup("venue")?.fired != nil)
        #expect(MailSplit.of(try #require(store.thread("venue")), now: now) == .needs)
    }

    @Test func doneRightAfterAnsweringKeepsTheReminder() throws {
        // You answer in the inbox and press E: the reminder is what brings it back.
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put([mail("q1", from: Self.mila, to: Self.me, at: Self.day(28, 10), labels: ["INBOX"]),
                   mail("a1", from: Self.me, to: Self.mila, at: Self.day(28, 10, minute: 30), labels: ["SENT"], rfc: Self.mine)])
        store.follow(MailFollowup(thread: "venue", message: Self.mine, until: Self.day(1, 9, month: 10), sent: Self.day(28, 10, minute: 30)))
        let acted = MailOps.done(["venue"], in: store, now: Self.day(28, 11))
        #expect(acted.unfollowed.isEmpty && store.followup("venue") != nil)
        // In Waiting, E is done waiting: the reminder ends with it.
        let waited = MailOps.done(["venue"], in: store, now: Self.day(30, 11))
        #expect(waited.unfollowed.map(\.thread) == ["venue"] && store.followup("venue") == nil)
    }

    // MARK: - edges of days and zones

    @Test func edgesAtMidnight() {
        // A mail of last night is a day old this morning.
        #expect(MailFollowups.status(sent: Self.day(28, 23, minute: 59), now: Self.day(29, 0, minute: 1), calendar: Self.calendar) == "No reply · 1d")
        #expect(MailFollowups.status(sent: Self.day(28, 0, minute: 1), now: Self.day(28, 23, minute: 59), calendar: Self.calendar) == "No reply · today")
        // Tomorrow until midnight, then today.
        #expect(MailFollowups.said(Self.day(29, 9), now: Self.day(28, 23, minute: 59), calendar: Self.calendar) == "tomorrow")
        #expect(MailFollowups.said(Self.day(29, 9), now: Self.day(29, 0, minute: 1), calendar: Self.calendar) == "at 9:00")
        #expect(MailFollowups.line(Self.day(1, 9, month: 10), now: Self.day(28, 10), calendar: Self.calendar) == "Remind me in 3 days if no reply")
        #expect(MailFollowups.said(Self.day(1, 10, month: 10), now: Self.day(28, 10), calendar: Self.calendar) == "Thu 10:00")
        // A send that goes in its undo window past midnight keeps "in 3 days" as chosen.
        let chosen = Self.day(1, 9, month: 10)
        #expect(MailFollowups.until(chosen, set: Self.day(28, 23, minute: 59), sent: Self.day(29, 0, minute: 0), calendar: Self.calendar) == chosen)
        // Due at its minute, not a second before.
        let store = asked()
        #expect(MailFollowups.check(store, now: Self.day(1, 8, minute: 59, month: 10).addingTimeInterval(59), calendar: Self.calendar).isEmpty)
        #expect(MailFollowups.check(store, now: Self.day(1, 9, month: 10), calendar: Self.calendar).fired == ["venue"])
    }

    @Test func acrossTimeZones() {
        let tokyo = Self.zone("Asia/Tokyo")
        let now = Self.day(28, 10)
        // "In 3 days" is that morning where the Mac is.
        let lisbon = MailLater.followups(now: now, calendar: Self.calendar).first { $0.label == "In 3 days" }?.at
        let there = MailLater.followups(now: now, calendar: tokyo).first { $0.label == "In 3 days" }?.at
        #expect(lisbon == Self.day(1, 9, month: 10))
        #expect(there == Self.day(1, 9, month: 10, in: tokyo))
        // A reminder is an instant: due when it comes, wherever the Mac is now.
        let store = asked()
        store.follow(MailFollowup(thread: "venue", message: Self.mine, until: there!, sent: Self.day(28, 10, minute: 30)))
        #expect(MailFollowups.check(store, now: there!.addingTimeInterval(-1), calendar: Self.calendar).isEmpty)
        #expect(MailFollowups.check(store, now: there!, calendar: Self.calendar).fired == ["venue"])
        // Days are counted on the Mac's own calendar: Lisbon's late evening
        // is Tokyo's next morning.
        let from = Self.day(28, 23, minute: 30), to = Self.day(29, 8)
        #expect(MailFollowups.keep(Self.day(1, 9, month: 10), from: from, to: to, calendar: Self.calendar) == Self.day(2, 9, month: 10))
        #expect(MailFollowups.keep(Self.day(1, 9, month: 10), from: from, to: to, calendar: tokyo) == Self.day(1, 9, month: 10))
        #expect(MailFollowups.status(sent: from, now: to, calendar: Self.calendar) == "No reply · 1d")
        #expect(MailFollowups.status(sent: from, now: to, calendar: tokyo) == "No reply · today")
    }

    @Test func overTheClockChangeTheMorningStaysNine() {
        // Lisbon goes back an hour early on Sunday, October 25, 2026.
        let friday = Self.day(23, 10, month: 10)
        let three = MailLater.followups(now: friday, calendar: Self.calendar).first { $0.label == "In 3 days" }?.at
        #expect(three == Self.day(26, 9, month: 10))
        #expect(Self.calendar.component(.hour, from: three!) == 9)
        // Saturday's reminder moved a day on across it: Sunday at nine, 25 hours on.
        let saturday = Self.day(24, 9, month: 10)
        let moved = MailFollowups.keep(saturday, from: Self.day(23, 8, month: 10), to: Self.day(24, 8, minute: 30, month: 10), calendar: Self.calendar)
        #expect(moved == Self.day(25, 9, month: 10))
        #expect(moved.timeIntervalSince(saturday) == 25 * 3600)
        #expect(MailFollowups.status(sent: Self.day(24, 23, month: 10), now: Self.day(25, 23, month: 10), calendar: Self.calendar) == "No reply · 1d")
    }

    // MARK: - the draft, sending, Send Later

    @Test func theChoicesAreHsWithInThreeDays() {
        let monday = MailLater.followups(now: Self.day(28, 10), calendar: Self.calendar)
        #expect(monday.map(\.label) == ["Later today", "Tomorrow morning", "In 3 days", "This weekend", "Next week"])
        #expect(monday.map(\.detail) == ["18:00", "Tue 9:00", "Thu 9:00", "Sat 9:00", "Mon 9:00"])
        // On a Wednesday evening, in three days is the weekend: said once.
        let wednesday = MailLater.followups(now: Self.day(30, 20), calendar: Self.calendar)
        #expect(wednesday.map(\.label) == ["Tomorrow morning", "In 3 days", "Next week"])
        // On Friday, In 3 days already means Monday, so Next week is omitted.
        let friday = MailLater.followups(now: Self.day(2, 10, month: 10), calendar: Self.calendar)
        #expect(friday.map(\.label) == ["Later today", "Tomorrow morning", "In 3 days"])
    }

    @Test func aDraftKeepsItsReminder() throws {
        let store = MailStore(file: MailStore.memory)
        var draft = MailDraft(id: "new:1", to: [Self.mila], subject: "Venue", body: "Loft or boathouse?")
        draft.remind = Self.day(1, 9, month: 10)
        draft.remindSet = Self.day(28, 10)
        store.save(draft)
        let kept = try #require(store.draft("new:1"))
        #expect(kept.remind == Self.day(1, 9, month: 10) && kept.remindSet == Self.day(28, 10))
        // Taken off: none, kept so.
        draft.remind = nil
        draft.remindSet = nil
        store.save(draft)
        #expect(store.draft("new:1")?.remind == nil)
        // An agent's reply ready with one keeps it as the store keeps replies.
        let stored = MailDesk.Ready.stored("Loft works.", everyone: true, remind: Self.day(1, 9, month: 10), set: Self.day(28, 10))
        let ready = MailDesk.Ready(stored: stored, by: "Written by Claude")
        #expect(ready.text == "Loft works." && ready.everyone == true)
        #expect(ready.remind == Self.day(1, 9, month: 10) && ready.remindSet == Self.day(28, 10))
        // Without one, as before.
        #expect(MailDesk.Ready.stored("Yes.", everyone: nil, remind: nil, set: nil) == "Yes.")
        #expect(MailDesk.Ready.stored("Yes.", everyone: false, remind: nil, set: nil) == MailDesk.Ready.stored("Yes.", everyone: false))
    }

    @Test func sendLaterKeepsItAsFarFromTheSend() {
        // "In 3 days" chosen Saturday morning (Tuesday 9:00), the mail set to go Monday at 8: Thursday.
        let until = MailFollowups.until(Self.day(29, 9), set: Self.day(26, 10), sent: Self.day(28, 8), calendar: Self.calendar)
        #expect(until == Self.day(1, 9, month: 10))
        // Sent now: as chosen.
        #expect(MailFollowups.until(Self.day(29, 9), set: Self.day(26, 10), sent: Self.day(26, 10, minute: 1), calendar: Self.calendar) == Self.day(29, 9))
        // Chosen for a time that has gone by when it goes: as long after the send.
        let late = MailFollowups.until(Self.day(26, 18), set: Self.day(26, 17), sent: Self.day(26, 17, minute: 30), calendar: Self.calendar)
        #expect(late == Self.day(26, 18))
        let gone = MailFollowups.until(Self.day(26, 18), set: Self.day(26, 17), sent: Self.day(26, 18, minute: 5), calendar: Self.calendar)
        #expect(gone > Self.day(26, 18, minute: 5))
    }

    @Test func sentWithItsReminderAMailOfItsOwnThread() async throws {
        let (store, gmail, fake) = world()
        store.set("me", Self.me.address)
        var draft = MailDraft(id: "new:2", to: [Self.mila], subject: "Venue", body: "Loft or boathouse?")
        draft.messageID = MailCompose.messageID(from: Self.me.address)
        // Whole seconds, as the store keeps times to the bit.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        draft.remind = now.addingTimeInterval(3 * 86_400)
        draft.remindSet = now
        store.save(draft)
        store.queueOp(.send, thread: draft.id)
        try await MailOps.flush(store, gmail: gmail)
        // Gone in a thread Gmail named; its reminder kept against it.
        let sent = try #require(fake.messages.values.first { $0.labels.contains("SENT") })
        let followup = try #require(store.followup(sent.thread))
        #expect(followup.message == draft.messageID)
        #expect(followup.until == draft.remind)
        #expect(store.draft("new:2") == nil)
        // A send that timed out and was found in Sent keeps its reminder too.
        var again = MailDraft(id: "new:3", to: [Self.mila], subject: "Lisbon", body: "Dates?")
        again.messageID = MailCompose.messageID(from: Self.me.address)
        again.remind = now.addingTimeInterval(86_400)
        again.remindSet = now
        store.save(again)
        fake.dropAnswers = 1
        let seq = store.queueOp(.send, thread: again.id)
        try await MailOps.flush(store, gmail: gmail)
        #expect(store.op(seq)?.tries == 1)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(30) })
        let lisbon = try #require(fake.messages.values.first { $0.subject == "Lisbon" })
        #expect(store.followup(lisbon.thread)?.message == again.messageID)
        #expect(fake.sent.count == 2)
    }

    // MARK: - with Yab closed

    /// A store and a Gmail of its own, on a host no other suite asks.
    func world(file: URL = MailStore.memory) -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "followup-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01)
        return (MailStore(file: file), gmail, fake)
    }

    func labels(_ fake: FakeGmail, _ thread: String) -> Set<String> {
        fake.messages.values.filter { $0.thread == thread }.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
    }

    @Test func flushWakesWhatIsDueWithYabClosedAndNeverTwice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("me@example.com.sqlite")
        let (app, gmail, fake) = world(file: file)
        // Whole seconds, as the store keeps times to the bit.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        // Mila's question, your answer (done, out of the inbox), and Lisbon's dates in the inbox.
        fake.add(.init(id: "q1", thread: "venue", from: "Mila Novak <mila@novak.studio>", subject: "Venue",
                       body: "Loft or boathouse?", at: now.addingTimeInterval(-4 * 86_400), labels: []), record: false)
        fake.add(.init(id: "a1", thread: "venue", from: "me@example.com", to: "mila@novak.studio", subject: "Re: Venue",
                       body: "The loft.", at: now.addingTimeInterval(-3 * 86_400), labels: ["SENT"], rfc: Self.mine), record: false)
        fake.add(.init(id: "l1", thread: "lisbon", from: "Mila Novak <mila@novak.studio>", subject: "Lisbon dates",
                       body: "Which week?", at: now.addingTimeInterval(-3600), labels: ["INBOX"]), record: false)
        try await MailSync(store: app, gmail: gmail).sync()
        // Lisbon put off for an hour, Gmail told; the venue's reminder due in two.
        MailOps.snooze("lisbon", until: now.addingTimeInterval(3600), why: "In an hour", in: app)
        try await MailOps.flush(app, gmail: gmail)
        #expect(!labels(fake, "lisbon").contains("INBOX"))
        app.follow(MailFollowup(thread: "venue", message: Self.mine, until: now.addingTimeInterval(7200),
                                sent: now.addingTimeInterval(-3 * 86_400)))
        #expect(MailLater.waiting([app]))

        // While the app runs it holds the wake lock: `yab mail flush` wakes nothing.
        let lockFile = folder.appendingPathComponent("wake.lock")
        let running = MailLock(lockFile)
        #expect(running.take())
        let agent = MailLock(lockFile)
        #expect(!agent.take())
        let later = now.addingTimeInterval(3 * 3600)
        let closed = MailStore(file: file)
        await MailLater.flush([("me@example.com", closed)], waking: agent.take(), now: later, gmail: { _ in gmail })
        #expect(closed.snoozes().map(\.thread) == ["lisbon"] && closed.followup("venue")?.fired == nil)

        // Yab quit: the lock is free, and the agent wakes both and tells Gmail.
        running.letGo()
        #expect(agent.take())
        await MailLater.flush([("me@example.com", closed)], waking: true, now: later, gmail: { _ in gmail })
        #expect(closed.snoozes().isEmpty)
        #expect(closed.followup("venue")?.fired == later)
        #expect(labels(fake, "lisbon").isSuperset(of: ["INBOX", "UNREAD"]))
        #expect(!labels(fake, "lisbon").contains(where: { $0.hasPrefix("Label_") }))
        #expect(labels(fake, "venue").isSuperset(of: ["INBOX", "UNREAD"]))
        #expect(closed.pendingOps == 0)
        let calls = fake.calls.count
        agent.letGo()

        // The app back: the same file, nothing to wake again, nothing sent twice.
        #expect(MailOps.wakeDue(app, now: later.addingTimeInterval(60)).isEmpty)
        #expect(MailFollowups.check(app, now: later.addingTimeInterval(60)).fired.isEmpty)
        #expect(app.pendingOps == 0)
        try await MailOps.flush(app, gmail: gmail)
        #expect(fake.calls.count == calls)
        #expect(MailSplit.of(try #require(app.thread("venue")), now: later) == .needs)
        #expect(!MailLater.waiting([app]))
    }

    @Test func twoAtOnceOneWakes() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-twice-\(UUID().uuidString).sqlite")
        let one = MailStore(file: file), other = MailStore(file: file)
        one.follow(MailFollowup(thread: "venue", message: Self.mine, until: Self.day(1, 9, month: 10), sent: Self.day(28, 10)))
        one.snooze(MailSnooze(thread: "lisbon", until: Self.day(29, 9), why: "Tomorrow", message: ""))
        // Both find them due; the first to mark each wakes it.
        #expect(one.fire("venue", at: Self.day(1, 10, month: 10)))
        #expect(!other.fire("venue", at: Self.day(1, 10, month: 10)))
        #expect(other.takeSnooze("lisbon") != nil)
        #expect(one.takeSnooze("lisbon") == nil)
        // Not due yet: not fired.
        other.follow(MailFollowup(thread: "deck", message: "", until: Self.day(5, 9, month: 10), sent: Self.day(28, 10)))
        #expect(!one.fire("deck", at: Self.day(1, 10, month: 10)))
    }

    // MARK: - mail_draft's remind_in

    @Test func remindInDaysOrWords() {
        let now = Self.day(28, 10)
        #expect(MailFollowups.remindIn(3, now: now, calendar: Self.calendar) == Self.day(1, 9, month: 10))
        #expect(MailFollowups.remindIn("3", now: now, calendar: Self.calendar) == Self.day(1, 9, month: 10))
        #expect(MailFollowups.remindIn("in 2 days", now: now, calendar: Self.calendar) == Self.day(30, 9))
        #expect(MailFollowups.remindIn("2 days", now: now, calendar: Self.calendar) == Self.day(30, 9))
        #expect(MailFollowups.remindIn(0.5, now: now, calendar: Self.calendar) == Self.day(28, 22))
        #expect(MailFollowups.remindIn("in 4 hours", now: now, calendar: Self.calendar) == Self.day(28, 14))
        for nothing: Any in [0, -2, "", "whenever", true, 400] {
            #expect(MailFollowups.remindIn(nothing, now: now, calendar: Self.calendar) == nil, "\(nothing)")
        }
    }

    // MARK: - nudges

    @MainActor @Test func aNudgeForThoseYouWaitOnFirstAmongTheReady() throws {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        // Whole seconds, as the store keeps times to the bit.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        // Your ask to Mila three days ago, nobody answered: Waiting.
        store.put([mail("a1", from: Self.me, to: Self.mila, at: now.addingTimeInterval(-3 * 86_400), labels: ["SENT"], rfc: Self.mine),
                   // Her question an hour ago: needs you, no nudge.
                   mail("d1", thread: "deck", from: Self.mila, to: Self.me, at: now.addingTimeInterval(-3600), labels: ["INBOX"]),
                   // Your answer of this morning, its reminder due within the day.
                   mail("p1", thread: "lisbon", from: Self.me, to: Self.mila, at: now.addingTimeInterval(-7200), labels: ["SENT"])])
        store.follow(MailFollowup(thread: "lisbon", message: "<p1@example.com>", until: now.addingTimeInterval(3600), sent: now.addingTimeInterval(-7200)))
        let asks = MailDrafts.nudging(store, now: now)
        #expect(Set(asks.map(\.thread)) == ["venue", "lisbon"])
        #expect(asks.allSatisfy { $0.text.contains("<thread id=") })
        // Asked: not again within the day, whatever came back.
        for ask in asks { store.nudging(ask.thread, message: ask.message, at: now) }
        #expect(MailDrafts.nudging(store, now: now.addingTimeInterval(3600)).isEmpty)
        #expect(MailDrafts.nudging(store, now: now.addingTimeInterval(86_400 + 60)).count == 2)
        // Written: first among what is ready, named Nudge.
        store.keepNudge("venue", message: "a1", body: "Just bringing this back up: loft or boathouse?")
        store.keepAhead("venue", message: "", replies: ["Agree\u{1F}The loft it is."])
        let engine = MailCenter.Engine(account: Self.me.address, store: store, gmail: MailGmail(token: { "" }), sync: MailSync(store: store, gmail: MailGmail(token: { "" })))
        let ready = MailDesk.ready("venue", in: engine)
        #expect(ready.map(\.label) == ["Nudge", "Agree"])
        #expect(ready.first?.text == "Just bringing this back up: loft or boathouse?")
        // A nudge kept: none asked for it while it stands.
        #expect(!MailDrafts.nudging(store, now: now.addingTimeInterval(86_400 + 60)).map(\.thread).contains("venue"))
        // Another mail in the thread: the nudge was for the one before.
        store.put([mail("a2", from: Self.me, to: Self.mila, at: now.addingTimeInterval(-60), labels: ["SENT"])])
        #expect(store.nudge("venue") == nil)
        #expect(MailDesk.ready("venue", in: engine).map(\.label) == ["Agree"])
    }

    @MainActor @Test func nudgesWrittenByTheWriter() throws {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put([mail("a1", from: Self.me, to: Self.mila, at: Date().addingTimeInterval(-3 * 86_400), labels: ["SENT"], rfc: Self.mine)])
        let engine = MailCenter.Engine(account: Self.me.address, store: store, gmail: MailGmail(token: { "" }), sync: MailSync(store: store, gmail: MailGmail(token: { "" })))
        var asked: [String] = []
        let kept = MailDrafts.fake
        // Replies written ahead are off until the person turns them on
        // (MailConsent); this test is of what they write once on.
        let wasOn = MailDrafts.on
        MailDrafts.on = true
        defer { MailDrafts.fake = kept; MailDrafts.on = wasOn }
        MailDrafts.fake = { prompt in
            asked.append(prompt)
            return #"{"venue": [{"label": "Nudge", "text": "Any thoughts on the venue?"}]}"#
        }
        MailDrafts.run(engine, force: true)
        #expect(asked.count == 1 && asked[0].contains("Write a nudge for each of these threads."))
        #expect(store.nudge("venue") == "Any thoughts on the venue?")
        #expect(MailDesk.ready("venue", in: engine).first?.label == "Nudge")
    }
}
