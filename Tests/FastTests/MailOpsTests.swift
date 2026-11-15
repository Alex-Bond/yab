import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// What every triage key does to mail (docs/mail.md, Ops): star, Trash, spam,
// mute and not done, here at once and at Gmail after; each taken back by
// ⌘Z, dropped while Gmail hasn't heard it and undone there by its inverse
// once it has; an act on many threads going to Gmail as messages/batchModify
// in packs of a thousand messages, one journal entry a pack, one ⌘Z for all.
@Suite(.serialized)
struct MailOpsTests {
    let now = Date()

    /// A store and a Gmail of its own, on a host no other suite asks.
    func world() -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "ops-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01)
        return (MailStore(file: MailStore.memory), gmail, fake)
    }

    /// Anna asks, a bill, a digest, and a thread you started and Tim
    /// answered, archived since.
    func seeded() async throws -> (MailStore, MailGmail, FakeGmail) {
        let (store, gmail, fake) = world()
        fake.add(.init(id: "a1", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Thursday works?",
                       body: "Can we do the review Thursday?", at: now.addingTimeInterval(-3600), labels: ["INBOX", "UNREAD"]), record: false)
        fake.add(.init(id: "b1", thread: "tb", from: "Ledgerly <billing@ledgerly.io>", subject: "Invoice #4471 is past due",
                       body: "Your card was declined.", at: now.addingTimeInterval(-7200), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "c1", thread: "tc", from: "News <news@digest.io>", subject: "Weekly digest",
                       body: "Ten links.", at: now.addingTimeInterval(-9000), labels: ["INBOX", "CATEGORY_UPDATES"]), record: false)
        fake.add(.init(id: "d1", thread: "td", from: "me@example.com", to: "tim@okafor.co", subject: "Logo files",
                       body: "Could you send the SVGs?", at: now.addingTimeInterval(-86_400 * 3), labels: ["SENT"]), record: false)
        fake.add(.init(id: "d2", thread: "td", from: "Tim Okafor <tim@okafor.co>", subject: "Re: Logo files",
                       body: "Here.", at: now.addingTimeInterval(-86_400 * 2), labels: []), record: false)
        try await MailSync(store: store, gmail: gmail).sync()
        return (store, gmail, fake)
    }

    func labels(_ fake: FakeGmail, _ thread: String) -> Set<String> {
        fake.messages.values.filter { $0.thread == thread }.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
    }

    // MARK: - effects and inverses

    @Test func eachKindAndItsInverse() {
        let kinds: [MailOp.Kind] = [.archive, .unarchive, .read, .unread, .label, .unlabel, .trash, .untrash,
                                    .star, .unstar, .spam, .unspam, .mute, .unmute]
        for kind in kinds {
            #expect(MailOps.inverse(kind).flatMap(MailOps.inverse) == kind, "\(kind)")
        }
        #expect(MailOps.inverse(.send) == nil)
        let said = { (kind: MailOp.Kind) -> [Set<String>] in
            let change = MailOps.effect(kind, label: kind == .mute || kind == .unmute ? MailOps.muted : "")
            return [change.add, change.remove]
        }
        #expect(said(.star) == [["STARRED"], []])
        #expect(said(.unstar) == [[], ["STARRED"]])
        #expect(said(.spam) == [["SPAM"], ["INBOX"]])
        #expect(said(.unspam) == [[], ["SPAM"]])
        #expect(said(.trash) == [["TRASH"], ["INBOX"]])
        // Out of Trash as Gmail takes it out: back in the inbox is its own op.
        #expect(said(.untrash) == [[], ["TRASH"]])
        #expect(said(.mute) == [[], ["INBOX"]])
        #expect(said(.unmute) == [[], []])
    }

    @Test func starHereAtOnceThenGmailThenTakenBack() async throws {
        let (store, gmail, fake) = try await seeded()
        let acted = MailOps.star(["tb"], after: 4, in: store)
        #expect(acted.kinds == [.star])
        #expect(store.thread("tb")?.labels.contains("STARRED") == true)
        // Held for its undo: Gmail hasn't heard it.
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "tb").contains("STARRED"))
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        #expect(labels(fake, "tb").contains("STARRED"))
        // ⌘Z once Gmail has it: unstarred here at once, and there by its inverse.
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("tb")?.labels.contains("STARRED") == false)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "tb").contains("STARRED"))
        #expect(store.pendingOps == 0)
        // Every one starred already: S unstars.
        _ = MailOps.star(["ta"], in: store)
        #expect(MailOps.star(["ta"], in: store).kinds == [.unstar])
    }

    @Test func trashAndBackOutOfIt() async throws {
        let (store, gmail, fake) = try await seeded()
        let acted = MailOps.trash(["tb"], in: store)
        #expect(store.thread("tb")?.labels == ["TRASH"])
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "tb") == ["TRASH"])
        #expect(fake.calls.contains("POST threads/tb/trash"))
        // ⌘Z after Gmail heard it: out of Trash, and back in the inbox, where it was, in one call.
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("tb")?.labels == ["INBOX"])
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.calls.contains("POST threads/tb/modify") && !fake.calls.contains("POST threads/tb/untrash"))
        #expect(labels(fake, "tb") == ["INBOX"])
        // # on a thread in Trash already: out of it, back in the inbox.
        _ = MailOps.trash(["tc"], in: store)
        let out = MailOps.trash(["tc"], in: store)
        #expect(out.kinds == [.untrash, .unarchive])
        #expect(store.thread("tc")?.labels.contains("INBOX") == true)
        #expect(store.thread("tc")?.labels.contains("TRASH") == false)
    }

    @Test func spamTakenBackBeforeGmailHears() async throws {
        let (store, gmail, fake) = try await seeded()
        fake.calls = []
        let acted = MailOps.spam(["tc"], after: 4, in: store)
        #expect(store.thread("tc")?.labels.contains("SPAM") == true)
        #expect(store.thread("tc")?.labels.contains("INBOX") == false)
        #expect(MailSplit.of(try #require(store.thread("tc"))) == nil)
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("tc")?.labels.contains("SPAM") == false)
        #expect(store.thread("tc")?.labels.contains("INBOX") == true)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        // Gmail never heard a thing.
        #expect(fake.calls.isEmpty)
        #expect(store.pendingOps == 0)
    }

    @Test func spamOutOfTheInboxAndNotSpamBackIn() async throws {
        let (store, gmail, fake) = try await seeded()
        let acted = MailOps.spam(["ta"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "ta").contains("SPAM"))
        #expect(!labels(fake, "ta").contains("INBOX"))
        MailOps.takeBack(acted, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "ta").contains("SPAM"))
        #expect(labels(fake, "ta").contains("INBOX"))
        // ! on spam: not spam, in the inbox.
        _ = MailOps.spam(["tb"], in: store)
        #expect(MailOps.spam(["tb"], in: store).kinds == [.unspam, .unarchive])
        #expect(store.thread("tb")?.labels.contains("INBOX") == true)
    }

    @Test func muteKeepsWhatComesOutOfTheInbox() async throws {
        let (store, gmail, fake) = try await seeded()
        let sync = MailSync(store: store, gmail: gmail)
        let acted = MailOps.mute(["ta"], in: store)
        #expect(acted.muted == ["ta"])
        #expect(store.thread("ta")?.muted == true)
        #expect(store.thread("ta")?.labels.contains("INBOX") == false)
        try await MailOps.flush(store, gmail: gmail)
        // Gmail: out of the inbox, under yab/Muted, made once.
        #expect(fake.labels.values.sorted() == ["yab/Muted"])
        #expect(labels(fake, "ta").contains("Label_1"))
        #expect(!labels(fake, "ta").contains("INBOX"))
        // Anna writes again: it doesn't come back to Needs you.
        fake.add(.init(id: "a2", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Thursday works?",
                       body: "Any news?", at: now, labels: ["INBOX", "UNREAD"]))
        try await sync.sync()
        let thread = try #require(store.thread("ta"))
        #expect(!thread.labels.contains("INBOX"))
        #expect(thread.unread)
        #expect(!MailSplit.threads(.needs, in: store).map(\.0.id).contains("ta"))
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.messages["a2"]?.labels.contains("INBOX") == false)
        // Muted ones listed; ⇧M on one muted: unmuted, back in the inbox.
        #expect(store.mutedThreads().map(\.id) == ["ta"])
        let unmuted = MailOps.mute(["ta"], in: store)
        #expect(unmuted.kinds == [.unmute, .unarchive])
        #expect(store.thread("ta")?.muted == false)
        #expect(store.thread("ta")?.labels.contains("INBOX") == true)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "ta").contains("Label_1"))
        // ⌘Z on the unmute: muted again, out again.
        MailOps.takeBack(unmuted, in: store)
        #expect(store.thread("ta")?.muted == true)
        #expect(store.thread("ta")?.labels.contains("INBOX") == false)
    }

    @Test func notDoneBringsItBack() async throws {
        let (store, gmail, fake) = try await seeded()
        // Tim's thread: archived, Tim's the last word. ⇧E: in the inbox.
        let acted = MailOps.notDone(["td", "ta"], in: store)
        #expect(acted.kinds == [.unarchive])
        #expect(acted.entries.first?.threads == ["td"])
        #expect(store.thread("td")?.labels.contains("INBOX") == true)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.messages["d2"]?.labels.contains("INBOX") == true)
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("td")?.labels.contains("INBOX") == false)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.messages["d2"]?.labels.contains("INBOX") == false)
    }

    @Test func doneOnALaterThreadIsDoneWithIt() async throws {
        let (store, _, _) = try await seeded()
        _ = MailOps.snooze(["tb"], until: now.addingTimeInterval(3600), why: "In an hour", in: store)
        #expect(store.snoozes().map(\.thread) == ["tb"])
        let acted = MailOps.done(["tb"], in: store)
        #expect(store.snoozes().isEmpty)
        #expect(acted.kinds == [.unlabel])
        MailOps.takeBack(acted, in: store)
        #expect(store.snoozes().map(\.thread) == ["tb"])
    }

    // MARK: - many at once

    /// 2,500 threads of one mail each, here and at Gmail.
    func many(_ count: Int) -> (MailStore, MailGmail, FakeGmail, [String]) {
        let (store, gmail, fake) = world()
        store.set("me", "me@example.com")
        var mail: [MailMessage] = []
        for n in 0..<count {
            let at = now.addingTimeInterval(Double(-n) * 60)
            fake.add(.init(id: "m\(n)", thread: "t\(n)", from: "Shop <news@shop.example>", subject: "Order \(n)", body: "Shipped.",
                           at: at, labels: ["INBOX"]), record: false)
            mail.append(MailMessage(id: "m\(n)", thread: "t\(n)", from: MailPerson(name: "Shop", address: "news@shop.example"),
                                    subject: "Order \(n)", date: at, labels: ["INBOX"]))
        }
        store.put(mail)
        return (store, gmail, fake, (0..<count).map { "t\($0)" })
    }

    @Test func aBulkGoesInPacksOfAThousand() async throws {
        let (store, gmail, fake, threads) = many(2500)
        let acted = MailOps.done(threads, after: 4, in: store)
        // One journal entry a pack, and all of it out of the inbox here.
        #expect(acted.entries.count == 1)
        #expect(acted.entries[0].parts.map(\.threads.count) == [1000, 1000, 500])
        #expect(store.pendingOps == 3)
        #expect(store.threads(label: "INBOX").isEmpty)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        // Three calls, a thousand ids at most each, every message once.
        let calls = fake.calls.filter { $0 == "POST messages/batchModify" }
        #expect(calls.count == 3)
        #expect(fake.batches.map(\.count) == [1000, 1000, 500])
        #expect(Set(fake.batches.joined()).count == 2500)
        #expect(fake.messages.values.allSatisfy { !$0.labels.contains("INBOX") })
        #expect(store.pendingOps == 0)
        // What it cost: 50 a call, where a thread's modify each would be 25,000.
        let cost = calls.map { _ in MailGmail.cost("messages/batchModify", method: "POST") }.reduce(0, +)
        #expect(cost == 150)
        #expect(MailGmail.cost("threads/t1/modify", method: "POST") * threads.count == 25_000)
    }

    @Test func oneUndoTakesBackTheWholeBulk() async throws {
        let (store, gmail, fake, threads) = many(2500)
        // Before Gmail heard it: every pack dropped, every thread back.
        let early = MailOps.done(threads, after: 4, in: store)
        MailOps.takeBack(early, in: store)
        #expect(store.pendingOps == 0)
        #expect(store.threads(label: "INBOX", limit: 3000).count == 2500)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        #expect(fake.calls.isEmpty)
        // After: the inverse, in packs again, the inbox as it was.
        let late = MailOps.done(threads, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 3)
        MailOps.takeBack(late, in: store)
        #expect(store.threads(label: "INBOX", limit: 3000).count == 2500)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 6)
        #expect(fake.messages.values.allSatisfy { $0.labels.contains("INBOX") })
    }

    @Test func aPackOfThreadsLongAndShort() {
        let (store, _, _, _) = many(3)
        var long: [MailMessage] = []
        for n in 0..<700 {
            long.append(MailMessage(id: "l\(n)", thread: "long", from: MailPerson(name: "", address: "a@b.c"), date: now, labels: ["INBOX"]))
        }
        store.put(long)
        // 700 and one each: a pack can't hold the second long one.
        #expect(MailOps.packs(["long", "t0", "t1"], in: store) == [["long", "t0", "t1"]])
        store.put(long.map { var m = $0; m.id = "k" + m.id; m.thread = "long2"; return m })
        #expect(MailOps.packs(["long", "t0", "long2", "t1"], in: store) == [["long", "t0"], ["long2", "t1"]])
        // One thread is an op of its own, as ever: Gmail hears threads/modify.
        #expect(MailOps.bulk(.star, threads: ["t2"], in: store).count == 1)
        #expect(store.allOps().last?.isPack == false)
        #expect(store.allOps().last?.threads == ["t2"])
    }

    /// Fewer than five threads go to Gmail a thread at a time, 10 units
    /// each, under a batch's 50 (Google's quota table); five and more as one
    /// messages/batchModify. Fewer than ten messages by their ids go a
    /// message at a time, 5 units each.
    @Test func aFewThreadsGoByTheirThreadsWhereThatCostsLess() async throws {
        let (store, gmail, fake, threads) = many(9)
        let four = Array(threads.prefix(4))
        _ = MailOps.done(four, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.isEmpty)
        #expect(Set(fake.calls.filter { $0.hasSuffix("/modify") }) == Set(four.map { "POST threads/\($0)/modify" }))
        #expect(four.allSatisfy { fake.messages["m" + $0.dropFirst()]?.labels.contains("INBOX") == false })
        let before = fake.calls.count
        _ = MailOps.done(Array(threads.suffix(5)), in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 1 && fake.batches.first?.count == 5)
        #expect(!fake.calls[before...].contains { $0.hasPrefix("POST threads/") })
        // By their ids: three messages, a message at a time.
        MailOps.bulk(.unarchive, messages: ["m0", "m1", "m2"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 1)
        #expect(Set(fake.calls.filter { $0.hasPrefix("POST messages/m") }) == ["POST messages/m0/modify", "POST messages/m1/modify", "POST messages/m2/modify"])
        #expect(["m0", "m1", "m2"].allSatisfy { fake.messages[$0]?.labels.contains("INBOX") == true })
    }

    /// # again on a thread in Trash, ! again on spam: out of it and back in
    /// the inbox in one call to Gmail (TRASH or SPAM off, INBOX on, a
    /// modify takes both), where an untrash and an unarchive were two.
    @Test func outOfTrashAndBackInTheInboxInOneCall() async throws {
        let (store, gmail, fake, threads) = many(7)
        _ = MailOps.trash(["t0"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        let before = fake.calls.count
        let back = MailOps.trash(["t0"], in: store)
        #expect(back.kinds == [.untrash, .unarchive])
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.calls[before...].filter { $0.hasPrefix("POST") } == ["POST threads/t0/modify"])
        #expect(fake.messages["m0"]?.labels == ["INBOX"])
        #expect(store.pendingOps == 0)
        // Six threads into spam and back: one batch for each, not two back.
        let six = Array(threads.suffix(6))
        _ = MailOps.spam(six, in: store)
        try await MailOps.flush(store, gmail: gmail)
        let batches = fake.batches.count
        #expect(MailOps.spam(six, in: store).kinds == [.unspam, .unarchive])
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == batches + 1)
        #expect(six.allSatisfy { fake.messages["m" + $0.dropFirst()]?.labels == ["INBOX"] })
        #expect(store.pendingOps == 0)
        // ⌘Z before Gmail heard either: both dropped, nothing sent.
        _ = MailOps.trash(["t0"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        let held = MailOps.trash(["t0"], after: 60, in: store)
        MailOps.takeBack(held, in: store)
        let sent = fake.calls.count
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.calls.count == sent && store.pendingOps == 0)
    }

    /// Muted on another Mac, or before Yab was put on this one again:
    /// Gmail's yab/Muted says so and the sync keeps it muted here, its next
    /// mail put away as it comes; unmuted there, unmuted here, unless a
    /// mute of this Mac's own still waits for Gmail.
    @Test func mutesComeBackFromGmail() async throws {
        let (store, gmail, fake) = world()
        store.set("me", "me@example.com")
        fake.labels["Label_M"] = "yab/Muted"
        fake.add(.init(id: "a1", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Party", body: "Who's in?",
                       at: now.addingTimeInterval(-600), labels: ["Label_M"]), record: false)
        fake.add(.init(id: "b1", thread: "tb", from: "Tim Okafor <tim@okafor.co>", subject: "Logo", body: "v2",
                       at: now.addingTimeInterval(-500), labels: ["INBOX"]), record: false)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        #expect(store.mutedThreads().map(\.id) == ["ta"])
        // Anna writes again: put away as it comes, as a mute made here is.
        fake.add(.init(id: "a2", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Re: Party", body: "Anyone?",
                       at: now, labels: ["INBOX", "UNREAD"]))
        try await sync.sync()
        #expect(store.message("a2")?.labels.contains("INBOX") == false)
        // Unmuted on the other Mac: yab/Muted off its mail.
        try await gmail.modify(message: "a1", add: [], remove: ["Label_M"])
        try await sync.sync()
        #expect(store.mutedThreads().isEmpty)
        // Muted here, Gmail not told yet: it stays muted, whatever Gmail's mail says.
        _ = MailOps.mute(["tb"], after: 60, in: store)
        fake.add(.init(id: "b2", thread: "tb", from: "Tim Okafor <tim@okafor.co>", subject: "Re: Logo", body: "v3",
                       at: now, labels: ["INBOX", "UNREAD"]))
        try await sync.sync()
        #expect(store.mutedThreads().map(\.id) == ["tb"])
    }

    @Test func aThreadNotWholeHereGoesByItsThread() async throws {
        let (store, gmail, fake, _) = many(4)
        // The first mail kept of t9 answers one older than the sync reached.
        fake.add(.init(id: "old", thread: "t9", from: "Anna <anna@fold.studio>", subject: "Plan", body: "v1",
                       at: now.addingTimeInterval(-86_400 * 90), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "new", thread: "t9", from: "Anna <anna@fold.studio>", subject: "Re: Plan", body: "v2",
                       at: now, labels: ["INBOX"]), record: false)
        store.put([MailMessage(id: "new", thread: "t9", from: MailPerson(name: "Anna", address: "anna@fold.studio"), subject: "Re: Plan",
                               date: now, labels: ["INBOX"], rfcID: "<new@x>", inReplyTo: "<old@x>")])
        #expect(store.partial(["t0", "t9"]) == ["t9"])
        // Five threads: a batch is worth it for the four whole here.
        _ = MailOps.done(["t0", "t1", "t2", "t3", "t9"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches == [["m0", "m1", "m2", "m3"]])
        #expect(fake.calls.contains("POST threads/t9/modify"))
        // Its mail older than this Mac holds is out of the inbox too.
        #expect(fake.messages["old"]?.labels.contains("INBOX") == false)
    }

    // MARK: - the lists beyond the inbox

    @Test func viewsHoldWhatTheyShould() async throws {
        let (store, _, _) = try await seeded()
        _ = MailOps.star(["ta"], in: store)
        _ = MailOps.trash(["tb"], in: store)
        _ = MailOps.spam(["tc"], in: store)
        let ids = { (view: String) in MailDesk.viewThreads(view, in: store).map(\.id) }
        #expect(ids("starred") == ["ta"])
        #expect(ids("trash") == ["tb"])
        #expect(ids("spam") == ["tc"])
        #expect(ids("sent") == ["td"])
        // Done: out of the inbox with someone else's mail in it; Tim answered.
        #expect(ids("done") == ["td"])
        #expect(ids("all") == ["ta", "td"])
        _ = MailOps.done(["ta"], in: store)
        #expect(ids("done") == ["ta", "td"])
        _ = MailOps.mute(["ta"], in: store)
        #expect(ids("muted") == ["ta"])
        #expect(ids("done") == ["td"])
        #expect(ids("starred") == ["ta"])
    }
}
