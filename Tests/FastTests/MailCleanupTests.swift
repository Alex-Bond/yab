import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Clearing mail out (docs/mail.md, Cleanup): what List-Unsubscribe says and
// which way ⌘U takes; the one-click POST that carries nothing of yours; a
// sender kept out by their address or their domain, their new mail into
// Trash as it comes; Get Me To Zero's threads and its packs; the Bulk
// Actions log, kept on disk and taken back.
@Suite(.serialized)
struct MailCleanupTests {
    let now = Date()

    /// A store and a Gmail of their own, on a host no other suite asks.
    func world(file: URL = MailStore.memory) -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "cleanup-" + UUID().uuidString.prefix(8).lowercased()
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

    // MARK: - List-Unsubscribe

    @Test func listUnsubscribeAsWritten() {
        let urls = { (header: String) in MailUnsubscribe.addresses(header).map(\.absoluteString) }
        // The usual: a mail address and a page, each in angle brackets.
        #expect(urls("<mailto:leave@lists.example.com?subject=unsubscribe>, <https://lists.example.com/u?id=42>")
                == ["mailto:leave@lists.example.com?subject=unsubscribe", "https://lists.example.com/u?id=42"])
        // Folded across lines, spaces inside an address ignored (RFC 2369).
        #expect(urls("<https://news.example.com/unsub\r\n  scribe?u=1&id=2>,\r\n <mailto:out@news.example.com>")
                == ["https://news.example.com/unsubscribe?u=1&id=2", "mailto:out@news.example.com"])
        // Several of each, in their order.
        #expect(urls("<https://a.example/1>, <https://b.example/2>, <mailto:c@c.example>").count == 3)
        // Written without brackets, as some senders do.
        #expect(urls("mailto:leave@x.example, https://x.example/out") == ["mailto:leave@x.example", "https://x.example/out"])
        // What isn't a way out is left out.
        #expect(urls("<ftp://x.example/out>, <>, <javascript:alert(1)>, <https://ok.example/u>") == ["https://ok.example/u"])
        #expect(urls("").isEmpty)
    }

    @Test func oneClickAsListsWriteIt() {
        #expect(MailUnsubscribe.oneClick("List-Unsubscribe=One-Click"))
        #expect(MailUnsubscribe.oneClick("  list-unsubscribe=one-click "))
        #expect(!MailUnsubscribe.oneClick("List-Unsubscribe=Other"))
        #expect(!MailUnsubscribe.oneClick(""))
    }

    @Test func theWayOutBestFirst() {
        let both = "<mailto:leave@list.example.com?subject=stop>, <https://list.example.com/u/7>"
        // One-click: the POST at the first https address.
        #expect(MailUnsubscribe.way(header: both, post: "List-Unsubscribe=One-Click", testing: false)
                == .oneClick(URL(string: "https://list.example.com/u/7")!))
        // Without one-click: a mail to the list's address before its page.
        let mail = MailUnsubscribe.Mailto(to: ["leave@list.example.com"], subject: "stop", body: "Unsubscribe")
        #expect(MailUnsubscribe.way(header: both, post: "", testing: false) == .mail(mail))
        #expect(MailUnsubscribe.ways(header: both, post: "List-Unsubscribe=One-Click", testing: false)
                == [.oneClick(URL(string: "https://list.example.com/u/7")!), .mail(mail), .page(URL(string: "https://list.example.com/u/7")!)])
        // A page alone: opened, for you to finish there.
        #expect(MailUnsubscribe.way(header: "<https://list.example.com/u/7>", post: "", testing: false)
                == .page(URL(string: "https://list.example.com/u/7")!))
        // One-click needs https: http is a page.
        #expect(MailUnsubscribe.way(header: "<http://list.example.com/u/7>", post: "List-Unsubscribe=One-Click", testing: false)
                == .page(URL(string: "http://list.example.com/u/7")!))
        // Never a POST into this Mac or its network; a test world's own server, yes.
        let local = "<https://192.168.1.1/admin?reboot=1>"
        #expect(MailUnsubscribe.way(header: local, post: "List-Unsubscribe=One-Click", testing: false) == .page(URL(string: "https://192.168.1.1/admin?reboot=1")!))
        let test = "<http://127.0.0.1:8899/unsub/1>"
        #expect(MailUnsubscribe.way(header: test, post: "List-Unsubscribe=One-Click", testing: true) == .oneClick(URL(string: "http://127.0.0.1:8899/unsub/1")!))
        #expect(MailUnsubscribe.way(header: test, post: "List-Unsubscribe=One-Click", testing: false) == .page(URL(string: "http://127.0.0.1:8899/unsub/1")!))
        // Nothing to go by.
        #expect(MailUnsubscribe.way(header: "", post: "List-Unsubscribe=One-Click") == nil)
    }

    @Test func aMailtoAsTheMailItSends() {
        let one = MailUnsubscribe.mailto(URL(string: "mailto:Leave@List.example.com?subject=Unsubscribe%20me&body=Please%20stop")!)
        #expect(one == .init(to: ["leave@list.example.com"], subject: "Unsubscribe me", body: "Please stop"))
        // Nothing asked for: "Unsubscribe", as list servers read it.
        #expect(MailUnsubscribe.mailto(URL(string: "mailto:out@list.example.com")!) == .init(to: ["out@list.example.com"], subject: "Unsubscribe", body: "Unsubscribe"))
        // The address in a to= field, and two at once.
        #expect(MailUnsubscribe.mailto(URL(string: "mailto:?to=out@list.example.com")!)?.to == ["out@list.example.com"])
        #expect(MailUnsubscribe.mailto(URL(string: "mailto:a@x.example,b@x.example")!)?.to == ["a@x.example", "b@x.example"])
        // No address mail can go to: no mail.
        #expect(MailUnsubscribe.mailto(URL(string: "mailto:nobody")!) == nil)
        #expect(MailUnsubscribe.mailto(URL(string: "https://x.example")!) == nil)
    }

    @Test func onlyHostsOnTheInternet() {
        for host in ["list-manage.com", "click.example.co.uk", "8.8.8.8", "140.82.112.3"] {
            #expect(MailUnsubscribe.outside(host), "\(host)")
        }
        for host in ["localhost", "printer.local", "router.lan", "nas.home.arpa", "intranet", "10.0.0.1", "127.0.0.1", "192.168.1.1",
                     "172.16.4.2", "172.31.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "::1", "fe80::1"] {
            #expect(!MailUnsubscribe.outside(host), "\(host)")
        }
        #expect(MailUnsubscribe.outside("172.32.0.1"))
    }

    @Test func aThreadsWayFromItsNewestListMail() {
        let me = "me@example.com"
        let list = MailPerson(name: "Lumen Weekly", address: "news@lumen.example")
        let messages = [
            MailMessage(id: "a", thread: "t", from: list, date: now.addingTimeInterval(-60), listUnsubscribe: true,
                        unsubscribe: "<https://lumen.example/old>", unsubscribePost: ""),
            MailMessage(id: "b", thread: "t", from: list, date: now.addingTimeInterval(-30), listUnsubscribe: true,
                        unsubscribe: "<https://lumen.example/u/9>", unsubscribePost: "List-Unsubscribe=One-Click"),
            // Your own answer in it names no way.
            MailMessage(id: "c", thread: "t", from: MailPerson(name: "", address: me), date: now),
        ]
        let found = MailUnsubscribe.of(messages, me: me, testing: false)
        #expect(found?.way == .oneClick(URL(string: "https://lumen.example/u/9")!))
        #expect(found?.sender == list)
        #expect(MailUnsubscribe.of([messages[2]], me: me) == nil)
    }

    // MARK: - one-click

    /// What the one-click POST carried, and what the list answers.
    final class Listener: URLProtocol {
        nonisolated(unsafe) static var heard: [URLRequest] = []
        nonisolated(unsafe) static var bodies: [String] = []
        nonisolated(unsafe) static var status = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Listener.heard.append(request)
            Listener.bodies.append(String(decoding: request.bodyData ?? Data(), as: UTF8.self))
            var headers = ["Content-Type": "text/plain"]
            if (300..<400).contains(Listener.status) { headers["Location"] = "https://lumen.example/sorry" }
            let response = HTTPURLResponse(url: request.url!, statusCode: Listener.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test func oneClickCarriesNothingOfYours() async throws {
        // The session ⌘U posts with keeps nothing and sends nothing kept.
        let kept = MailUnsubscribe.session.configuration
        #expect(kept.httpShouldSetCookies == false)
        #expect(kept.httpCookieAcceptPolicy == .never)
        #expect(kept.httpCookieStorage == nil && kept.urlCredentialStorage == nil && kept.urlCache == nil)
        #expect(kept.timeoutIntervalForRequest <= 10)
        let config = kept
        config.protocolClasses = [Listener.self]
        let session = URLSession(configuration: config)
        Listener.heard = []
        Listener.bodies = []
        Listener.status = 200
        let url = URL(string: "https://lumen.example/u/9?token=abc")!
        #expect(await MailUnsubscribe.post(url, session: session))
        let request = try #require(Listener.heard.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == url)
        #expect(Listener.bodies.first == "List-Unsubscribe=One-Click")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        // A refusal, or a redirect (RFC 8058 has the list answer itself), isn't a yes.
        Listener.status = 500
        #expect(!(await MailUnsubscribe.post(url, session: session)))
        Listener.status = 302
        Listener.heard = []
        #expect(!(await MailUnsubscribe.post(url, session: session)))
        #expect(Listener.heard.count == 1)
    }

    // MARK: - blocking

    @Test func blockByAddressDomainAndUnder() {
        #expect(MailBlock.blocks(["substack.com"], "news@substack.com"))
        #expect(MailBlock.blocks(["substack.com"], "Writer@Mail.Substack.com"))
        #expect(!MailBlock.blocks(["substack.com"], "news@notsubstack.com"))
        #expect(!MailBlock.blocks(["substack.com"], "substack.com@evil.example"))
        #expect(MailBlock.blocks(["anna@fold.studio"], "anna@fold.studio"))
        #expect(!MailBlock.blocks(["anna@fold.studio"], "ben@fold.studio"))
        #expect(!MailBlock.blocks([], "anna@fold.studio"))
        // As typed or found, kept the one way.
        #expect(MailBlock.entry("Anna Lindqvist <Anna@Fold.Studio>") == "anna@fold.studio")
        #expect(MailBlock.entry("@substack.com") == "substack.com")
        #expect(MailBlock.entry(" .Substack.com. ") == "substack.com")
        #expect(MailBlock.entry("not a domain") == nil)
        #expect(MailBlock.entry("https://substack.com/x") == nil)
        // Everyone's domains, and your own, are offered by address only.
        #expect(MailBlock.domain(of: "someone@gmail.com", me: "me@example.com") == nil)
        #expect(MailBlock.domain(of: "colleague@example.com", me: "me@example.com") == nil)
        #expect(MailBlock.domain(of: "news@substack.com", me: "me@example.com") == "substack.com")
    }

    @Test func blockedMailGoesToTrashAsItComes() async throws {
        let (store, gmail, fake) = world()
        let sync = MailSync(store: store, gmail: gmail)
        fake.add(.init(id: "n1", thread: "tn", from: "Lumen <news@lumen.example>", subject: "Issue 1", body: "One.",
                       at: now.addingTimeInterval(-7200), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "g1", thread: "tg", from: "Anna Lindqvist <anna@fold.studio>", subject: "Plans", body: "Friday?",
                       at: now.addingTimeInterval(-7000), labels: ["INBOX"]), record: false)
        try await sync.sync()
        // The domain kept out, from an hour ago; what came before stays.
        store.block("lumen.example", at: now.addingTimeInterval(-3600))
        #expect(store.blocked().map(\.who) == ["lumen.example"])
        fake.add(.init(id: "n2", thread: "tn2", from: "Lumen Deals <deals@mail.lumen.example>", subject: "Issue 2", body: "Two.",
                       at: now, labels: ["INBOX", "UNREAD"]))
        // In a thread others write in, only their mail goes.
        fake.add(.init(id: "g2", thread: "tg", from: "Lumen <news@lumen.example>", subject: "Re: Plans", body: "Buy now.",
                       at: now, labels: ["INBOX", "UNREAD"]))
        try await sync.sync()
        #expect(store.message("n2")?.labels.contains("TRASH") == true)
        #expect(store.message("n2")?.labels.contains("INBOX") == false)
        #expect(store.message("g2")?.labels.contains("TRASH") == true)
        #expect(store.message("g1")?.labels.contains("INBOX") == true)
        #expect(store.message("n1")?.labels.contains("INBOX") == true)
        #expect(!store.threads(label: "INBOX").map(\.id).contains("tn2"))
        // Gmail hears it by those messages' ids: two, each its own modify (5 units, under a batch's 50).
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.isEmpty)
        #expect(Set(fake.calls.filter { $0.hasPrefix("POST messages/") }) == ["POST messages/n2/modify", "POST messages/g2/modify"])
        #expect(fake.messages["n2"]?.labels == ["TRASH", "UNREAD"])
        #expect(fake.messages["g1"]?.labels == ["INBOX"])
        // Once Gmail has it, nothing more to do.
        try await sync.sync()
        #expect(store.blockedArrivals().isEmpty)
        #expect(store.pendingOps == 0)
    }

    @Test func blockSenderTakenBack() async throws {
        let (store, gmail, fake) = world()
        fake.add(.init(id: "n1", thread: "tn", from: "Lumen <news@lumen.example>", subject: "Issue 1", body: "One.",
                       at: now.addingTimeInterval(-60), labels: ["INBOX"]), record: false)
        try await MailSync(store: store, gmail: gmail).sync()
        let acted = MailOps.block(["news@lumen.example"], threads: ["tn"], after: 4, in: store)
        #expect(acted.blocked == ["news@lumen.example"])
        #expect(acted.kinds == [.trash])
        #expect(store.thread("tn")?.labels.contains("TRASH") == true)
        // Blocked again: nothing new to keep, nothing to take back for it.
        #expect(MailOps.block(["news@lumen.example"], threads: [], in: store).isEmpty)
        // ⌘Z: let in again, out of Trash, in the inbox, Gmail never told.
        MailOps.takeBack(acted, in: store)
        #expect(store.blocked().isEmpty)
        #expect(store.thread("tn")?.labels == ["INBOX"])
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        #expect(labels(fake, "tn") == ["INBOX"])
        #expect(fake.calls.filter { $0.hasPrefix("POST") }.isEmpty)
    }

    // MARK: - Get Me To Zero

    /// Threads of one mail each, `ago` apart, in the inbox.
    func inbox(_ store: MailStore, _ threads: [(id: String, ago: TimeInterval, labels: Set<String>)], fake: FakeGmail? = nil) {
        store.set("me", "me@example.com")
        store.put(threads.map { one in
            MailMessage(id: "m-" + one.id, thread: one.id, from: MailPerson(name: "Shop", address: "news@shop.example"),
                        subject: one.id, date: now.addingTimeInterval(-one.ago), labels: one.labels)
        })
        for one in threads {
            fake?.add(.init(id: "m-" + one.id, thread: one.id, from: "Shop <news@shop.example>", subject: one.id, body: "Shipped.",
                            at: now.addingTimeInterval(-one.ago), labels: one.labels), record: false)
        }
    }

    @Test func getMeToZeroTakesWhatIsOldEnough() {
        let (store, _, _) = world()
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        inbox(store, [("fresh", hour, ["INBOX"]), ("two", 2 * day, ["INBOX", "UNREAD"]), ("ten", 10 * day, ["INBOX", "STARRED"]),
                      ("forty", 40 * day, ["INBOX"]), ("done", 3 * day, [])])
        // A thread whose last word is newer than the line stays, however old its first.
        store.put([MailMessage(id: "m-forty-2", thread: "forty", from: MailPerson(name: "", address: "me@example.com"),
                               subject: "Re: forty", date: now.addingTimeInterval(-20 * day), labels: ["SENT"])])
        let take = { (age: MailZero.Age, leave: MailZero.Leave) in MailZero.threads(age, leave: leave, in: store, now: now) }
        #expect(take(.day, .init()) == ["two", "ten", "forty"])
        #expect(take(.week, .init()) == ["ten", "forty"])
        #expect(take(.month, .init()).isEmpty)
        #expect(take(.all, .init()) == ["fresh", "two", "ten", "forty"])
        #expect(take(.day, .init(unread: true)) == ["ten", "forty"])
        #expect(take(.day, .init(unread: true, starred: true)) == ["forty"])
    }

    @Test func getMeToZeroGoesInPacks() async throws {
        let (store, gmail, fake) = world()
        inbox(store, (0..<1200).map { ("old\($0)", 86_400 * 3 + Double($0), ["INBOX"]) }, fake: fake)
        inbox(store, [("new", 60, ["INBOX"])], fake: fake)
        let threads = MailZero.threads(.day, leave: .init(), in: store, now: now)
        #expect(threads.count == 1200)
        let log = MailOps.log(.zero, said: "Get Me To Zero, older than a day", threads: threads, in: store)
        let acted = MailOps.archive(threads, inbox: true, after: 4, in: store)
        // Two packs of up to a thousand messages, all of it out here at once.
        #expect(acted.entries.flatMap(\.parts).map(\.threads.count) == [1000, 200])
        #expect(store.threads(label: "INBOX", limit: 2000).map(\.id) == ["new"])
        #expect(store.bulkMessages(log).count == 1200)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(5) })
        // Two calls, every one of them out of Gmail's inbox, the new one left.
        #expect(fake.calls.filter { $0 == "POST messages/batchModify" }.count == 2)
        #expect(fake.batches.map(\.count) == [1000, 200])
        #expect(fake.messages.values.filter { $0.labels.contains("INBOX") }.map(\.id) == ["m-new"])
        // One ⌘Z: the inverse, in two calls again, the inbox as it was.
        MailOps.takeBack(acted, in: store)
        #expect(store.threads(label: "INBOX", limit: 2000).count == 1201)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.batches.count == 4)
        #expect(fake.messages.values.allSatisfy { $0.labels.contains("INBOX") })
    }

    // MARK: - the Bulk Actions log

    @Test func theLogOutlivesARestartAndTakesBack() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-cleanup-\(UUID().uuidString).sqlite")
        let id: Int64
        let threads = (0..<30).map { "old\($0)" }
        let fake: FakeGmail, gmail: MailGmail
        do {
            let (store, g, f) = world(file: file)
            fake = f
            gmail = g
            inbox(store, threads.map { ($0, 86_400 * 9, ["INBOX"]) }, fake: fake)
            // One of them yours too, never in the inbox: it stays out of it.
            store.put([MailMessage(id: "mine", thread: "old0", from: MailPerson(name: "", address: "me@example.com"),
                                   subject: "Re: old0", date: now.addingTimeInterval(-86_400 * 9 + 60), labels: ["SENT"])])
            fake.add(.init(id: "mine", thread: "old0", from: "me@example.com", subject: "Re: old0", body: "Thanks.",
                           at: now.addingTimeInterval(-86_400 * 9 + 60), labels: ["SENT"]), record: false)
            id = MailOps.log(.zero, said: "Get Me To Zero, older than a week", threads: threads, in: store)
            _ = MailOps.archive(threads, inbox: true, in: store)
            try await MailOps.flush(store, gmail: gmail)
            #expect(fake.messages.values.filter { $0.labels.contains("INBOX") }.isEmpty)
        }
        // Yab again: the entry is there, with the mail it moved.
        let store = MailStore(file: file)
        let kept = store.bulks(since: now.addingTimeInterval(-MailOps.bulkKept))
        #expect(kept.map(\.said) == ["Get Me To Zero, older than a week"])
        #expect(kept.first?.threads == 30 && kept.first?.back == nil && kept.first?.kind == .zero)
        #expect(store.bulkMessages(id).count == 30)
        // One moved since into Trash stays there.
        _ = MailOps.trash(["old29"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        fake.batches = []
        let back = try #require(MailOps.restore(id, in: store))
        #expect(back.count == 29 && !back.contains("old29"))
        #expect(store.threads(label: "INBOX", limit: 100).count == 29)
        try await MailOps.flush(store, gmail: gmail)
        // Exactly the mail it took out, by its ids, in one call.
        #expect(fake.batches.count == 1 && fake.batches.first?.count == 29)
        #expect(fake.messages["mine"]?.labels == ["SENT"])
        #expect(fake.messages["m-old29"]?.labels.contains("TRASH") == true)
        #expect(fake.messages.values.filter { $0.labels.contains("INBOX") }.count == 29)
        // Taken back once: not again, and the log says so.
        #expect(MailOps.restore(id, in: store) == nil)
        #expect(store.bulk(id)?.back != nil)
    }

    @Test func theLogKeepsSevenDays() {
        let (store, _, _) = world()
        inbox(store, [("a", 86_400 * 3, ["INBOX"]), ("b", 86_400 * 3, ["INBOX"])])
        let old = MailOps.log(.zero, said: "Get Me To Zero, everything", threads: ["a"], in: store, now: now.addingTimeInterval(-8 * 86_400))
        #expect(MailOps.restore(old, in: store) == nil)
        // The next entry lets the one past its week go, with its mail.
        _ = MailOps.log(.done, said: "Everything from Shop, done", threads: ["b"], in: store)
        #expect(store.bulk(old) == nil)
        #expect(store.bulkMessages(old).isEmpty)
        #expect(store.bulks(since: now.addingTimeInterval(-MailOps.bulkKept)).map(\.kind) == [.done])
    }

    @Test func aSendersMailFromTrashBack() async throws {
        let (store, gmail, fake) = world()
        inbox(store, [("s1", 3600, ["INBOX"]), ("s2", 7200, ["INBOX", "UNREAD"])], fake: fake)
        #expect(store.inboxThreads(from: "news@shop.example") == ["s1", "s2"])
        let id = MailOps.log(.trash, said: "Everything from Shop, moved to Trash", threads: ["s1", "s2"], in: store)
        _ = MailOps.trash(["s1", "s2"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "s1") == ["TRASH"])
        #expect(store.inboxThreads(from: "news@shop.example").isEmpty)
        let back = MailOps.restore(id, in: store)
        #expect(Set(back ?? []) == ["s1", "s2"])
        #expect(store.thread("s2")?.labels == ["INBOX", "UNREAD"])
        try await MailOps.flush(store, gmail: gmail)
        #expect(labels(fake, "s1") == ["INBOX"] && labels(fake, "s2") == ["INBOX", "UNREAD"])
    }

    // MARK: - keys

    @MainActor @Test func cleanupsKeysAreMails() {
        let mail = Shortcut.all.first { $0.title == "Mail" }?.items ?? []
        let listed = Set(mail.compactMap(\.action))
        for action in [Shortcut.Action.mailUnsubscribe, .mailBlock, .mailZero, .mailBulk] {
            #expect(listed.contains(action), "\(action.rawValue) isn't in Settings › Shortcuts")
            #expect(Shortcut.context(action) == .mail)
            #expect(Shortcut.byAction[action]?.does.isEmpty == false && Shortcut.byAction[action]?.taken.isEmpty == false)
            // Each is a command of ⌘K's and ?'s too.
            #expect(Browser.command(forKey: action.rawValue) != nil, "\(action.rawValue) has no command")
        }
        // ⌘U, and only it: Block Sender, Get Me To Zero and Bulk Actions wait for a key of yours.
        let unsubscribe = Shortcut.byAction[.mailUnsubscribe]?.key
        #expect(unsubscribe?.text == "⌘U")
        #expect(unsubscribe.map { Keymap.valid($0, for: .mailUnsubscribe) } == true)
        #expect(mail.filter { $0.key == unsubscribe }.count == 1)
        #expect(Shortcut.byAction[.mailBlock]?.key == nil && Shortcut.byAction[.mailZero]?.key == nil && Shortcut.byAction[.mailBulk]?.key == nil)
    }

    /// Get Me To Zero's ages with no thread in them, and a sender with no
    /// more mail: shown, dimmed, and never chosen, by the arrows, the
    /// pointer or ↩; the rows there is something to take from are.
    @MainActor @Test func rowsWithNothingToTakeAreQuiet() {
        let browser = Browser(windowID: UUID())
        browser.query.stock.mail = MailFieldContext(mode: .zero)
        // No account here: every age holds nothing.
        let rows = browser.mailSuggestions()
        let ids = rows.compactMap { offer -> String? in
            guard case .page(let what) = offer.kind else { return nil }
            return String(what.dropFirst(5))
        }
        let ages = MailZero.Age.allCases.map { "zero." + $0.rawValue }
        #expect(Array(ids.prefix(ages.count)) == ages)
        for age in ages {
            #expect(Browser.mailRows[age]?.quiet == true && Browser.mailRows[age]?.end == "None")
        }
        #expect(Browser.mailRows["zero.leave.unread"]?.quiet == false)
        browser.query.offers = rows
        let leave = ids.firstIndex(of: "zero.leave.unread")
        #expect(rows.firstIndex { !Browser.inert($0) } == leave)
        // The arrows pass the quiet rows by, and off the top of what is
        // left come round to its foot.
        browser.query.lead = leave
        browser.walk(1)
        #expect(browser.query.picked.map { ids[$0] } == "zero.leave.starred")
        browser.walk(-1)
        #expect(browser.query.picked.map { ids[$0] } == "zero.leave.unread")
        browser.walk(-1)
        #expect(browser.query.picked == rows.lastIndex { !Browser.inert($0) })
        // The pointer on one: nothing pointed at; ↩ on one: nothing done.
        browser.point(at: 0)
        #expect(browser.query.pointed == nil)
        browser.takeMail(ages[0])
        #expect(browser.query.stock.mail?.mode == .zero)
    }

    // MARK: - the store

    @Test func aListsHeadersKeptAndLearnedLate() async throws {
        // An old store: mail that isn't a list is known to have no way out;
        // a list's is asked of Gmail again.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-cleanup-old-\(UUID().uuidString).sqlite")
        MailStoreV5.write(file, count: 4)
        SQL.on(file, "UPDATE messages SET bulk = 1 WHERE id = 'm2'")
        let store = MailStore(file: file)
        #expect(store.message("m0")?.unsubscribe == "")
        #expect(store.message("m2")?.unsubscribe == nil)
        // Learned: kept as Gmail gave it, and a put that doesn't know it keeps it.
        var m = try #require(store.message("m2"))
        m.unsubscribe = "<https://fold.studio/u>"
        m.unsubscribePost = "List-Unsubscribe=One-Click"
        store.put([m])
        m.unsubscribe = nil
        m.unsubscribePost = nil
        store.put([m])
        #expect(store.message("m2")?.unsubscribe == "<https://fold.studio/u>")
        #expect(store.message("m2")?.unsubscribePost == "List-Unsubscribe=One-Click")
        // From Gmail: both headers asked for, and kept.
        let (fresh, gmail, fake) = world()
        fake.add(.init(id: "l1", thread: "tl", from: "Lumen <news@lumen.example>", subject: "Issue", body: "Hi.", at: now,
                       labels: ["INBOX"], unsubscribe: "<mailto:out@lumen.example>, <https://lumen.example/u>",
                       unsubscribePost: "List-Unsubscribe=One-Click"), record: false)
        try await MailSync(store: fresh, gmail: gmail).sync()
        let got = try #require(fresh.message("l1"))
        #expect(got.listUnsubscribe && got.unsubscribe == "<mailto:out@lumen.example>, <https://lumen.example/u>")
        #expect(got.unsubscribePost == "List-Unsubscribe=One-Click")
        #expect(fresh.thread("tl")?.bulk == true)
    }

    @Test func anOpOnMessagesHereAndInGmail() async throws {
        let (store, gmail, fake) = world()
        inbox(store, [("a", 60, ["INBOX"]), ("b", 120, ["INBOX"])], fake: fake)
        let seqs = MailOps.bulk(.archive, messages: ["m-a", "m-b"], after: 4, in: store)
        #expect(seqs.count == 1)
        // The journal says which are still waiting (the head's line, MailGoing).
        #expect(store.pending(seqs + [9999]) == Set(seqs))
        #expect(store.allOps().first?.onMessages == true)
        #expect(Set(store.allOps().first?.messages ?? []) == ["m-a", "m-b"])
        #expect(Set(store.allOps().first?.threads ?? []) == ["a", "b"])
        #expect(store.threads(label: "INBOX").isEmpty)
        // Taken back before Gmail heard: dropped, as it was.
        #expect(MailOps.undo(seqs[0], in: store))
        #expect(store.threads(label: "INBOX").count == 2)
        // One gone from Gmail since: the rest go a message at a time.
        MailOps.bulk(.archive, messages: ["m-a", "m-b", "gone"], in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.calls.contains("POST messages/m-a/modify") && fake.calls.contains("POST messages/m-b/modify"))
        #expect(labels(fake, "a").isEmpty && labels(fake, "b").isEmpty)
        #expect(store.pendingOps == 0)
    }
}
