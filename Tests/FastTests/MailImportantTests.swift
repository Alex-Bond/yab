import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Only what matters (docs/mail.md, Only what matters): Needs you holds what asks
// you something, names a date or came back unanswered, and only from the
// window (a week unless Settings says otherwise); older threads of the
// inbox are Archive, quiet; ads and promos are kept out of every list on
// this Mac alone; and one number, as the Count says, on the pin and the Dock.
struct MailImportantTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let day: TimeInterval = 86_400
    static let week = MailSplit.Policy(asks: true, days: 7)

    func of(age: TimeInterval, lastIsMine: Bool = false, bulk: Bool = false, category: Bool = false,
            kind: MailSensed.Kind? = nil, fired: Bool = false, read: (needs: Bool, due: Bool)? = nil,
            policy: MailSplit.Policy = week) -> MailSplit? {
        MailSplit.of(inbox: true, bulk: bulk, category: category, kind: kind, lastIsMine: lastIsMine, doneWaiting: false,
                     last: Self.now.addingTimeInterval(-age), fired: fired, read: read, now: Self.now, policy: policy)
    }

    // MARK: - what needs you

    @Test func needsYouIsWhatAsksYou() {
        // Not read yet: it needs you until it is.
        #expect(of(age: 3600) == .needs)
        // Read: asks you something, or names a date.
        #expect(of(age: 3600, kind: .person, read: (true, false)) == .needs)
        #expect(of(age: 3600, kind: .invoice, read: (false, true)) == .needs)
        // A person who asked nothing: Other.
        #expect(of(age: 3600, kind: .person, read: (false, false)) == .other)
        // Its reminder came due with nobody answering: asked for.
        #expect(of(age: 3600, lastIsMine: true, fired: true) == .needs)
    }

    @Test func yourLastWordWaitsElsewhere() {
        // Just written: nothing waits on you yet.
        #expect(of(age: 3600, lastIsMine: true, kind: .person, read: (false, false)) == .other)
        // Two days to two weeks with no answer: Waiting, as before.
        #expect(of(age: 5 * Self.day, lastIsMine: true) == .waiting)
    }

    @Test func everyoneFromPeopleIsTheOldRule() {
        let everyone = MailSplit.Policy(asks: false, days: 7)
        #expect(of(age: 3600, kind: .person, read: (false, false), policy: everyone) == .needs)
        #expect(of(age: 3600, lastIsMine: true, policy: everyone) == .needs)
        #expect(of(age: 3600, bulk: true, policy: everyone) == .other)
    }

    // MARK: - Archive

    @Test func olderThanTheWindowIsArchive() {
        #expect(of(age: 8 * Self.day, kind: .person, read: (true, false)) == .older)
        #expect(of(age: 8 * Self.day, bulk: true) == .older)
        // Waiting keeps its own two weeks whatever the window.
        #expect(of(age: 10 * Self.day, lastIsMine: true) == .waiting)
        // A month's window, and every age.
        #expect(of(age: 20 * Self.day, read: (true, false), policy: MailSplit.Policy(asks: true, days: 30)) == .needs)
        #expect(of(age: 400 * Self.day, read: (true, false), policy: MailSplit.Policy(asks: true, days: nil)) == .needs)
        // Lists inside the window stay Other.
        #expect(of(age: Self.day, category: true) == .other)
        #expect(of(age: Self.day, kind: .code) == .other)
    }

    @Test func thePolicyIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "MailImportantTests.\(UUID().uuidString)"))
        #expect(MailSplit.Policy.kept(defaults) == MailSplit.Policy(asks: true, days: 7))
        MailSplit.Policy(asks: false, days: nil).keep(defaults)
        #expect(MailSplit.Policy.kept(defaults) == MailSplit.Policy(asks: false, days: nil))
        MailSplit.Policy(asks: true, days: 30).keep(defaults)
        #expect(MailSplit.Policy.kept(defaults) == MailSplit.Policy(asks: true, days: 30))
    }

    @MainActor @Test func archiveStandsUnderLaterAndOnlyWhenItHoldsSomething() {
        let order = MailSplits.order(["needs", "waiting", "other", "later"], splits: [])
        #expect(order == ["needs", "waiting", "promised", "other", "later", "older"])
        #expect(order.firstIndex(of: "older") == order.firstIndex(of: "later").map { $0 + 1 })
        let empty = MailSplits.column(order: order, splits: [], counts: ["older": 0], hideEmpty: true, front: "needs")
        #expect(!empty.contains { $0.id == "older" })
        let some = MailSplits.column(order: order, splits: [], counts: ["older": 12], hideEmpty: true, front: "needs")
        #expect(some.first { $0.id == "older" }?.title == "Archive")
    }

    // MARK: - ads and promos

    func mail(_ id: String, _ thread: String, from: String, labels: Set<String>, hours: Double = 1) -> MailMessage {
        MailMessage(id: id, thread: thread, from: MailPerson.one(from)!, to: [MailPerson(name: "", address: "me@acme.io")], subject: "Hi",
                    snippet: "Words.", date: Self.now.addingTimeInterval(-hours * 3600), labels: labels, text: "Words.")
    }

    @MainActor @Test func adsAreKeptOutHereAndNeverYours() throws {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@acme.io")
        store.put([
            mail("p1", "promo", from: "Shop <deals@shop.example>", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
            mail("s1", "social", from: "Net <hi@net.example>", labels: ["INBOX", "CATEGORY_SOCIAL"]),
            mail("y1", "yours", from: "Shop <deals@shop.example>", labels: ["INBOX", "CATEGORY_PROMOTIONS", "STARRED"]),
            mail("t1", "team", from: "Kai <kai@acme.io>", labels: ["INBOX", "CATEGORY_PROMOTIONS"]),
            mail("a1", "anna", from: "Anna <anna@fold.studio>", labels: ["INBOX"]),
        ])
        let ads = try #require(MailSplits.builtIns.first { $0.id == MailSplits.ads })
        #expect(ads.on && ads.mode == .only && ads.hidden)
        let sort = MailSplitSort([ads], order: [ads.id], policy: Self.week)
        let facts = store.facts(now: Self.now)
        let placed = sort.place(facts, me: store.me, answers: sort.answers(store, among: nil, now: Self.now), now: Self.now)
        #expect(placed.home["promo"] == 0)
        #expect(placed.home["social"] == 0)
        // Starred, your own domain, a person's: never.
        #expect(placed.home["yours"] == nil)
        #expect(placed.home["team"] == nil)
        #expect(placed.home["anna"] == nil)
        // Out of the column, where Other's head reaches it.
        let column = MailSplits.column(order: ["needs", ads.id], splits: [ads], counts: [ads.id: 2], hideEmpty: false, front: "needs")
        #expect(!column.contains { $0.id == ads.id })
    }

    // MARK: - the count

    @Test func oneNumberAsTheCountSays() {
        #expect(MailNotify.number(.needs, needs: 4, unreadNeeds: 2, unread: 9) == 4)
        #expect(MailNotify.number(.unreadNeeds, needs: 4, unreadNeeds: 2, unread: 9) == 2)
        #expect(MailNotify.number(.unread, needs: 4, unreadNeeds: 2, unread: 9) == 9)
        #expect(MailNotify.number(.off, needs: 4, unreadNeeds: 2, unread: 9) == 0)
        #expect(MailNotify.label(.unreadNeeds, needs: 4, unreadNeeds: 0, unread: 9) == nil)
        #expect(MailNotify.Badge(rawValue: "unread-needs") == .unreadNeeds)
    }

    // MARK: - the day's line (docs/mail.md, Only what matters)

    @MainActor @Test func theDaysLine() {
        let at = Self.now
        let one = MailList.Dated(account: "a", thread: "t1", words: "Ledgerly · $1,240 for August hosting", due: at)
        let two = MailList.Dated(account: "a", thread: "t2", words: "Anna · Asks for a review slot by Thursday", due: at)
        let three = MailList.Dated(account: "a", thread: "t3", words: "you promised Mark · Q3 numbers", due: at)
        #expect(MailList.todayLine([]) == "")
        // Each a clause: its own stop or question mark goes.
        let asked = MailList.Dated(account: "a", thread: "t4", words: "Anna · Review slot this week?", due: at)
        let said = MailList.Dated(account: "a", thread: "t5", words: "Kai · Any slot works.", due: at)
        #expect(MailList.todayLine([asked, said]) == "First: Anna · Review slot this week. Then Kai · Any slot works.")
        #expect(MailList.todayLine([one]) == "Today: Ledgerly · $1,240 for August hosting.")
        #expect(MailList.todayLine([one, two, three])
                == "First: Ledgerly · $1,240 for August hosting. Then Anna · Asks for a review slot by Thursday, and you promised Mark · Q3 numbers.")
    }

    @MainActor @Test func archiveSaysWhatItHolds() {
        #expect(MailSplit(rawValue: "older") == .older)
        #expect(MailList.base.contains { $0.id == "older" && $0.name == "Archive" })
    }
}
