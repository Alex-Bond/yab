import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Mail's searches in Gmail's words (docs/mail.md, Search): every operator
// read as Gmail reads it, written back as Gmail takes it, answered by the
// store in memory, and what the Mac finds merged with what Gmail found.

@Suite(.serialized)
struct MailQueryTests {
    typealias Term = MailQuery.Term

    /// Days in UTC, so a date reads the same on any Mac.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func parse(_ text: String) -> Term? { MailQuery.parse(text, calendar: Self.utc).root }

    func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - reading

    @Test func everyOperator() {
        #expect(parse("from:anna") == .person(.from, "anna"))
        #expect(parse("to:mark@northwind.vc") == .person(.to, "mark@northwind.vc"))
        #expect(parse("cc:tim") == .person(.cc, "tim"))
        #expect(parse("bcc:tim") == .person(.bcc, "tim"))
        #expect(parse("subject:invoice") == .text("invoice", .subject, exact: false))
        #expect(parse("has:attachment") == .has("attachment"))
        #expect(parse("is:unread") == .flag("unread"))
        #expect(parse("is:Starred") == .flag("starred"))
        #expect(parse("label:receipts") == .label("receipts", box: false))
        #expect(parse("in:inbox") == .label("inbox", box: true))
        #expect(parse("in:anywhere") == .anywhere)
        #expect(parse("category:primary") == .label("CATEGORY_PERSONAL", box: true))
        #expect(parse("category:updates") == .label("CATEGORY_UPDATES", box: true))
        #expect(parse("size:5M") == .other("size", "5M"))
        #expect(parse("FROM:anna") == .person(.from, "anna"))
        // Not one of Gmail's: a word, as Gmail reads it.
        #expect(parse("note:this") == .text("note:this", .all, exact: false))
        #expect(parse("10:30") == .text("10:30", .all, exact: false))
    }

    @Test func wordsSpacesAndQuotes() {
        #expect(parse("from:anna invoice") == .all([.person(.from, "anna"), .text("invoice", .all, exact: false)]))
        #expect(parse("\"board deck\" review") == .all([.text("board deck", .all, exact: true), .text("review", .all, exact: false)]))
        #expect(parse("subject:\"board deck\"") == .text("board deck", .subject, exact: true))
        #expect(parse("from:\"Anna Lindqvist\"") == .person(.from, "Anna Lindqvist"))
        // An unclosed quote runs to the end.
        #expect(parse("\"board deck") == .text("board deck", .all, exact: true))
        #expect(parse("   ") == nil)
        #expect(parse("@ !") == nil)
        #expect(MailQuery.parse("").isEmpty)
    }

    @Test func minus() {
        #expect(parse("-label:work") == .not(.label("work", box: false)))
        #expect(parse("invoice -\"past due\"") == .all([.text("invoice", .all, exact: false), .not(.text("past due", .all, exact: true))]))
        #expect(parse("-(from:anna invoice)") == .not(.all([.person(.from, "anna"), .text("invoice", .all, exact: false)])))
        // Inside a word, or alone, a dash is no minus.
        #expect(parse("e-mail") == .text("e-mail", .all, exact: false))
        #expect(parse("deck - v3") == .all([.text("deck", .all, exact: false), .text("v3", .all, exact: false)]))
    }

    @Test func orBindsCloserThanSpace() {
        // Gmail: (from:amy OR from:david) AND invoice.
        #expect(parse("from:amy OR from:david invoice") ==
            .all([.any([.person(.from, "amy"), .person(.from, "david")]), .text("invoice", .all, exact: false)]))
        #expect(parse("a OR b OR c") == .any([.text("a", .all, exact: false), .text("b", .all, exact: false), .text("c", .all, exact: false)]))
        #expect(parse("{from:amy from:david}") == .any([.person(.from, "amy"), .person(.from, "david")]))
        // Only Gmail's capital OR is an OR; AND is said or not.
        #expect(parse("cats or dogs") == .all([.text("cats", .all, exact: false), .text("or", .all, exact: false), .text("dogs", .all, exact: false)]))
        #expect(parse("cats AND dogs") == .all([.text("cats", .all, exact: false), .text("dogs", .all, exact: false)]))
    }

    @Test func parentheses() {
        #expect(parse("(invoice OR receipt) from:stripe") ==
            .all([.any([.text("invoice", .all, exact: false), .text("receipt", .all, exact: false)]), .person(.from, "stripe")]))
        #expect(parse("((a))") == .text("a", .all, exact: false))
        #expect(parse("subject:(board deck)") == .all([.text("board", .subject, exact: false), .text("deck", .subject, exact: false)]))
        #expect(parse("from:(anna OR mark)") == .any([.person(.from, "anna"), .person(.from, "mark")]))
        #expect(parse("-(a OR b)") == .not(.any([.text("a", .all, exact: false), .text("b", .all, exact: false)])))
        // Unbalanced: what is there is read.
        #expect(parse("(a b") == .all([.text("a", .all, exact: false), .text("b", .all, exact: false)]))
        #expect(parse("a) b") == .all([.text("a", .all, exact: false), .text("b", .all, exact: false)]))
    }

    @Test func accentedWords() {
        #expect(parse("reçu de:anna") == .all([.text("reçu", .all, exact: false), .text("de:anna", .all, exact: false)]))
        #expect(parse("subject:Grüße") == .text("Grüße", .subject, exact: false))
        #expect(MailQuery.tokens("Reçu pour AVRIL") == ["recu", "pour", "avril"])
        #expect(MailQuery.words("Reçu pour AVRIL") == ["Reçu", "pour", "AVRIL"])
        #expect(MailQuery.parse("\"reçu pour avril\" -spam").lit == ["reçu", "pour", "avril"])
    }

    @Test func labelsWithSlashes() {
        #expect(parse("label:work/clients") == .label("work/clients", box: false))
        #expect(parse("-label:Work/Clients/2024 deck") == .all([.not(.label("Work/Clients/2024", box: false)), .text("deck", .all, exact: false)]))
        #expect(MailQuery.parse("label:\"my list\"").gmail == "label:my-list")
        #expect(MailQuery.parse("label:work/clients").gmail == "label:work/clients")
        // Gmail's own boxes are known; one of yours by the name learned.
        #expect(MailQuery.labelID("Inbox", known: { _ in nil }) == "INBOX")
        #expect(MailQuery.labelID("work/clients", known: { _ in nil }) == nil)
        #expect(!MailQuery.parse("label:work/clients").answerable(labels: { _ in nil }))
        #expect(MailQuery.parse("label:work/clients").answerable(labels: { $0 == "work/clients" ? "Label_7" : nil }))
        #expect(MailQuery.parse("label:work/clients in:inbox").labelNames == ["work/clients"])
    }

    @Test func datesInGmailsFormats() {
        #expect(parse("before:2024/01/31") == .before(day(2024, 1, 31)))
        #expect(parse("after:2024-1-5") == .after(day(2024, 1, 5)))
        #expect(parse("before:01/31/2024") == .before(day(2024, 1, 31)))
        #expect(parse("after:2024.03.02") == .after(day(2024, 3, 2)))
        #expect(parse("older:2023/12/01") == .before(day(2023, 12, 1)))
        #expect(parse("newer:2023/12/01") == .after(day(2023, 12, 1)))
        #expect(parse("after:1704067200") == .after(Date(timeIntervalSince1970: 1_704_067_200)))
        // No such day: Gmail's to read.
        #expect(parse("before:2024/02/30") == .other("before", "2024/02/30"))
        #expect(parse("before:soon") == .other("before", "soon"))
        #expect(parse("older_than:2y") == .older(2, .year))
        #expect(parse("newer_than:3d") == .newer(3, .day))
        #expect(parse("newer_than:2w") == .newer(14, .day))
        #expect(parse("older_than:6m") == .older(6, .month))
        #expect(parse("older_than:3x") == .other("older_than", "3x"))
    }

    @Test func gmailReadsItBack() {
        let cases = [
            "from:anna (invoice OR receipt) -label:spam older_than:1y",
            "subject:\"board deck\" has:attachment is:unread",
            "to:me -in:inbox category:updates newer_than:3d",
            "\"past due\" -(from:stripe OR from:apple)",
        ]
        for text in cases {
            let query = MailQuery.parse(text, calendar: Self.utc)
            #expect(query.gmail == text, "\(text) became \(query.gmail)")
            #expect(MailQuery.parse(query.gmail, calendar: Self.utc).root == query.root)
        }
        // A day goes as its moment, so Gmail's midnight is this Mac's.
        #expect(MailQuery.parse("from:anna before:2024/01/31", calendar: Self.utc).gmail == "from:anna before:1706659200")
        #expect(MailQuery.parse("{a b} c").gmail == "(a OR b) c")
        #expect(MailQuery.person("with", "anna@fold.studio", words: "deck").gmail
            == "(from:anna@fold.studio OR to:anna@fold.studio OR cc:anna@fold.studio) deck")
    }

    @Test func whatOnlyGmailCanAnswer() {
        let now = Date()
        let horizon = now.addingTimeInterval(-60 * 86_400)
        let known: (String) -> String? = { _ in nil }
        #expect(!MailQuery.parse("size:5M").answerable(labels: known))
        #expect(!MailQuery.parse("bcc:tim").answerable(labels: known))
        #expect(!MailQuery.parse("is:muted").answerable(labels: known))
        #expect(MailQuery.parse("has:userlabels is:read").answerable(labels: known))
        // Files: by what each mail kept says of its own (MailMessage.attached).
        #expect(MailQuery.parse("has:attachment from:anna").answerable(labels: known))
        // older_than:2y, before: anything: past what the Mac keeps.
        #expect(MailQuery.parse("older_than:2y").reachesPast(horizon, now: now))
        #expect(MailQuery.parse("invoice before:2030/01/01").reachesPast(horizon, now: now))
        #expect(MailQuery.parse("after:2020/01/01 deck").reachesPast(horizon, now: now))
        #expect(MailQuery.parse("newer_than:1y").reachesPast(horizon, now: now))
        #expect(!MailQuery.parse("newer_than:3d invoice").reachesPast(horizon, now: now))
        #expect(!MailQuery.parse("from:anna invoice").reachesPast(horizon, now: now))
        // Not newer than a year: older than one.
        #expect(MailQuery.parse("-newer_than:1y").reachesPast(horizon, now: now))
        #expect(!MailQuery.parse("-older_than:3d").reachesPast(horizon, now: now))
        // Gmail is asked when the Mac can't tell, finds few, or the search reaches past.
        #expect(MailServerSearch.wanted(MailQuery.parse("deck"), found: 3, answered: true, horizon: horizon))
        #expect(!MailServerSearch.wanted(MailQuery.parse("deck"), found: 12, answered: true, horizon: horizon))
        #expect(MailServerSearch.wanted(MailQuery.parse("deck older_than:2y"), found: 40, answered: true, horizon: horizon))
        #expect(MailServerSearch.wanted(MailQuery.parse("size:5M"), found: 0, answered: false, horizon: horizon))
        #expect(!MailServerSearch.wanted(MailQuery.parse(""), found: 0, answered: true, horizon: horizon))
    }

    // MARK: - the store's answer

    /// A mailbox kept in memory: Anna's invoice a year old, Mark's reply
    /// with Anna in Cc under a label of yours, yours to Anna Müller in French, a
    /// deck from a list, an invoice thrown away.
    func mailbox(now: Date = Date()) -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        store.learn(labels: [(id: "Label_7", name: "Work/Clients"), (id: "INBOX", name: "INBOX")])
        let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")
        let me = MailPerson(name: "", address: "me@example.com")
        store.put([
            MailMessage(id: "a1", thread: "ta", from: anna, to: [me], subject: "Invoice for March", snippet: "Please find the invoice",
                        date: now.addingTimeInterval(-365 * 86_400), labels: ["INBOX", "UNREAD"], replyTo: [],
                        text: "Please find the invoice attached. Thanks!"),
            MailMessage(id: "b1", thread: "tb", from: MailPerson(name: "Mark Chen", address: "mark@northwind.vc"), to: [me], cc: [anna],
                        subject: "Re: the invoice", snippet: "Paid on Friday", date: now.addingTimeInterval(-10 * 86_400),
                        labels: ["INBOX", "STARRED", "Label_7"], replyTo: [], text: "Paid on Friday."),
            MailMessage(id: "c1", thread: "tc", from: me, to: [MailPerson(name: "Anna Müller", address: "anna.m@gmx.de")],
                        subject: "Reçu pour avril", snippet: "Bonjour", date: now.addingTimeInterval(-3 * 86_400), labels: ["SENT"],
                        replyTo: [], text: "Bonjour! Le reçu est joint."),
            MailMessage(id: "d1", thread: "td", from: MailPerson(name: "Fold Weekly", address: "news@fold.studio"), to: [me],
                        subject: "The board deck, v3", snippet: "Ten links", date: now.addingTimeInterval(-86_400),
                        labels: ["INBOX", "CATEGORY_UPDATES"], listUnsubscribe: true, replyTo: [], text: "Our board deck and ten links."),
            MailMessage(id: "e1", thread: "te", from: anna, to: [me], subject: "Old invoice", snippet: "Thrown away",
                        date: now.addingTimeInterval(-5 * 86_400), labels: ["TRASH"], replyTo: [], text: "An invoice nobody wanted."),
        ])
        return store
    }

    func ids(_ store: MailStore, _ text: String) -> [String] {
        let found = store.find(MailQuery.parse(text, calendar: Self.utc), limit: 100)
        #expect(found.total == found.threads.count)
        return found.threads.map(\.id)
    }

    @Test func theStoreAnswersEveryOperator() {
        let store = mailbox()
        #expect(ids(store, "invoice") == ["tb", "ta"])
        // From finds only their own: Anna in Mark's Cc isn't from her.
        #expect(ids(store, "from:anna") == ["ta"])
        #expect(ids(store, "from:anna@fold.studio") == ["ta"])
        #expect(ids(store, "from:fold.studio") == ["td", "ta"])
        #expect(ids(store, "from:anna invoice") == ["ta"])
        #expect(ids(store, "from:me") == ["tc"])
        // To is anyone it was sent to, Cc too.
        #expect(ids(store, "to:anna") == ["tc", "tb"])
        #expect(ids(store, "cc:anna") == ["tb"])
        #expect(ids(store, "to:müller") == ["tc"])
        #expect(ids(store, "subject:invoice") == ["tb", "ta"])
        #expect(ids(store, "subject:\"board deck\"") == ["td"])
        #expect(ids(store, "\"deck board\"").isEmpty)
        #expect(ids(store, "is:unread") == ["ta"])
        #expect(ids(store, "is:starred") == ["tb"])
        #expect(ids(store, "is:read invoice") == ["tb"])
        #expect(ids(store, "in:inbox -category:updates") == ["tb", "ta"])
        #expect(ids(store, "label:work/clients") == ["tb"])
        #expect(ids(store, "label:work-clients") == ["tb"])
        // -label: leaves out.
        #expect(ids(store, "invoice -label:work/clients") == ["ta"])
        #expect(ids(store, "has:userlabels") == ["tb"])
        #expect(ids(store, "invoice OR deck") == ["td", "tb", "ta"])
        #expect(ids(store, "(from:mark OR from:anna) -is:starred") == ["ta"])
        #expect(ids(store, "reçu") == ["tc"])
        #expect(ids(store, "REÇU joint") == ["tc"])
        #expect(ids(store, "bonjour") == ["tc"])
        // Dates.
        #expect(ids(store, "invoice older_than:6m") == ["ta"])
        #expect(ids(store, "invoice newer_than:30d") == ["tb"])
        let year = Self.utc.component(.year, from: Date())
        #expect(ids(store, "invoice before:\(year + 1)/01/01").contains("ta"))
        // Spam and Trash only when asked for.
        #expect(!ids(store, "invoice").contains("te"))
        #expect(ids(store, "invoice in:trash") == ["te"])
        #expect(ids(store, "\"nobody wanted\" in:anywhere") == ["te"])
    }

    @Test func whatTheMacCantTellIsGmails() {
        let store = mailbox()
        let found = store.find(MailQuery.parse("size:5M from:anna"))
        #expect(!found.answered && found.threads.isEmpty && found.total == 0)
        // Files are told here: a mail Gmail said carries some.
        #expect(store.find(MailQuery.parse("has:attachment")).answered && ids(store, "has:attachment").isEmpty)
        store.markAttached(["a1"])
        #expect(ids(store, "has:attachment from:anna") == ["ta"])
        #expect(!store.find(MailQuery.parse("label:receipts")).answered)
        // A label learned is answered here from then on.
        store.learn(labels: [(id: "Label_9", name: "Receipts")])
        #expect(store.find(MailQuery.parse("label:receipts")).answered)
        #expect(store.labelID(named: "receipts") == "Label_9")
    }

    @Test func aMessageAndAThreadInHand() throws {
        let store = mailbox()
        let a1 = try #require(store.message("a1"))
        let me = "me@example.com"
        #expect(MailQuery.parse("from:anna invoice").matches(a1, me: me))
        #expect(MailQuery.parse("from:annabel").matches(a1, me: me) == false)
        #expect(MailQuery.parse("\"find the invoice\"").matches(a1, me: me))
        #expect(MailQuery.parse("subject:march is:unread").matches(a1, me: me))
        #expect(MailQuery.parse("older_than:6m -in:sent").matches(a1, me: me))
        #expect(!MailQuery.parse("has:attachment").matches(a1, me: me))
        var filed = a1
        filed.attached = true
        #expect(MailQuery.parse("has:attachment invoice").matches(filed, me: me))
        let b1 = try #require(store.message("b1"))
        #expect(MailQuery.parse("cc:anna label:work/clients").matches(b1, me: me, labels: { store.labelID(named: $0) }))
        let c1 = try #require(store.message("c1"))
        #expect(MailQuery.parse("from:me to:müller recu").matches(c1, me: me))
        // The thread as a list shows it.
        let ta = try #require(store.thread("ta"))
        #expect(MailQuery.parse("from:lindqvist is:unread in:inbox").matches(ta, me: me))
        #expect(!MailQuery.parse("is:starred").matches(ta, me: me))
        #expect(!MailQuery.parse("to:me").matches(ta, me: me))
        let te = try #require(store.thread("te"))
        #expect(!MailQuery.parse("invoice").matches(te, me: me))
        #expect(MailQuery.parse("invoice in:anywhere").matches(te, me: me))
    }

    /// The Mac's own and Gmail's together: newest first, no thread twice,
    /// Gmail's own marked, all of them counted.
    @MainActor
    @Test func mergedWithoutRepeatsInDateOrder() async throws {
        let store = mailbox()
        let query = MailQuery.parse("invoice")
        // What Gmail found: one the Mac found too (tb), two it didn't, one older than all.
        let now = Date()
        store.put([
            MailMessage(id: "g1", thread: "tg1", from: MailPerson(name: "Ledgerly", address: "billing@ledgerly.io"), subject: "Invoice #12",
                        snippet: "Due", date: now.addingTimeInterval(-30 * 86_400), labels: [], replyTo: []),
            MailMessage(id: "g2", thread: "tg2", from: MailPerson(name: "Ledgerly", address: "billing@ledgerly.io"), subject: "Your bill",
                        snippet: "Due", date: now.addingTimeInterval(-800 * 86_400), labels: [], replyTo: []),
        ], backfilled: true)
        let engine = MailCenter.Engine(account: "me@example.com", store: store, gmail: MailGmail(token: { "" }),
                                       sync: MailSync(store: store, gmail: MailGmail(token: { "" })))
        // Ids Gmail answered with, its newest first (as MailSync.search gives them).
        let gmail = ["tb", "tg1", "tg2"]
        let merged = MailDesk.merge(here: store.find(query, limit: 10, among: gmail), gmail: gmail, in: engine, limit: 10)
        #expect(merged.rows.map(\.thread) == ["tb", "tg1", "ta", "tg2"])
        #expect(merged.rows.map(\.gmail) == [false, true, false, true])
        #expect(merged.total == 4)
        // Cut at a page: the newest of all of them, all of them counted once.
        let page = MailDesk.merge(here: store.find(query, limit: 2, among: gmail), gmail: gmail, in: engine, limit: 2)
        #expect(page.rows.map(\.thread) == ["tb", "tg1"])
        #expect(page.total == 4)
        #expect(store.find(query, limit: 1, among: gmail).among == ["tb", "tg1"])
    }
}
