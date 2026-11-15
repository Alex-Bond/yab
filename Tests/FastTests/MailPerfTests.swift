import Foundation
import Testing
@testable import Fast
@testable import MailCore

// What the store answers in, on a mailbox of 50,000 messages kept in memory,
// with no window (PLAN-mail-superhuman.md 0.3, docs/mail.md Measuring and
// testing): a word typed in the search, the same right after the store
// changed beside the mail and right after new mail, the inbox's threads,
// the Needs you list. Each is the median of
// seven, held to the plan's budget; over it on a Mac too busy to measure is
// a known issue, and a ceiling catches it getting worse.
@Suite(.serialized)
struct MailPerfTests {
    /// 50,000 messages over five years in about 22,000 threads, as
    /// evals/mail/fake_gmail.py makes them: people, lists, tools, an inbox
    /// of the last weeks and an old one mostly archived, bodies for the
    /// newest threads.
    static let mailbox: MailStore = {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        var maker = MailboxMaker(seed: 7)
        store.put(maker.messages(50_000))
        return store
    }()

    /// The median of `runs` timings of `work`, in ms.
    func median(_ runs: Int = 7, _ work: () -> Void) -> Double {
        work()
        let times = (0..<runs).map { _ -> Double in
            let start = Date()
            work()
            return Date().timeIntervalSince(start) * 1000
        }
        return times.sorted()[runs / 2]
    }

    func record(_ what: String, _ ms: Double, budget: Double, ceiling: Double) {
        print("MailPerf \(what): \(String(format: "%.1f", ms)) ms (budget \(Int(budget)), ceiling \(Int(ceiling)))")
        #expect(ms < ceiling, "\(what) took \(ms) ms, over the ceiling of \(ceiling)")
        if ms >= budget {
            withKnownIssue("\(what) is over its budget of \(budget) ms (a busy Mac)", isIntermittent: true) {
                #expect(ms < budget)
            }
        }
    }

    @Test func theMailboxIsWhole() {
        let store = Self.mailbox
        #expect(store.messageIDs().count == 50_000)
        #expect(store.threadCount() > 15_000)
        #expect(!store.threads(label: "INBOX").isEmpty)
    }

    @Test func aWordInTheSearch() {
        let store = Self.mailbox
        for word in ["d", "de", "deck", "invoice friday", "lindqvist"] {
            let ms = median { _ = store.search(word) }
            record("search \"\(word)\"", ms, budget: 30, ceiling: 200)
        }
        #expect(!store.search("deck").isEmpty)
    }

    @Test func aWordRightAfterAChange() {
        // A change beside the mail (what was worked out about a thread) and
        // the next word typed: the word index's map of threads stays.
        let store = Self.mailbox
        var n = 0
        let ms = median(5) {
            n += 1
            store.keep(MailSensed(thread: "pt\(n)", message: "p\(n)", needs: false, gist: "", due: nil, kind: .other))
            _ = store.search("d")
        }
        record("search \"d\" right after a change", ms, budget: 30, ceiling: 300)
        // New mail: the map made again first, off the main thread in the
        // app (MailSearch), so said and held to a ceiling only.
        let made = median(3) {
            n += 1
            store.put([MailMessage(id: "pn\(n)", thread: "ptn\(n)", from: MailPerson(name: "New", address: "new@example.org"),
                                   subject: "New \(n)", date: Date(), labels: ["INBOX"], replyTo: [], text: "deck")])
            _ = store.search("d")
        }
        print("MailPerf search \"d\" right after new mail: \(String(format: "%.1f", made)) ms (the map made again, ceiling 400)")
        #expect(made < 400)
        // The mailbox as the other tests have it.
        store.remove(messages: (1...n).map { "pn\($0)" })
    }

    @Test func theInboxThreads() {
        let store = Self.mailbox
        let ms = median { _ = store.threads(label: "INBOX") }
        record("threads(label: INBOX)", ms, budget: 10, ceiling: 100)
        #expect(store.threads(label: "INBOX").count == 100)
    }

    @Test func theNeedsYouList() {
        let store = Self.mailbox
        // Read as after a change, each a minute on so what the store kept
        // of the splits' facts (MailStore.facts) isn't used; then again
        // with nothing changed, as the column and the pin read it.
        var later = 0.0
        let ms = median(5) {
            later += 60
            _ = MailSplit.threads(.needs, in: store, now: Date().addingTimeInterval(later))
        }
        record("Needs you", ms, budget: 10, ceiling: 300)
        let again = median(5) { _ = MailSplit.threads(.needs, in: store) }
        record("Needs you again", again, budget: 10, ceiling: 300)
        #expect(!MailSplit.threads(.needs, in: store).isEmpty)
    }

    /// The whole inbox placed among splits as a person has them (Splits):
    /// VIP of three, Team, Calendar with an invitation in 300 threads,
    /// Receipts, Dev's domains, a split of words and one of a person's mail
    /// beside Needs you. Placing, once a reading of the facts, with the
    /// store's answers kept; and those answers asked anew, which happens off
    /// the main thread once mail came (MailSplitCache).
    @Test func theSplitsPlaceTheInbox() {
        let store = Self.mailbox
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:perf\r\nDTSTART:20261006T120000Z\r\nDURATION:PT30M\r\n"
            + "ORGANIZER:mailto:anna@fold.studio\r\nSUMMARY:Call\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        for (n, fact) in store.facts(now: Date()).filter(\.inbox).prefix(300).enumerated() {
            store.keepInvite(message: "perf-invite-\(n)", thread: fact.id, at: Date(), ics: ics.replacingOccurrences(of: "UID:perf", with: "UID:perf\(n)"))
        }
        let splits = [MailList.Split(id: "vip", title: "VIP", q: "from:anna@fold.studio from:mark@northwind.vc from:priya@nair.dev"),
                      MailList.Split(id: "team", title: "Team", q: "team:domain"),
                      MailList.Split(id: "calendar", title: "Calendar", q: "kind:meeting"),
                      MailList.Split(id: "receipts", title: "Receipts", q: "kind:invoice"),
                      MailList.Split(id: "dev", title: "Dev", q: MailRule.line(MailSplits.dev.map { MailRule(kind: "from", value: $0) })),
                      MailList.Split(title: "Deck", q: "words:deck"),
                      MailList.Split(title: "With Lena", q: "with:lena@acme.com", mode: .also)]
        let sort = MailSplitSort(splits, order: splits.map(\.id))
        let facts = store.facts(now: Date())
        var answers = sort.answers(store, among: nil, now: Date())
        let asked = median(5) { answers = sort.answers(store, among: nil, now: Date()) }
        record("splits' answers", asked, budget: 50, ceiling: 500)
        let placing = median { _ = sort.place(facts, me: store.me, answers: answers, now: Date()) }
        // Not a key's wait: once a reading of the facts, after a change.
        record("splits placing the inbox", placing, budget: 20, ceiling: 150)
        #expect(!sort.place(facts, me: store.me, answers: answers, now: Date()).isEmpty)
    }
}

/// Mail made up the way the fake Gmail's generator makes it, in Swift, from a
/// seed: the same every run.
struct MailboxMaker {
    var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func pick<T>(_ list: [T]) -> T { list[Int(next() % UInt64(list.count))] }

    static let first = ["Anna", "Mark", "Priya", "Tim", "Lena", "Kai", "Sofia", "Jonas", "Mira", "Omar", "Elena", "Lucas", "Hana", "Diego",
                        "Noor", "Felix", "Ines", "Yuki", "Arjun", "Clara", "Nika", "Pavel", "Grace", "Theo"]
    static let last = ["Lindqvist", "Chen", "Nair", "Okafor", "Hoffmann", "Brandt", "Rossi", "Weber", "Novak", "Haddad", "Petrova", "Silva",
                       "Tanaka", "Garcia", "Rahman", "Klein", "Moreau", "Sato", "Iyer", "Larsen", "Orlova", "Kim"]
    static let orgs = ["fold.studio", "northwind.vc", "nair.dev", "acme.com", "globex.io", "initech.com", "hooli.xyz", "gmail.com", "outlook.com"]
    static let words = ("the deck plan launch review numbers budget draft contract meeting call notes slides pricing design onboarding "
        + "invoice report roadmap hiring offer feedback schedule quarter revenue users growth churn metrics proposal timeline update "
        + "friday monday next week tomorrow morning office lisbon berlin flight hotel dinner photos files version copy final edits")
        .split(separator: " ").map(String.init)
    static let topics = ["Q3 numbers", "Launch plan", "Contract draft", "Offsite in Lisbon", "Hiring: senior iOS", "Pricing page", "Board deck",
                         "Design review", "Investor update", "Onboarding flow", "Logo files", "Dinner on Saturday?", "Lease renewal"]

    mutating func sentence() -> String {
        (0..<(6 + Int(next() % 10))).map { _ in pick(Self.words) }.joined(separator: " ").capitalized + "."
    }

    mutating func messages(_ count: Int, now: Date = Date()) -> [MailMessage] {
        var out: [MailMessage] = []
        out.reserveCapacity(count)
        let people = (0..<400).map { _ -> MailPerson in
            let first = pick(Self.first), last = pick(Self.last)
            return MailPerson(name: "\(first) \(last)", address: "\(first.lowercased()).\(last.lowercased())@\(pick(Self.orgs))")
        }
        let lists = (0..<90).map { n in MailPerson(name: "Letter \(n)", address: "news@letter\(n).com") }
        let me = MailPerson(name: "", address: "me@example.com")
        let span = 5 * 365 * 86_400.0
        var thread = 0
        while out.count < count {
            thread += 1
            let age = span * pow(unit(), 1.7)
            let kind = unit()
            let inbox = unit() < (age < 14 * 86_400 ? 0.85 : age < 365 * 86_400 ? 0.22 : 0.07)
            var at = now.addingTimeInterval(-age)
            if kind < 0.36 {
                let who = people[min(people.count - 1, Int(Double(people.count) * pow(unit(), 3)))]
                let size = unit() < 0.55 ? 1 : pick([2, 2, 2, 3, 3, 4, 5, 6, 8, 11, 17, 24])
                let subject = pick(Self.topics)
                for n in 0..<size where out.count < count {
                    let mine = n % 2 == 1
                    at = min(now.addingTimeInterval(-30), at.addingTimeInterval(n == 0 ? 0 : 9 * 3600 * -log(max(unit(), 1e-9))))
                    var labels: Set<String> = mine ? ["SENT"] : inbox ? ["INBOX"] : []
                    if !mine, inbox, now.timeIntervalSince(at) < 4 * 86_400, unit() < 0.6 { labels.insert("UNREAD") }
                    out.append(message(out.count, thread, from: mine ? me : who, to: mine ? who : me, subject: (n > 0 ? "Re: " : "") + subject,
                                       at: at, labels: labels, bulk: false, recent: age < 30 * 86_400))
                }
            } else {
                let tool = kind > 0.78
                let who = tool ? MailPerson(name: "GitHub", address: "notifications@github.com") : lists[min(lists.count - 1, Int(90 * pow(unit(), 2)))]
                var labels: Set<String> = tool ? ["CATEGORY_UPDATES"] : [pick(["CATEGORY_UPDATES", "CATEGORY_PROMOTIONS"])]
                if inbox { labels.insert("INBOX") }
                if inbox, unit() < 0.6 { labels.insert("UNREAD") }
                out.append(message(out.count, thread, from: who, to: me, subject: "\(who.name) #\(next() % 400)", at: at, labels: labels,
                                   bulk: true, recent: age < 30 * 86_400))
            }
        }
        return out
    }

    mutating func message(_ n: Int, _ thread: Int, from: MailPerson, to: MailPerson, subject: String, at: Date, labels: Set<String>,
                          bulk: Bool, recent: Bool) -> MailMessage {
        let line = sentence()
        // Bodies for what came lately, as a first sync fetches ahead.
        let text = recent ? (0..<(3 + Int(next() % 12))).map { _ in sentence() }.joined(separator: " ") : nil
        return MailMessage(id: "p\(n)", thread: "pt\(thread)", from: from, to: [to], subject: subject, snippet: line, date: at, labels: labels,
                           rfcID: "<p\(n)@example.com>", listUnsubscribe: bulk, replyTo: [], text: text.map { line + " " + $0 })
    }
}
