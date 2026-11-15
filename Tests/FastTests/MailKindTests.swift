import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Sorting (docs/mail.md, Splits): kinds of mail placed by the splits'
// own rules (a split of a kind alone takes it, or skips the inbox with it)
// or, with none, by Needs you or Other as Settings says for the kind; and
// Label in Gmail, yab/<Kind> on the last month's threads of a kind, each
// once, through ops.
struct MailKindTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let day: TimeInterval = 86_400
    static let me = "me@acme.io"

    func of(_ kind: MailSensed.Kind?, lastIsMine: Bool = false, bulk: Bool = false, age: TimeInterval = 3600,
            read: (needs: Bool, due: Bool)? = (false, false), kinds: [String: String] = [:]) -> MailSplit? {
        MailSplit.of(inbox: true, bulk: bulk, category: false, kind: kind, lastIsMine: lastIsMine, doneWaiting: false,
                     last: Self.now.addingTimeInterval(-age), read: read, now: Self.now,
                     policy: MailSplit.Policy(asks: true, days: 7, kinds: kinds))
    }

    // MARK: - placing

    @Test func aKindGoesWhereSortingSays() {
        // As it asks: a bill asking nothing is Other, one naming a date needs you.
        #expect(of(.invoice) == .other)
        #expect(of(.invoice, read: (false, true)) == .needs)
        // Set to Needs you: there whatever it asks, a list's mail too.
        #expect(of(.invoice, kinds: ["invoice": "needs"]) == .needs)
        #expect(of(.list, bulk: true, kinds: ["list": "needs"]) == .needs)
        // Set to Other: an invitation asking you is Other.
        #expect(of(.meeting, read: (true, false), kinds: ["meeting": "other"]) == .other)
        // Never Needs you while your word is the last.
        #expect(of(.invoice, lastIsMine: true, kinds: ["invoice": "needs"]) == .other)
        // Older than the window: Archive still.
        #expect(of(.invoice, age: 10 * Self.day, kinds: ["invoice": "needs"]) == .older)
        // Another kind is left as it was.
        #expect(of(.code, bulk: true, kinds: ["invoice": "needs"]) == .other)
    }

    @Test func sortingIsKept() {
        let defaults = UserDefaults(suiteName: "mail-kinds-\(UUID().uuidString)")!
        MailSplit.Policy(asks: true, days: 7, kinds: ["invoice": "needs", "code": "other"]).keep(defaults)
        #expect(MailSplit.Policy.kept(defaults).kinds == ["invoice": "needs", "code": "other"])
        // Anything but a list's name kept by another Yab is left out.
        defaults.set(["shipping": "later"], forKey: "mail.kinds")
        #expect(MailSplit.Policy.kept(defaults).kinds.isEmpty)
    }

    // MARK: - the table's menu

    func builtIns(receipts: Bool = false, mode: MailList.Split.Mode = .only) -> [MailList.Split] {
        MailSplits.builtIns.map { one in
            var one = one
            if one.id == "receipts" {
                one.on = receipts
                one.mode = mode
            }
            return one
        }
    }

    @Test func whereAKindGoesIsTheSplits() {
        // Receipts gathers bills alone; Calendar invitations; none the rest, Ads and promos hidden.
        #expect(MailKinds.splits(of: .invoice, in: builtIns()).map(\.id) == ["receipts"])
        #expect(MailKinds.splits(of: .meeting, in: builtIns()).map(\.id) == ["calendar"])
        #expect(MailKinds.splits(of: .shipping, in: builtIns()).isEmpty)
        #expect(MailKinds.splits(of: .promotion, in: builtIns()).isEmpty)
        // A split of people and a kind isn't the kind's.
        let mixed = MailList.Split(title: "Stripe", q: "from:stripe.com kind:invoice")
        #expect(MailKinds.splits(of: .invoice, in: [mixed]).isEmpty)

        let policy = MailSplit.Policy()
        // Receipts off: as it asks.
        #expect(MailKinds.goes(.invoice, splits: builtIns(), policy: policy) == "auto")
        // On, Only here: Receipts. Skips the inbox: Skip the inbox. Also in Needs you: the lists.
        #expect(MailKinds.goes(.invoice, splits: builtIns(receipts: true), policy: policy) == "split:receipts")
        #expect(MailKinds.goes(.invoice, splits: builtIns(receipts: true, mode: .skip), policy: policy) == "skip")
        #expect(MailKinds.goes(.invoice, splits: builtIns(receipts: true, mode: .also), policy: MailSplit.Policy(kinds: ["invoice": "needs"])) == "needs")
        // A kind that never asks shows Other as its own way.
        #expect(MailKinds.goes(.code, splits: builtIns(), policy: MailSplit.Policy(kinds: ["code": "other"])) == "auto")

        // Its menu: the lists, its split, Skip the inbox; New Split where it has none.
        #expect(MailKinds.choices(.invoice, splits: builtIns()).map(\.value) == ["auto", "needs", "other", "split:receipts", "skip"])
        #expect(MailKinds.choices(.shipping, splits: builtIns()).map(\.value) == ["auto", "needs", "new", "skip"])
        #expect(MailKinds.choices(.shipping, splits: builtIns()).first?.title == "Other")
        // The split New Split makes is the kind's own.
        let made = MailKinds.made(.list)
        #expect(made.title == "Newsletters" && made.mode == .only && !made.builtIn)
        #expect(MailKinds.splits(of: .list, in: [made]).map(\.id) == [made.id])
    }

    @Test func aKindsSplitTakesItsMail() {
        let store = store()
        let splits = [MailKinds.made(.shipping)]
        let sort = MailSplitSort(splits, order: splits.map(\.id))
        let facts = store.facts(now: Self.now)
        let placed = sort.place(facts, me: Self.me, answers: sort.answers(store, among: nil, now: Self.now), now: Self.now)
        #expect(Set(placed.home.keys) == ["parcel"])
    }

    // MARK: - labels in Gmail

    func mail(_ id: String, _ thread: String, from: String, days: Double, labels: Set<String> = ["INBOX"]) -> MailMessage {
        MailMessage(id: id, thread: thread, from: MailPerson.one(from)!, to: [MailPerson(name: "", address: Self.me)], subject: "Hello",
                    snippet: "A few words.", date: Self.now.addingTimeInterval(-days * Self.day), labels: labels, text: "A few words.")
    }

    /// A bill, a parcel, a code and a newsletter from this month, a bill
    /// from two months ago, and a person's mail.
    func store() -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me)
        store.put([
            mail("m1", "bill", from: "Ledgerly <billing@ledgerly.example>", days: 1),
            mail("m2", "parcel", from: "Shop <ship@shop.example>", days: 2),
            mail("m3", "code", from: "Bank <verify@bank.example>", days: 3),
            mail("m4", "news", from: "Digest <news@digest.example>", days: 4, labels: []),
            mail("m5", "oldbill", from: "Ledgerly <billing@ledgerly.example>", days: 60),
            mail("m6", "anna", from: "Anna <anna@fold.studio>", days: 1),
        ])
        for (thread, message, kind) in [("bill", "m1", MailSensed.Kind.invoice), ("parcel", "m2", .shipping), ("code", "m3", .code),
                                        ("news", "m4", .list), ("oldbill", "m5", .invoice), ("anna", "m6", .person)] {
            store.keep(MailSensed(thread: thread, message: message, needs: false, gist: "", kind: kind))
        }
        return store
    }

    @Test func monthsCounts() {
        let counts = MailKindLabels.counts(store(), now: Self.now)
        #expect(counts[.invoice] == 1)
        #expect(counts[.shipping] == 1)
        #expect(counts[.list] == 1)
        #expect(counts[.promotion] == nil)
    }

    @Test func labelsGoOnAKindsThreadsOnce() {
        let store = store()
        // Nothing turned on: nothing labeled.
        #expect(MailKindLabels.run(store, kinds: [], now: Self.now) == nil)
        #expect(store.allOps().isEmpty)
        // Bills: this month's, by the label's name while Gmail hasn't made it; archived mail too.
        #expect(MailKindLabels.run(store, kinds: [.invoice, .list], now: Self.now)?.count == 2)
        let ops = store.allOps()
        #expect(ops.count == 2)
        #expect(ops.allSatisfy { $0.kind == .label })
        let bills = ops.first { $0.label == "name:yab/Invoices" }
        #expect(bills.map { $0.threads.isEmpty ? [$0.thread] : $0.threads } == ["bill"])
        #expect(ops.contains { $0.label == "name:yab/Newsletters" })
        // Again: none twice.
        #expect(MailKindLabels.run(store, kinds: [.invoice, .list], now: Self.now) == nil)
        #expect(store.allOps().count == 2)
    }

    @Test func aLabelKnownIsPutByItsId() {
        let store = store()
        store.keep(label: MailLabel(id: "Label_9", name: "yab/Shipping"))
        // A thread carrying it already is left as it is.
        store.relabel(thread: "parcel", add: ["Label_9"], remove: [])
        store.put([mail("m7", "parcel2", from: "Shop <ship@shop.example>", days: 1)])
        store.keep(MailSensed(thread: "parcel2", message: "m7", needs: false, gist: "", kind: .shipping))
        #expect(MailKindLabels.run(store, kinds: [.shipping], now: Self.now)?.count == 1)
        let op = store.allOps().last
        #expect(op?.label == "Label_9")
        #expect(op.map { $0.threads.isEmpty ? [$0.thread] : $0.threads } == ["parcel2"])
        // Here at once, as L puts a label.
        #expect(store.thread("parcel2")?.labels.contains("Label_9") == true)
        // Taken off by hand in Gmail: not put back.
        store.relabel(thread: "parcel2", add: [], remove: ["Label_9"])
        #expect(MailKindLabels.run(store, kinds: [.shipping], now: Self.now) == nil)
    }
}
