import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Speed with numbers (PLAN-mail-superhuman.md P0.5, docs/mail.md Measuring
// and testing): what makes mail fast has to stay right. The first screen
// after Connect comes before the rest of a first sync; a fetch ahead of a
// thread left behind asks Gmail nothing; the store's read-only look sees
// what was written; a search of words alone, answered by the word index and
// the store's map of threads, finds what the whole query finds, and the
// map is made again only when the mail changes; what was worked out about
// many threads goes in at once.
@Suite(.serialized)
struct MailSpeedTests {
    let now = Date()

    /// A Gmail of its own, by its host, so this suite runs beside MailSyncTests.
    func world(pace: MailPace? = nil, fake given: FakeGmail? = nil) -> (MailStore, MailGmail, FakeGmail) {
        let fake = given ?? FakeGmail()
        let host = "speed-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01, pace: pace)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).sqlite")
        return (MailStore(file: file), gmail, fake)
    }

    final class Told: @unchecked Sendable {
        let lock = NSLock()
        var first: (inbox: Int, calls: [String])?
    }

    @Test func theFirstScreenComesBeforeTheRest() async throws {
        let (store, gmail, fake) = world()
        fake.pageSize = 500
        // Sixty threads in the inbox, newest first an hour apart; mail of yours.
        for n in 0..<60 {
            fake.add(.init(id: "i\(n)", thread: "ti\(n)", from: "Person \(n) <p\(n)@example.org>", subject: "Question \(n)",
                           body: "Could you look at \(n)?", at: now.addingTimeInterval(-3600 * Double(n + 1)), labels: ["INBOX"]), record: false)
        }
        for n in 0..<5 {
            fake.add(.init(id: "s\(n)", thread: "ts\(n)", from: "me@example.com", to: "p\(n)@example.org", subject: "Re: hello \(n)",
                           body: "Thanks.", at: now.addingTimeInterval(-7200 * Double(n + 1)), labels: ["SENT"]), record: false)
        }
        let told = Told()
        let sync = MailSync(store: store, gmail: gmail) {
            told.lock.lock(); defer { told.lock.unlock() }
            if told.first == nil { told.first = (store.threads(label: "INBOX", limit: 100).count, fake.calls) }
        }
        try await sync.sync()
        let first = try #require(told.first)
        // Told with the inbox's newest fifty in the store: the account, one
        // list, a mail each; no other list asked before them.
        #expect(first.inbox >= 50)
        #expect(first.calls.first == "GET profile" || first.calls.first == "GET messages")
        #expect(first.calls.filter { $0 == "GET messages" }.count == 1)
        #expect(first.calls.filter { $0.hasPrefix("GET messages/") }.count >= 50)
        // And the rest came after: the whole inbox, mail of yours, each asked once.
        #expect(store.threads(label: "INBOX", limit: 100).count == 60)
        let gets = fake.calls.filter { $0.hasPrefix("GET messages/") }
        #expect(Set(gets).count == gets.count)
    }

    @Test func aFetchAheadLeftBehindAsksNothing() async throws {
        // Gmail's pace spent: the next call waits its turn, and is no longer
        // wanted by then.
        let pace = MailPace(rate: 1, burst: 0)
        await pace.take(20)
        let (store, gmail, fake) = world(pace: pace)
        store.set("me", "me@example.com")
        let old = now.addingTimeInterval(-45 * 86_400)
        fake.add(.init(id: "q1", thread: "tq", from: "Lena Brandt <lena@acme.com>", subject: "Older", body: "Forty-five days ago.",
                       at: old, labels: ["INBOX"]), record: false)
        // Kept by its headers only, as an old inbox's mail is.
        store.put([MailMessage(id: "q1", thread: "tq", from: MailPerson(name: "Lena Brandt", address: "lena@acme.com"), subject: "Older",
                               date: old, labels: ["INBOX"], replyTo: [])])
        let sync = MailSync(store: store, gmail: gmail)
        let ahead = Task { await sync.prefetch(threads: ["tq"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        ahead.cancel()
        await ahead.value
        #expect(!fake.calls.contains("GET messages/q1") && !fake.calls.contains("GET threads/tq"))
        #expect(store.message("q1")?.text == nil)
        // Wanted again, with the pace back: it comes, one mail by itself (20 units).
        let (_, quick, _) = world(fake: fake)
        await MailSync(store: store, gmail: quick).prefetch(threads: ["tq"])
        #expect(store.message("q1")?.text == "Forty-five days ago.")
        #expect(fake.calls.filter { $0 == "GET messages/q1" }.count == 1)
    }

    @Test func theReadOnlyLookSeesWhatWasWritten() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).sqlite")
        let store = MailStore(file: file)
        #expect(store.off !== store)
        store.put([MailMessage(id: "m1", thread: "t1", from: MailPerson(name: "", address: "me@example.com"), subject: "Mine",
                               date: now, labels: ["SENT"], replyTo: [])])
        #expect(store.off.thread("t1")?.subject == "Mine")
        // The account's address learned after the look was opened: read again.
        #expect(store.off.thread("t1")?.lastIsMine == false)
        store.set("me", "me@example.com")
        #expect(store.off.thread("t1")?.lastIsMine == true)
        // A store in memory is its own look.
        let memory = MailStore(file: MailStore.memory)
        #expect(memory.off === memory)
    }

    @Test func wordsAloneFindWhatTheWholeQueryFinds() {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        var maker = MailboxMaker(seed: 11)
        store.put(maker.messages(3_000))
        // Mail thrown away is left out either way.
        store.put([MailMessage(id: "bin", thread: "tbin", from: MailPerson(name: "Deck Bin", address: "bin@example.org"),
                               subject: "Deck in the bin", date: now, labels: ["TRASH"], replyTo: [], text: "deck deck")])
        let among = store.threads(label: "INBOX", limit: 40).map(\.id)
        for words in ["d", "de", "deck", "invoice friday", "lindqvist", "q3 numbers", "zzzz"] {
            // Words alone: the index and the store's map; with a date that
            // leaves nothing out, the whole query in SQL.
            let quick = store.find(MailQuery.parse(words), limit: 30, among: among)
            let whole = store.find(MailQuery.parse(words + " after:1990/01/01"), limit: 30, among: among)
            #expect(quick.total == whole.total, "\(words): \(quick.total) against \(whole.total)")
            #expect(quick.threads.map(\.id) == whole.threads.map(\.id), "\(words)")
            #expect(quick.among == whole.among, "\(words)")
            #expect(!quick.threads.contains { $0.id == "tbin" })
        }
        // A change is seen by the next search.
        store.put([MailMessage(id: "new", thread: "tnew", from: MailPerson(name: "Zed", address: "zed@example.org"), subject: "zzzz",
                               date: now, labels: ["INBOX"], replyTo: [], text: "zzzz")])
        #expect(store.find(MailQuery.parse("zzzz")).threads.map(\.id) == ["tnew"])
    }

    @Test func theWordMapFollowsTheMailAlone() {
        // The search's map of threads, read through the read-only look as
        // the app's search reads it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).sqlite")
        let store = MailStore(file: file)
        store.set("me", "me@example.com")
        var maker = MailboxMaker(seed: 5)
        store.put(maker.messages(2_000))
        let look = store.off
        #expect(look.find(MailQuery.parse("zzzz")).total == 0)
        let made = look.mapsMade
        // Written beside the mail: the map stays.
        store.keep([MailSensed(thread: "t1", message: "m1", needs: true, gist: "Wants it", due: nil, kind: .person)])
        store.set("notify-since", "1")
        #expect(look.find(MailQuery.parse("zzzz")).total == 0)
        #expect(look.mapsMade == made)
        // New mail, and mail put in Trash: made again, and right.
        store.put([MailMessage(id: "new", thread: "tnew", from: MailPerson(name: "Zed", address: "zed@example.org"), subject: "zzzz",
                               date: now, labels: ["INBOX"], replyTo: [], text: "zzzz")])
        #expect(look.find(MailQuery.parse("zzzz")).threads.map(\.id) == ["tnew"])
        #expect(look.mapsMade == made + 1)
        store.relabel(thread: "tnew", add: ["TRASH"], remove: ["INBOX"])
        #expect(look.find(MailQuery.parse("zzzz")).total == 0)
    }

    @Test func whatWasWorkedOutGoesInAtOnce() {
        let store = MailStore(file: MailStore.memory)
        let all = (0..<300).map { n in
            MailSensed(thread: "t\(n)", message: "m\(n)", needs: n % 2 == 0, gist: "Wants \(n)", due: nil, kind: .person)
        }
        store.keep(all)
        let back = store.sensed(all.map(\.thread))
        #expect(back.count == 300 && back["t7"]?.gist == "Wants 7" && back["t8"]?.needs == true)
    }

    @Test @MainActor func animationsOffMeansNotEvenAFade() {
        let settings = Store.settings
        let kept = settings.object(forKey: "mail.motion")
        defer { settings.set(kept, forKey: "mail.motion") }
        settings.set(false, forKey: "mail.motion")
        #expect(MailDesk.instant && MailDesk.still)
        // Animations on: whatever Reduce Motion says, never instant.
        settings.set(true, forKey: "mail.motion")
        #expect(!MailDesk.instant)
    }
}
