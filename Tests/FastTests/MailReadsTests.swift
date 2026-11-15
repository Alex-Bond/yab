import CryptoKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Read statuses (docs/mail.md, Read statuses; fast-web docs/read-statuses.md):
// a mail's key of 128 random bits, and its token as the contract's vector
// has it; the picture last in the HTML part, and only while the setting is
// on; none in mail to eleven people or to yourself under any address; Undo
// send and Send Later; the site asked with no cookie, 200 keys an ask, and
// its answer read; the lines under your mail, in Sent and in Waiting,
// Apple Mail's privacy a maybe; mail_read saying them; keys kept across a
// reset; our picture never loading here.
struct MailReadsTests {
    static let me = MailPerson(name: "", address: "me@example.com")
    static let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")

    // MARK: - keys and tokens

    @Test func aKeyIs128RandomBitsAndItsTokenTheContracts() {
        // The contract's vector: key 00 01 … 0f, its token.
        #expect(MailReads.token(for: "AAECAwQFBgcICQoLDA0ODw") == "vkXLJgW_Nr695oSEGijw_Q")
        #expect(MailReads.decoded("AAECAwQFBgcICQoLDA0ODw") == Data(0..<16))
        #expect(MailReads.encoded(Data(0..<16)) == "AAECAwQFBgcICQoLDA0ODw")
        #expect(MailReads.encoded(MailReads.token(of: Data(0..<16))) == "vkXLJgW_Nr695oSEGijw_Q")
        // 16 bytes each, never the same twice, about half their bits set.
        let keys = (0..<2000).map { _ in MailReads.newKey() }
        #expect(keys.allSatisfy { $0.count == 16 })
        #expect(Set(keys).count == keys.count)
        let ones = keys.reduce(0) { sum, key in sum + key.reduce(0) { $0 + $1.nonzeroBitCount } }
        let share = Double(ones) / Double(keys.count * 128)
        #expect(share > 0.48 && share < 0.52)
        // Written as the site takes them: 22 characters, the last A, Q, g or w.
        for key in keys.prefix(200).map(MailReads.encoded) {
            #expect(key.count == 22 && MailReads.written(key) && "AQgw".contains(key.last!))
            #expect(MailReads.written(MailReads.token(for: key) ?? ""))
            #expect(MailReads.decoded(key).map(MailReads.encoded) == key)
        }
        // Anything else isn't a key.
        for bad in ["", "AAECAwQFBgcICQoLDA0OD", "AAECAwQFBgcICQoLDA0ODx", "AAECAwQFBgcICQoLDA0ODw==", "AAECAwQFBgcICQoLDA0OD+"] {
            #expect(!MailReads.written(bad) && MailReads.token(for: bad) == nil)
        }
    }

    @Test func thePictureIsOneByOneLastAndNamedByTheToken() {
        let site = URL(string: "https://yetanotherbrowser.com")!
        #expect(MailReads.address(of: "vkXLJgW_Nr695oSEGijw_Q", base: site).absoluteString == "https://yetanotherbrowser.com/o/vkXLJgW_Nr695oSEGijw_Q.gif")
        #expect(MailReads.image("vkXLJgW_Nr695oSEGijw_Q", base: site)
            == "<img src=\"https://yetanotherbrowser.com/o/vkXLJgW_Nr695oSEGijw_Q.gif\" width=\"1\" height=\"1\" alt=\"\" style=\"border:0;width:1px;height:1px\">")
        // A stand-in on this Mac, in a test world.
        let local = URL(string: "http://127.0.0.1:8873")!
        #expect(MailReads.address(of: "vkXLJgW_Nr695oSEGijw_Q", base: local).absoluteString == "http://127.0.0.1:8873/o/vkXLJgW_Nr695oSEGijw_Q.gif")
    }

    // MARK: - going out

    @Test func thePictureGoesLastInTheHTMLPartOnlyWhileTheSettingIsOn() async throws {
        let (store, gmail, fake) = world()
        // Off, as it starts: plain words go as text alone, no key.
        #expect(!MailReads.on(store))
        try await send(MailDraft(id: "new:1", to: [Self.anna], subject: "Off", body: "Plain words."), store: store, gmail: gmail)
        let off = try last(fake)
        #expect(off.type == "text/plain" && off.text == "Plain words.")
        #expect(store.readKeys(since: .distantPast).isEmpty)

        // On: an HTML twin of the plain words, the picture last in it, the plain part as it was.
        MailReads.set(true, in: store)
        #expect(MailReads.on(store))
        let draft = MailDraft(id: "new:2", to: [Self.anna], subject: "On", body: "Plain words\nand a line.",
                              messageID: "<yab-on@example.com>")
        try await send(draft, store: store, gmail: gmail)
        let raw = try #require(fake.sent.last)
        let tree = try #require(MIMETree(raw))
        #expect(tree.type == "multipart/alternative")
        #expect(tree.parts.map(\.type) == ["text/plain", "text/html"])
        #expect(tree.parts[0].text == "Plain words\r\nand a line.")
        let kept = try #require(store.readKeys(since: .distantPast).first)
        #expect(kept.message == "<yab-on@example.com>")
        let token = try #require(MailReads.token(for: kept.key))
        let image = "<img src=\"https://yetanotherbrowser.com/o/\(token).gif\" width=\"1\" height=\"1\" alt=\"\" style=\"border:0;width:1px;height:1px\">"
        #expect(tree.parts[1].text == "<div dir=\"auto\">Plain words<br>and a line.</div>" + image)
        // The key goes nowhere: only its token is in the mail.
        #expect(!raw.contains(kept.key) && !tree.parts[1].text.contains(kept.key))
        // Kept against the thread Gmail named and the time it went.
        let thread = try #require(fake.messages.values.first { $0.subject == "On" }?.thread)
        #expect(kept.thread == thread)

        // Words with marks: their own HTML, the picture after it.
        var marked = MailDraft(id: "new:3", to: [Self.anna], subject: "Marked", body: "Deck attached.", messageID: "<yab-marked@example.com>")
        marked.html = "Deck <b>attached</b>."
        try await send(marked, store: store, gmail: gmail)
        let marks = try last(fake)
        #expect(marks.parts.last?.text.hasSuffix(".gif\" width=\"1\" height=\"1\" alt=\"\" style=\"border:0;width:1px;height:1px\">") == true)
        #expect(marks.parts.last?.text.hasPrefix("<div dir=\"auto\">Deck <b>attached</b>.</div><img src=") == true)
        #expect(marks.parts.first?.text.contains("img") == false)
        // One key a mail.
        #expect(Set(store.readKeys(since: .distantPast).map(\.key)).count == 2)

        // Turned off again: the next goes without.
        MailReads.set(false, in: store)
        try await send(MailDraft(id: "new:4", to: [Self.anna], subject: "Off again", body: "No picture.", messageID: "<yab-off@example.com>"),
                       store: store, gmail: gmail)
        #expect(try last(fake).type == "text/plain")
        #expect(store.readKeys(since: .distantPast).count == 2)
    }

    @Test func aSendTriedAgainGoesWithTheSameKey() async throws {
        let (store, gmail, fake) = world()
        MailReads.set(true, in: store)
        // Gmail took it and the answer was lost: found in Sent, not sent again, its key the one it carries.
        let lost = MailDraft(id: "new:1", to: [Self.anna], subject: "Lost answer", body: "Hi.", messageID: "<yab-lost@example.com>")
        store.save(lost)
        fake.dropAnswers = 1
        MailOps.act(.send, thread: lost.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(30) })
        #expect(fake.sent.count == 1)
        let kept = try #require(store.readKeys(since: .distantPast).first)
        #expect(try html(fake.sent[0]).contains("/o/" + (MailReads.token(for: kept.key) ?? "?") + ".gif"))
        #expect(kept.thread == fake.messages.values.first { $0.subject == "Lost answer" }?.thread)

        // Gmail refused it: sent again later, with the key it was going to carry.
        let refused = MailDraft(id: "new:2", to: [Self.anna], subject: "Refused", body: "Hi.", messageID: "<yab-refused@example.com>")
        store.save(refused)
        fake.failures = [500]
        MailOps.act(.send, thread: refused.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        let first = try #require(store.readKeys(since: .distantPast).first { $0.message == refused.messageID })
        #expect(first.thread.isEmpty)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(30) })
        #expect(fake.sent.count == 2)
        #expect(try html(fake.sent[1]).contains("/o/" + (MailReads.token(for: first.key) ?? "?") + ".gif"))
        #expect(store.readKeys(since: .distantPast).first { $0.message == refused.messageID }?.key == first.key)
    }

    @Test func noPictureForElevenPeopleOrForYourself() async throws {
        let (store, gmail, fake) = world()
        store.keep(sendAs: MailSendAs.list(MailRichTests.sendAsJSON))
        MailReads.set(true, in: store)
        let people = (1...11).map { MailPerson(name: "", address: "p\($0)@example.org") }
        let mine = MailReads.mine(store)
        #expect(mine == ["me@example.com", "sam@fold.studio"])
        // Ten is the most, To, Cc and Bcc together; an address counted once.
        #expect(MailReads.wanted(MailDraft(to: Array(people.prefix(10))), mine: mine))
        #expect(MailReads.wanted(MailDraft(to: Array(people.prefix(4)), cc: Array(people.prefix(4)) + Array(people[4..<7]),
                                           bcc: Array(people[7..<10])), mine: mine))
        #expect(!MailReads.wanted(MailDraft(to: Array(people.prefix(10)), bcc: [people[10]]), mine: mine))
        #expect(!MailReads.wanted(MailDraft(to: people), mine: mine))
        // Yourself, your alias, in any field, in any case.
        #expect(!MailReads.wanted(MailDraft(to: [Self.me]), mine: mine))
        #expect(!MailReads.wanted(MailDraft(to: [Self.anna], cc: [MailPerson(name: "", address: "Me@Example.com")]), mine: mine))
        #expect(!MailReads.wanted(MailDraft(to: [Self.anna], bcc: [MailPerson(name: "Sam", address: "sam@fold.studio")]), mine: mine))
        // Mail Yab writes for you: an unsubscribe, an answer to an invitation; and mail to nobody.
        #expect(!MailReads.wanted(MailDraft(id: "unsubscribe:1", to: [Self.anna]), mine: mine))
        #expect(!MailReads.wanted(MailDraft(id: "rsvp:1", to: [Self.anna]), mine: mine))
        #expect(!MailReads.wanted(MailDraft(), mine: mine))

        // Through the send: eleven people, and you, go plain, no key kept.
        try await send(MailDraft(id: "new:1", to: people, subject: "Eleven", body: "Hello all.", messageID: "<yab-11@example.com>"),
                       store: store, gmail: gmail)
        #expect(try last(fake).type == "text/plain")
        try await send(MailDraft(id: "new:2", to: [MailPerson(name: "", address: "sam@fold.studio")], subject: "Note to self",
                                 body: "Milk.", messageID: "<yab-self@example.com>"), store: store, gmail: gmail)
        #expect(try last(fake).type == "text/plain")
        #expect(store.readKeys(since: .distantPast).isEmpty)
        // Ten go with it.
        try await send(MailDraft(id: "new:3", to: Array(people.prefix(10)), subject: "Ten", body: "Hello ten.", messageID: "<yab-10@example.com>"),
                       store: store, gmail: gmail)
        #expect(try last(fake).type == "multipart/alternative")
        #expect(store.readKeys(since: .distantPast).map(\.message) == ["<yab-10@example.com>"])
    }

    @Test func undoSendLeavesNoKeyAndSendLaterGoesWithOne() async throws {
        let (store, gmail, fake) = world()
        MailReads.set(true, in: store)
        // ⌘↩ then ⌘Z inside the undo window: nothing went, no key was made.
        let undone = MailDraft(id: "new:1", to: [Self.anna], subject: "Taken back", body: "Oops.", messageID: "<yab-undone@example.com>")
        store.save(undone)
        let seq = MailOps.act(.send, thread: undone.id, after: 5, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(MailOps.undo(seq, in: store))
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(60) })
        #expect(fake.sent.isEmpty)
        #expect(store.readKeys(since: .distantPast).isEmpty)
        // Send Later: held until its time with no key, then out with one.
        let later = MailDraft(id: "new:2", to: [Self.anna], subject: "Tomorrow", body: "Morning.", messageID: "<yab-later@example.com>")
        store.save(later)
        MailOps.act(.send, thread: later.id, after: 3600, in: store)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(60) })
        #expect(fake.sent.isEmpty && store.readKeys(since: .distantPast).isEmpty)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(3700) })
        let kept = try #require(store.readKeys(since: .distantPast).first)
        #expect(fake.sent.count == 1)
        let went = try #require(fake.sent.first)
        #expect(try html(went).contains("/o/" + (MailReads.token(for: kept.key) ?? "?") + ".gif"))
        #expect(kept.message == later.messageID)
    }

    // MARK: - the site

    @Test func theSitesAnswerIsRead() throws {
        let answer = """
        {"opens": {
          "AAECAwQFBgcICQoLDA0ODw": [
            {"at": "2026-09-30T10:00:00.000Z", "kind": "apple-privacy"},
            {"at": "2026-09-30T12:30:00.250Z", "kind": "google-proxy"},
            {"at": "2026-09-30T11:00:00Z", "kind": "other"},
            {"at": "2026-09-30T11:30:00.000Z", "kind": "a-kind-from-later"},
            {"at": "yesterday", "kind": "other"}
          ],
          "not a key": [{"at": "2026-09-30T10:00:00.000Z", "kind": "other"}]
        }}
        """
        let found = try #require(MailReads.opens(from: Data(answer.utf8)))
        #expect(Array(found.keys) == ["AAECAwQFBgcICQoLDA0ODw"])
        let opens = try #require(found["AAECAwQFBgcICQoLDA0ODw"])
        // Newest first, milliseconds kept, a kind not known yet a reader's own, a time that isn't one left out.
        #expect(opens.map(\.kind) == [.google, .other, .other, .apple])
        #expect(opens[0].at == Date(timeIntervalSince1970: 1_790_771_400.25))
        #expect(opens[2].at == Date(timeIntervalSince1970: 1_790_766_000))
        // No opens at all is an answer too; anything else isn't.
        #expect(MailReads.opens(from: Data("{\"opens\":{}}".utf8)) == [:])
        #expect(MailReads.opens(from: Data("{\"error\":\"keys\"}".utf8)) == nil)
        #expect(MailReads.opens(from: Data("<html>".utf8)) == nil)
    }

    @Test func theSiteIsAskedWithNoCookieTwoHundredKeysAnAsk() async throws {
        let (store, site, client) = siteWorld()
        let now = Date()
        // 250 mails of the last month, one older, one of another thread.
        var keys: [String] = []
        for n in 0..<250 {
            let key = keep("<m\(n)@example.com>", thread: "t\(n % 5)", at: now.addingTimeInterval(-Double(n) * 3600), in: store)
            keys.append(key)
        }
        let old = keep("<old@example.com>", thread: "t0", at: now.addingTimeInterval(-31 * 86_400), in: store)
        site.load(try #require(MailReads.token(for: keys[0])), kind: "google-proxy", at: now.addingTimeInterval(-7200))
        site.load(try #require(MailReads.token(for: keys[0])), kind: "google-proxy", at: now.addingTimeInterval(-600))
        site.load(try #require(MailReads.token(for: keys[3])), kind: "apple-privacy", at: now.addingTimeInterval(-3600))
        site.load(try #require(MailReads.token(for: old)), kind: "other", at: now.addingTimeInterval(-60))

        #expect(await MailReads.ask(store, client: client, now: now))
        // Two asks, 200 and 50, the keys in the body as JSON, never in the address; no cookie, no key twice.
        #expect(site.asked.map(\.count) == [200, 50])
        #expect(Set(site.asked.flatMap { $0 }) == Set(keys))
        #expect(!site.asked.joined().contains(old))
        let request = try #require(site.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://opens.test/api/opens")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil && !request.httpShouldHandleCookies)
        let address = request.url?.absoluteString ?? ""
        #expect(!address.contains(keys[0]))
        // The client's own session: no cookie kept or sent, no cache, 15 seconds.
        let config = MailReads.Client.session.configuration
        #expect(config.httpCookieStorage == nil && !config.httpShouldSetCookies && config.urlCache == nil)
        #expect(config.timeoutIntervalForRequest == 15)

        // What it said, kept: by message, newest first.
        let seen = MailReads.seen(["<m0@example.com>", "<m3@example.com>", "<m1@example.com>", "<yours@nowhere>"], in: store)
        #expect(seen["<m0@example.com>"]?.sure == 2 && seen["<m3@example.com>"]?.maybe == 1)
        #expect(seen["<m1@example.com>"]?.isEmpty == true && seen["<yours@nowhere>"] == nil)
        // Asked again with nothing new: nothing new kept.
        #expect(!(await MailReads.ask(store, client: client, now: now)))
        #expect(store.opens(messages: ["<m0@example.com>"])["<m0@example.com>"]?.count == 2)
        // One thread's alone: its 50 keys in one ask.
        site.asked = []
        _ = await MailReads.ask(store, thread: "t1", client: client, now: now)
        #expect(site.asked.map(\.count) == [50])
        // The site away: nothing kept, asked again at the next turn.
        site.failures = [503]
        site.load(try #require(MailReads.token(for: keys[1])), kind: "other", at: now)
        #expect(!(await MailReads.ask(store, thread: "t1", client: client, now: now)))
        #expect(await MailReads.ask(store, thread: "t1", client: client, now: now))
    }

    // MARK: - said

    @Test func opensAreSaidInWordsAsMailSaysItsStatuses() {
        let now = Date(timeIntervalSince1970: 1_790_780_000)
        let opens = { (ago: [TimeInterval], kind: MailReads.Kind) in ago.map { MailReads.Open(at: now.addingTimeInterval(-$0), kind: kind) } }
        let three = MailReads.Seen(opens([7200, 86_400, 2 * 86_400], .google))
        #expect(MailReads.line(three, now: now) == "Opened 3× · last 2h ago")
        #expect(MailReads.short(three) == "Opened 3×")
        let one = MailReads.Seen(opens([300], .other))
        #expect(MailReads.line(one, now: now) == "Opened 5m ago")
        #expect(MailReads.short(one) == "Opened")
        #expect(MailReads.line(MailReads.Seen(opens([20], .google)), now: now) == "Opened just now")
        #expect(MailReads.line(MailReads.Seen(opens([3 * 86_400 + 60, 4 * 86_400], .google)), now: now) == "Opened 2× · last 3d ago")
        // A clock a little behind the site's: just now, never "in".
        #expect(MailReads.line(MailReads.Seen(opens([-5], .google)), now: now) == "Opened just now")
        // Not opened: nothing to say, in the thread or the row; to an agent, said so.
        let none = MailReads.Seen([])
        #expect(none.isEmpty && MailReads.line(none, now: now).isEmpty && MailReads.short(none).isEmpty)
        #expect(MailReads.told(none, now: now) == "not opened yet")
        #expect(MailReads.told(three, now: now) == "Opened 3× · last 2h ago")
    }

    @Test func applePrivacySaysMaybeWheneverItCame() {
        let now = Date(timeIntervalSince1970: 1_790_780_000)
        let at = { (ago: TimeInterval, kind: MailReads.Kind) in MailReads.Open(at: now.addingTimeInterval(-ago), kind: kind) }
        // Alone: a maybe, minutes after it went or days after.
        let early = MailReads.Seen([at(7200, .apple)])
        #expect(MailReads.line(early, now: now) == "Maybe opened 2h ago · Apple Mail’s privacy")
        #expect(MailReads.short(early) == "Maybe opened")
        let days = MailReads.Seen([at(3 * 86_400, .apple), at(5 * 86_400, .apple)])
        #expect(MailReads.line(days, now: now) == "Maybe opened 2× · last 3d ago · Apple Mail’s privacy")
        // Beside opens that count: those counted, the maybe said after them.
        let both = MailReads.Seen([at(600, .apple), at(3600, .google), at(7200, .other)])
        #expect(both.sure == 2 && both.maybe == 1)
        #expect(MailReads.line(both, now: now) == "Opened 2× · last 1h ago · 1 maybe, Apple Mail’s privacy")
        #expect(MailReads.short(both) == "Opened 2×")
    }

    @Test func listsAndMailReadSayIt() throws {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        let now = Date()
        let key = keep("<yab-q3@example.com>", thread: "q3", at: now.addingTimeInterval(-3 * 86_400), in: store)
        _ = keep("<yab-quiet@example.com>", thread: "quiet", at: now.addingTimeInterval(-86_400), in: store)
        store.keepOpens([key: [MailReads.Open(at: now.addingTimeInterval(-7200), kind: .google),
                               MailReads.Open(at: now.addingTimeInterval(-86_400), kind: .google)]])
        // A row: its newest mail of yours with a key, opened; a row whose wasn't says nothing.
        #expect(MailReads.rows(["q3", "quiet", "other"], in: store) == ["q3": "Opened 2×"])
        // A later mail of yours in it, not opened yet: the row says that one's, nothing.
        _ = keep("<yab-q3-again@example.com>", thread: "q3", at: now.addingTimeInterval(-3600), in: store)
        #expect(MailReads.rows(["q3"], in: store).isEmpty)
        // mail_read: the status on your mail, and only on yours.
        let mail = [
            MailMessage(id: "a", thread: "q3", from: Self.anna, to: [Self.me], subject: "Q3", date: now.addingTimeInterval(-4 * 86_400),
                        rfcID: "<a@fold.studio>", text: "Numbers?"),
            MailMessage(id: "b", thread: "q3", from: Self.me, to: [Self.anna], subject: "Re: Q3", date: now.addingTimeInterval(-3 * 86_400),
                        rfcID: "<yab-q3@example.com>", text: "Attached."),
            MailMessage(id: "c", thread: "q3", from: Self.me, to: [Self.anna], subject: "Re: Q3", date: now.addingTimeInterval(-3600),
                        rfcID: "<yab-q3-again@example.com>", text: "And the deck."),
        ]
        let text = MailAgent.read(mail, thread: "q3", reads: MailReads.seen(mail.map(\.rfcID), in: store))
        #expect(text.components(separatedBy: "Read status: ").count == 3)
        #expect(text.contains("Read status: Opened 2× · last 2h ago\n"))
        #expect(text.contains("Read status: not opened yet\n"))
        #expect(!MailAgent.read(mail, thread: "q3").contains("Read status"))
    }

    @Test func keysAndOpensOutliveTheStoreOpenedAgainAndAReset() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-reads-\(UUID().uuidString).sqlite")
        defer { MailAttachSendTests.clean(file) }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        var key = ""
        do {
            let store = MailStore(file: file)
            MailReads.set(true, in: store)
            key = keep("<yab-kept@example.com>", thread: "kept", at: now, in: store)
            store.keepOpens([key: [MailReads.Open(at: now, kind: .google)]])
        }
        // Opened again: the setting, the key and its open as they were.
        let again = MailStore(file: file)
        #expect(MailReads.on(again))
        #expect(again.readKeys(since: .distantPast).map(\.key) == [key])
        #expect(MailReads.seen(["<yab-kept@example.com>"], in: again)["<yab-kept@example.com>"]?.sure == 1)
        // A reset empties what came from Gmail, never these: the person's.
        let reset = MailStore(file: file, reset: MailStore.reset + 1)
        #expect(reset.readKeys(since: .distantPast).map(\.key) == [key])
        #expect(reset.opens(messages: ["<yab-kept@example.com>"])["<yab-kept@example.com>"]?.count == 1)
    }

    @Test func ourPictureNeverLoadsHere() {
        let token = "vkXLJgW_Nr695oSEGijw_Q"
        let ours = MailReads.image(token, base: MailReads.site)
        let picture = "<img src=\"https://fold.studio/deck.png\" width=\"600\" alt=\"Deck\">"
        // Your mail read here: ours goes, theirs stays.
        #expect(MailReads.strip("<div>Numbers.</div>" + picture + ours) == "<div>Numbers.</div>" + picture)
        // A reply quoting it, as Gmail's proxy writes the address; another site's /o/ stays.
        let proxied = "<img src=\"https://ci3.googleusercontent.com/meips/ADKq_Nb=s0-d-e1-ft#https://yetanotherbrowser.com/o/\(token).gif\" width=\"1\">"
        let elsewhere = "<img src=\"https://cdn.example.com/o/\(token).gif\">"
        #expect(MailReads.strip("<blockquote>Hi" + proxied + "</blockquote>" + elsewhere) == "<blockquote>Hi</blockquote>" + elsewhere)
        // Shown in a thread, whatever Block tracking pixels says (on here): never there.
        #expect(!MailHTML.clean("<p>Hi</p>" + ours).contains(token))
    }

    // MARK: - worlds

    /// A store and a Gmail of its own, on a host no other suite asks.
    func world() -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "reads-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01)
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        return (store, gmail, fake)
    }

    /// A store, the site in memory and a client asking it.
    func siteWorld() -> (MailStore, FakeOpensSite, MailReads.Client) {
        let site = FakeOpensSite()
        FakeOpensSite.serve(site, at: "opens.test")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeOpensProtocol.self]
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        return (store, site, MailReads.Client(base: URL(string: "https://opens.test")!, session: URLSession(configuration: config)))
    }

    /// A message's HTML part, its base64 undone.
    func html(_ raw: String) throws -> String {
        let tree = try #require(MIMETree(raw))
        return try #require(tree.parts.first { $0.type == "text/html" }).text
    }

    /// The last message Gmail was given, read back part by part.
    func last(_ fake: FakeGmail) throws -> MIMETree {
        let raw = try #require(fake.sent.last)
        return try #require(MIMETree(raw))
    }

    /// A draft sent now, through the journal, as ⌘↩ sends it once its undo window is over.
    func send(_ draft: MailDraft, store: MailStore, gmail: MailGmail) async throws {
        var draft = draft
        if draft.messageID.isEmpty { draft.messageID = MailCompose.messageID(from: "me@example.com") }
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
    }

    /// A mail of yours that went with a key, as MailOps.send keeps it.
    @discardableResult
    func keep(_ message: String, thread: String, at: Date, in store: MailStore) -> String {
        let key = store.readKey(message: message, at: at) { MailReads.encoded(MailReads.newKey()) } ?? ""
        store.readSent(message: message, thread: thread, at: at)
        return key
    }
}

/// The site as Yab asks it (fast-web docs/read-statuses.md), in memory: the
/// opens it wrote by token, each ask's keys and request, and failures to
/// answer with first. The token from a key worked out here on its own, not
/// by MailReads.
final class FakeOpensSite: @unchecked Sendable {
    var opens: [String: [(at: Date, kind: String)]] = [:]
    var asked: [[String]] = []
    var requests: [URLRequest] = []
    var failures: [Int] = []

    private static var sites: [String: FakeOpensSite] = [:]
    private static let lock = NSLock()

    static func serve(_ site: FakeOpensSite, at host: String) {
        lock.lock()
        defer { lock.unlock() }
        sites[host] = site
    }

    static func serving(_ request: URLRequest) -> FakeOpensSite? {
        lock.lock()
        defer { lock.unlock() }
        return sites[request.url?.host ?? ""]
    }

    func load(_ token: String, kind: String, at: Date) { opens[token, default: []].append((at, kind)) }

    static func token(_ key: String) -> String? {
        var plain = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        plain += String(repeating: "=", count: (4 - plain.count % 4) % 4)
        guard let bytes = Data(base64Encoded: plain), bytes.count == 16 else { return nil }
        return Data(SHA256.hash(data: bytes).prefix(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func answer(_ request: URLRequest) -> (Int, Data) {
        requests.append(request)
        guard request.httpMethod == "POST", request.url?.path == "/api/opens" else { return (404, Data()) }
        guard request.value(forHTTPHeaderField: "Content-Type") == "application/json" else { return (415, Data("{\"error\":\"type\"}".utf8)) }
        if !failures.isEmpty { return (failures.removeFirst(), Data("{\"error\":\"away\"}".utf8)) }
        guard let body = request.bodyData, body.count <= 8192,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let keys = json["keys"] as? [String],
              (1...200).contains(keys.count), keys.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{21}[AQgw]$", options: .regularExpression) != nil })
        else { return (400, Data("{\"error\":\"keys\"}".utf8)) }
        asked.append(keys)
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [String: Any] = [:]
        for key in Set(keys) {
            guard let token = FakeOpensSite.token(key), let list = opens[token], !list.isEmpty else { continue }
            out[key] = list.sorted { $0.at > $1.at }.prefix(50).map { ["at": format.string(from: $0.at), "kind": $0.kind] }
        }
        return (200, (try? JSONSerialization.data(withJSONObject: ["opens": out])) ?? Data())
    }
}

final class FakeOpensProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = FakeOpensSite.serving(request)?.answer(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
