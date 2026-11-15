import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Labels (docs/mail.md, Labels): Gmail's list kept in the store every ten
// minutes and at once for a label not known, renames and deletions
// followed; the column's labels nested by "/"; L, V and Y as ops with their
// inverses, in packs, one ⌘Z for all; a label's list, as G's are, read here
// and asked of Gmail for what is older; the counts the column shows asked
// of labels.get for the labels on screen only.
@Suite(.serialized)
struct MailLabelTests {
    let now = Date()
    let day: TimeInterval = 86_400

    /// A store and a Gmail of its own, on a host no other suite asks.
    func world() -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "labels-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01)
        return (MailStore(file: MailStore.memory), gmail, fake)
    }

    /// Work, Work/Clients and Receipts; Anna's thread in the inbox under
    /// Work/Clients, a bill in the inbox, a receipt filed away, and a
    /// contract under Work/Clients older than the sync keeps.
    func seeded() async throws -> (MailStore, MailGmail, FakeGmail, MailSync) {
        let (store, gmail, fake) = world()
        fake.labels = ["Label_1": "Work", "Label_2": "Work/Clients", "Label_3": "Receipts"]
        fake.add(.init(id: "a1", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Kickoff",
                       body: "Can we start Monday?", at: now.addingTimeInterval(-3600), labels: ["INBOX", "UNREAD", "Label_2"]), record: false)
        fake.add(.init(id: "b1", thread: "tb", from: "Ledgerly <billing@ledgerly.io>", subject: "Invoice #4471",
                       body: "Your card was declined.", at: now.addingTimeInterval(-7200), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "c1", thread: "tc", from: "Stripe <receipts@stripe.com>", subject: "Your receipt",
                       body: "Paid.", at: now.addingTimeInterval(-10 * day), labels: ["Label_3"]), record: false)
        fake.add(.init(id: "o1", thread: "to", from: "Mark Chen <mark@northwind.vc>", subject: "Contract 2024",
                       body: "Signed.", at: now.addingTimeInterval(-400 * day), labels: ["Label_2", "UNREAD"]), record: false)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        return (store, gmail, fake, sync)
    }

    func labels(_ fake: FakeGmail, _ thread: String) -> Set<String> {
        fake.messages.values.filter { $0.thread == thread }.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
    }

    // MARK: - Gmail's list

    @Test func theListIsKeptAndRenamesAndDeletionsFollow() async throws {
        let (store, _, fake, sync) = try await seeded()
        #expect(Set(store.labels().map(\.name)) == ["Work", "Work/Clients", "Receipts"])
        #expect(store.labelID(exactly: "work/clients") == "Label_2" && store.labelID(exactly: "Work-Clients") == nil)
        #expect(store.labelID(named: "Work-Clients") == "Label_2")
        #expect(store.thread("tc")?.labels.contains("Label_3") == true)
        // Renamed and deleted in Gmail, which takes a label deleted off its
        // mail without a word in its history.
        fake.labels["Label_1"] = "Projects"
        fake.labels["Label_3"] = nil
        for id in fake.messages.keys { fake.messages[id]?.labels.remove("Label_3") }
        // An op still to tell Gmail of the label deleted.
        _ = MailOps.label(["tb"], id: "Label_3", after: 60, in: store)
        #expect(store.pendingOps == 1)
        fake.calls = []
        try await sync.sync()
        // Not before its ten minutes are up.
        #expect(!fake.calls.contains("GET labels") && store.labelID(exactly: "Work") == "Label_1")
        #expect(try await sync.keepLabels(now: Date().addingTimeInterval(MailSync.labelsEvery + 1)))
        #expect(Set(store.labels().map(\.name)) == ["Projects", "Work/Clients"])
        #expect(store.labelID(exactly: "Work") == nil && store.labelID(exactly: "Projects") == "Label_1")
        // Off its mail here too, and nothing left to tell Gmail of it.
        #expect(store.thread("tc")?.labels.contains("Label_3") == false && store.thread("tb")?.labels.contains("Label_3") == false)
        #expect(store.pendingOps == 0)
        #expect(store.find(MailQuery.parse("label:receipts")).answered == false)
        // Nothing changed: the list again changes nothing.
        #expect(try await sync.keepLabels(force: true) == false)
    }

    // MARK: - the label's menu

    /// Mark All as Read reads what this Mac keeps of the label (Gmail's
    /// older mail is asked by its ids, as the eval checks), and its Undo
    /// takes that back.
    @Test func markAllReadReadsTheLabelsUnreadThreads() async throws {
        let (store, _, _, _) = try await seeded()
        #expect(store.unreadThreads(label: "Label_2") == ["ta"])
        #expect(store.unreadThreads(label: "Label_3").isEmpty)
        let acted = MailOps.read(store.unreadThreads(label: "Label_2"), after: 60, in: store)
        #expect(store.thread("ta")?.unread == false && store.unreadThreads(label: "Label_2").isEmpty)
        #expect(acted.kinds == [.read])
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("ta")?.unread == true && store.pendingOps == 0)
        // Nothing unread: nothing queued.
        #expect(MailOps.read(["tc"], in: store).isEmpty)
    }

    /// The bench presses a menu's line by its title, a submenu's by its path,
    /// Move To's nested names without their indent.
    @Test func aMenuLineIsFoundByItsPath() {
        let lines = [
            MailLabelLine("Mark All as Read", enabled: false),
            .divider,
            MailLabelLine("Move To", sub: [MailLabelLine("Clients"), MailLabelLine("\u{2003}Acme"), .divider, MailLabelLine("Move Out of \u{201C}Work\u{201D}")]),
        ]
        #expect(MailLabelLine.find("Mark All as Read", in: lines)?.enabled == false)
        #expect(MailLabelLine.find("Move To/Acme", in: lines)?.title == "\u{2003}Acme")
        #expect(MailLabelLine.find("Move To/Move Out of \u{201C}Work\u{201D}", in: lines) != nil)
        #expect(MailLabelLine.find("Move To/Nowhere", in: lines) == nil && MailLabelLine.find("Rename\u{2026}", in: lines) == nil)
    }

    @Test func aLabelNotKnownHasTheListAskedAtOnce() async throws {
        let (store, _, fake, sync) = try await seeded()
        fake.labels["Label_9"] = "Travel"
        fake.add(.init(id: "t1", thread: "tt", from: "Northwind Air <trips@northwindair.com>", subject: "Your flight",
                       body: "Gate 12.", at: now, labels: ["INBOX", "Label_9"]))
        fake.calls = []
        try await sync.sync()
        #expect(fake.calls.contains("GET labels"))
        #expect(store.labelID(exactly: "Travel") == "Label_9")
        // Mail with labels it knows asks nothing more.
        fake.add(.init(id: "t2", thread: "tt", from: "Northwind Air <trips@northwindair.com>", subject: "Re: Your flight",
                       body: "Boarding.", at: now, labels: ["INBOX", "Label_9"]))
        fake.calls = []
        try await sync.sync()
        #expect(!fake.calls.contains("GET labels"))
    }

    @Test func gmailsLabelsReadAsTheyCome() {
        let label = MailGmail.label(["id": "Label_4", "name": "Work/Clients", "type": "user", "labelListVisibility": "labelShowIfUnread",
                                     "color": ["backgroundColor": "#fad165", "textColor": "#000000"], "threadsUnread": 3, "threadsTotal": 12])
        #expect(label == MailLabel(id: "Label_4", name: "Work/Clients", type: "user", color: "#fad165", textColor: "#000000",
                                   shown: "labelShowIfUnread", unread: 3, threads: 12))
        // Gmail's own, said by its id when the type isn't there.
        #expect(MailGmail.label(["id": "STARRED", "name": "STARRED"])?.user == false)
    }

    // MARK: - the column

    @Test func nestedBySlashes() {
        let names = ["Work", "Work/Clients", "Work/Clients/Acme", "Home", "Receipts/2024", "work stuff", "Work/Hiring"]
        let tree = MailLabels.tree(names, closed: [])
        #expect(tree.map(\.name) == ["Home", "Receipts/2024", "Work", "Work/Clients", "Work/Clients/Acme", "Work/Hiring", "work stuff"])
        #expect(tree.map(\.leaf) == ["Home", "Receipts/2024", "Work", "Clients", "Acme", "Hiring", "work stuff"])
        #expect(tree.map(\.depth) == [0, 0, 0, 1, 2, 1, 0])
        #expect(tree.filter(\.parent).map(\.name) == ["Work", "Work/Clients"])
        // Closed over what is under it: those left out, it says so.
        let closed = MailLabels.tree(names, closed: ["Work/Clients"])
        #expect(closed.map(\.name) == ["Home", "Receipts/2024", "Work", "Work/Clients", "Work/Hiring", "work stuff"])
        #expect(closed.first { $0.name == "Work/Clients" }?.open == false)
        #expect(MailLabels.tree(names, closed: ["Work"]).map(\.name) == ["Home", "Receipts/2024", "Work", "work stuff"])
    }

    @Test func yabsOwnAndHiddenLabelsStayOut() {
        #expect(MailLabels.listed(MailLabel(id: "Label_1", name: "Work")))
        #expect(!MailLabels.offered(MailLabel(id: "Label_2", name: "yab/Snoozed")))
        #expect(!MailLabels.offered(MailLabel(id: "INBOX", name: "INBOX", type: "system")))
        // Hidden in Gmail's list: not in the column, still to pick with L.
        let hidden = MailLabel(id: "Label_3", name: "Old", shown: "labelHide")
        #expect(!MailLabels.listed(hidden) && MailLabels.offered(hidden))
    }

    // MARK: - L, V and Y

    @Test func labelHereAtOnceThenGmailThenTakenBack() async throws {
        let (store, gmail, fake, _) = try await seeded()
        let acted = MailOps.label(["tb"], id: "Label_3", after: 4, in: store)
        #expect(acted.kinds == [.label])
        #expect(store.thread("tb")?.labels.contains("Label_3") == true)
        // Held for its undo: Gmail hasn't heard it; taken back, never will.
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "tb").contains("Label_3"))
        MailOps.takeBack(acted, in: store)
        #expect(store.thread("tb")?.labels.contains("Label_3") == false && store.pendingOps == 0)
        // Again, heard this time, then taken back: Gmail hears the inverse.
        let again = MailOps.label(["tb"], id: "Label_3", in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "tb").contains("Label_3"))
        MailOps.takeBack(again, in: store)
        #expect(store.thread("tb")?.labels.contains("Label_3") == false)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "tb").contains("Label_3"))
        // L with a label all of them carry: off them, and ⌘Z puts it back.
        let off = MailOps.label(["ta"], id: "Label_2", in: store)
        #expect(off.kinds == [.unlabel] && store.thread("ta")?.labels.contains("Label_2") == false)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "ta").contains("Label_2"))
        MailOps.takeBack(off, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "ta").contains("Label_2") && store.thread("ta")?.labels.contains("Label_2") == true)
    }

    @Test func moveLabelsArchivesAndLeavesTheListItCameFrom() async throws {
        let (store, gmail, fake, _) = try await seeded()
        // From Work/Clients' list to Receipts: on, out of the inbox, off Work/Clients.
        let acted = MailOps.move(["ta"], to: "Label_3", from: "Label_2", in: store)
        #expect(acted.kinds == [.label, .archive, .unlabel])
        let moved = store.thread("ta")?.labels ?? []
        #expect(moved.contains("Label_3") && !moved.contains("INBOX") && !moved.contains("Label_2"))
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "ta").contains("Label_3") && !labels(fake, "ta").contains("INBOX") && !labels(fake, "ta").contains("Label_2"))
        MailOps.takeBack(acted, in: store)
        let back = store.thread("ta")?.labels ?? []
        #expect(!back.contains("Label_3") && back.contains("INBOX") && back.contains("Label_2"))
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "ta").contains("Label_3") && labels(fake, "ta").contains("INBOX") && labels(fake, "ta").contains("Label_2"))
        // Out of the inbox already, and moved to a label it has: nothing to do.
        #expect(MailOps.move(["tc"], to: "Label_3", in: store).isEmpty)
    }

    @Test func unlabelTakesOffOnlyWhereItIs() async throws {
        let (store, gmail, fake, _) = try await seeded()
        let acted = MailOps.unlabel(["ta", "tb"], id: "Label_2", in: store)
        #expect(acted.entries.map(\.threads) == [["ta"]])
        #expect(store.thread("ta")?.labels.contains("Label_2") == false)
        try await MailOps.flush(store, gmail: gmail)
        #expect(!labels(fake, "ta").contains("Label_2"))
        MailOps.takeBack(acted, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "ta").contains("Label_2"))
    }

    @Test func manyAtOnceArePacksAndOneTakeBack() async throws {
        let (store, gmail, fake) = world()
        fake.labels = ["Label_1": "Receipts"]
        for n in 0..<30 {
            fake.add(.init(id: "m\(n)", thread: "t\(n)", from: "Shop <orders@shop.example>", subject: "Order \(n)", body: "Shipped.",
                           at: now.addingTimeInterval(Double(-n) * 3600), labels: ["INBOX"]), record: false)
        }
        try await MailSync(store: store, gmail: gmail).sync()
        let threads = (0..<30).map { "t\($0)" }
        let acted = MailOps.label(threads, id: "Label_1", in: store)
        #expect(acted.entries.count == 1 && acted.entries[0].parts.count == 1)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 1 && Set(fake.batches[0]) == Set((0..<30).map { "m\($0)" }))
        #expect(threads.allSatisfy { labels(fake, $0).contains("Label_1") })
        MailOps.takeBack(acted, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 2 && threads.allSatisfy { !labels(fake, $0).contains("Label_1") })
    }

    @Test func aLabelMadeAtGmailOnce() async throws {
        let (store, gmail, fake, _) = try await seeded()
        let made = try await gmail.makeLabel(named: "Travel")
        #expect(made.user && made.name == "Travel" && fake.labels[made.id] == "Travel")
        store.keep(label: made)
        #expect(store.labelID(exactly: "travel") == made.id)
        // Made since elsewhere: Gmail's 409, and the one there is the one.
        let again = try await gmail.makeLabel(named: "TRAVEL")
        #expect(again.id == made.id && fake.labels.count == 4)
    }

    // MARK: - a label's list, and G's

    @Test func aLabelsListHereThenOlderFromGmail() async throws {
        let (store, _, fake, sync) = try await seeded()
        let view = MailViews.prefix + "Work/Clients"
        // What this Mac keeps: the contract is older than the sync went.
        #expect(MailDesk.viewThreads(view, in: store).map(\.id) == ["ta"])
        let since = MailServerSearch.horizon(store)
        let query = try #require(MailViews.query(view, in: store))
        #expect(query.gmail == "label:Work/Clients before:\(Int(since.timeIntervalSince1970))")
        fake.calls = []
        let found = try await sync.search(query, pages: MailViews.pages)
        #expect(found.threads == ["to"] && !found.more)
        #expect(!fake.calls.contains("GET labels"))
        // Kept, it is in the list now, saying it came from Gmail.
        #expect(MailDesk.viewThreads(view, in: store).map(\.id) == ["ta", "to"])
        #expect(store.thread("to")?.backfilled == true)
        // A label this account hasn't: no list, nothing asked.
        #expect(MailDesk.viewThreads(MailViews.prefix + "Nowhere", in: store).isEmpty)
        // A name with spaces as Gmail's search takes one; a quote in it is no end.
        #expect(MailViews.query(MailViews.prefix + "Q3 Plans", horizon: since)?.gmail.hasPrefix("label:Q3-Plans before:") == true)
        #expect(MailViews.query(MailViews.prefix + "My \"Stuff\"", horizon: since)?.gmail.hasPrefix("label:My") == true)
    }

    @Test func gsListsInGmailsWords() {
        let since = Date(timeIntervalSince1970: 1_750_000_000)
        let said = { (view: String) in MailViews.query(view, horizon: since)?.gmail }
        #expect(said("starred") == "is:starred before:1750000000")
        #expect(said("sent") == "in:sent before:1750000000")
        #expect(said("spam") == "in:spam before:1750000000")
        #expect(said("trash") == "in:trash before:1750000000")
        #expect(said("done") == "-in:inbox -from:me before:1750000000")
        #expect(said("all") == "before:1750000000")
        // Only this Mac keeps them: nothing to ask.
        #expect(said("muted") == nil && said("later") == nil && said("needs") == nil)
        // Spam and Trash ask Gmail for what a search leaves out.
        #expect(MailViews.query("trash", horizon: since)?.wantsBin == true)
    }

    @Test func aListBeyondTheInboxIsReadAPageAtATime() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        let anna = MailPerson(name: "Anna", address: "anna@fold.studio")
        store.put((0..<250).map { n in
            MailMessage(id: "s\(n)", thread: "t\(n)", from: anna, subject: "Starred \(n)", date: now.addingTimeInterval(Double(-n) * 3600),
                        labels: n == 7 ? ["STARRED", "TRASH"] : ["STARRED"], replyTo: [])
        })
        let page = MailDesk.view("starred", in: store, limit: 100)
        #expect(page.threads.count == 100 && page.threads.first?.id == "t0" && page.total == 249)
        #expect(!page.threads.contains { $0.id == "t7" })
    }

    // MARK: - counts

    @Test func countsAreAskedForLabelsShownOnly() async throws {
        let (store, _, fake, sync) = try await seeded()
        // Nothing shown: nothing asked.
        #expect(!fake.calls.contains { $0.hasPrefix("GET labels/") })
        #expect(store.labels().allSatisfy { $0.unread == nil })
        await sync.set(shownLabels: ["Label_2"])
        fake.calls = []
        #expect(try await sync.countLabels())
        #expect(fake.calls == ["GET labels/Label_2"])
        let clients = store.labels().first { $0.id == "Label_2" }
        #expect(clients?.unread == 2 && clients?.threads == 2)
        // Asked again only once its mail changed, or ten minutes on.
        fake.calls = []
        #expect(try await sync.countLabels() == false && fake.calls.isEmpty)
        store.staleLabels(["Label_2"])
        _ = try await sync.countLabels()
        #expect(fake.calls == ["GET labels/Label_2"])
        fake.calls = []
        _ = try await sync.countLabels(now: Date().addingTimeInterval(MailSync.labelsEvery + 1))
        #expect(fake.calls == ["GET labels/Label_2"])
        // Mail read in it, heard from Gmail's history: counted again, one fewer.
        fake.messages["a1"]?.labels.remove("UNREAD")
        fake.history += 1
        fake.records.append((fake.history, [], [], [("a1", ["UNREAD"], false)]))
        fake.calls = []
        try await sync.sync()
        #expect(fake.calls.contains("GET labels/Label_2"))
        #expect(store.labels().first { $0.id == "Label_2" }?.unread == 1)
    }
}
