import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Writing mail (docs/mail.md, Reply): whom a reply and a reply to all go
// to, a forward's subject, words and headers, Bcc in the message alone, the
// mail before quoted under the words, and Quick Quote taking exactly what
// is chosen in the thread.

struct MailComposeTests {
    let me = "me@example.com"
    let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")
    let bob = MailPerson(name: "Bob Reyes", address: "bob@northwind.vc")
    let carol = MailPerson(name: "Carol Diaz", address: "carol@lumen.studio")
    let utc = TimeZone(identifier: "UTC")!
    /// Tue, Sep 29, 2026 at 10:00 AM in UTC.
    let at = Date(timeIntervalSince1970: 1_790_676_000)

    func mail(_ id: String, from: MailPerson, to: [MailPerson], cc: [MailPerson] = [], replyTo: [MailPerson]? = [],
              subject: String = "Offsite plans", text: String = "Shall we keep Thursday?", refs: String = "") -> MailMessage {
        MailMessage(id: id, thread: "t1", from: from, to: to, cc: cc, subject: subject, date: at, rfcID: "<\(id)@mail>",
                    references: refs, replyTo: replyTo, text: text)
    }

    // MARK: - whom

    @Test func replyToAllLeavesYouAndYourAliasesOutOnceEach() throws {
        // You in another case and under an alias; Bob twice in two cases; Anna on her own Cc.
        let message = mail("a1", from: anna, to: [MailPerson(name: "Me", address: "Me@Example.com"), bob, MailPerson(name: "", address: "me+work@example.com")],
                           cc: [carol, MailPerson(name: "Bob", address: "BOB@northwind.vc"), anna])
        let all = try #require(MailCompose.replyAll(to: [message], me: me, aliases: ["ME+work@example.com"]))
        #expect(all.to == [anna, bob])
        #expect(all.cc == [carol])
        // R: the sender alone.
        let one = try #require(MailCompose.reply(to: [message], me: me, aliases: ["me+work@example.com"]))
        #expect(one.to == [anna])
        #expect(one.cc.isEmpty)
        #expect(one.subject == "Re: Offsite plans")
        #expect(one.inReplyTo == "<a1@mail>")
    }

    @Test func replyToWinsOverFrom() throws {
        let list = MailPerson(name: "Studio list", address: "list@fold.studio")
        let message = mail("a1", from: anna, to: [MailPerson(name: "", address: me), bob], cc: [carol], replyTo: [list])
        #expect(try #require(MailCompose.reply(to: [message], me: me)).to == [list])
        let all = try #require(MailCompose.reply(to: [message], me: me, all: true))
        #expect(all.to == [list, bob])
        #expect(all.cc == [carol])
        // Known to have none, or not known yet: From.
        #expect(try #require(MailCompose.reply(to: [mail("a2", from: anna, to: [], replyTo: [])], me: me)).to == [anna])
        #expect(try #require(MailCompose.reply(to: [mail("a3", from: anna, to: [], replyTo: nil)], me: me)).to == [anna])
    }

    @Test func aReplyToYourOwnLastMailGoesToWhomItWent() throws {
        let first = mail("a1", from: anna, to: [MailPerson(name: "", address: me)], subject: "Offsite plans")
        let mine = mail("a2", from: MailPerson(name: "Me", address: me), to: [anna, bob], cc: [carol], subject: "Re: Offsite plans",
                        text: "Thursday it is.", refs: "<a1@mail>")
        let one = try #require(MailCompose.reply(to: [first, mine], me: me))
        #expect(one.to == [anna, bob])
        #expect(one.cc.isEmpty)
        #expect(one.subject == "Re: Offsite plans")
        #expect(one.references == "<a1@mail> <a2@mail>")
        let all = try #require(MailCompose.reply(to: [first, mine], me: me, all: true))
        #expect(all.to == [anna, bob])
        #expect(all.cc == [carol])
        // Mail you sent only to yourself answers you.
        let note = mail("a3", from: MailPerson(name: "", address: me), to: [MailPerson(name: "", address: me)])
        #expect(try #require(MailCompose.reply(to: [note], me: me, all: true)).to.map(\.address) == [me])
    }

    // MARK: - forward

    @Test func aForwardOnceWithItsHeadItsWordsAndItsThread() throws {
        #expect(MailCompose.fwd("Deck v3") == "Fwd: Deck v3")
        #expect(MailCompose.fwd("Fwd: Deck v3") == "Fwd: Deck v3")
        #expect(MailCompose.fwd("FW: Deck v3") == "FW: Deck v3")
        #expect(MailCompose.fwd("Re: Deck v3") == "Fwd: Re: Deck v3")

        let first = mail("a1", from: MailPerson(name: "", address: me), to: [anna], subject: "Deck v3")
        let last = mail("a2", from: anna, to: [MailPerson(name: "", address: me)], cc: [bob], subject: "Re: Deck v3",
                        text: "Here it is.\r\nOne screen now.\n\n", refs: "<a1@mail>")
        let forward = try #require(MailCompose.forward([first, last], zone: utc))
        #expect(forward.thread == "t1")
        #expect(forward.to.isEmpty)
        #expect(forward.subject == "Fwd: Re: Deck v3")
        #expect(forward.inReplyTo == "<a2@mail>")
        #expect(forward.references == "<a1@mail> <a2@mail>")
        // Its files go with it once mail has them: which mail it is, kept.
        #expect(forward.forwarded == "a2")
        #expect(forward.quote == """
        ---------- Forwarded message ---------
        From: Anna Lindqvist <anna@fold.studio>
        Date: Tue, Sep 29, 2026 at 10:00 AM
        Subject: Re: Deck v3
        To: me@example.com
        Cc: Bob Reyes <bob@northwind.vc>

        Here it is.
        One screen now.
        """)

        var out = forward
        out.to = [carol]
        out.body = "FYI, the deck.\n"
        let raw = MailCompose.raw(out, from: MailPerson(name: "Me", address: me))
        let head = Self.head(raw)
        #expect(head.contains("Subject: Fwd: Re: Deck v3"))
        #expect(head.contains("In-Reply-To: <a2@mail>"))
        #expect(head.contains("References: <a1@mail> <a2@mail>"))
        #expect(Self.words(raw) == "FYI, the deck.\r\n\r\n" + forward.quote.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    // MARK: - Bcc

    @Test func bccIsInTheMessageAndNowhereInItsWords() {
        let draft = MailDraft(to: [anna], cc: [bob], bcc: [MailPerson(name: "Private", address: "private@example.org")],
                              subject: "Numbers", body: "September numbers attached.")
        let raw = MailCompose.raw(draft, from: MailPerson(name: "Me", address: me))
        let lines = Self.head(raw).components(separatedBy: "\r\n")
        #expect(lines.contains("Bcc: \"Private\" <private@example.org>"))
        // To, Cc, then Bcc, before the words.
        let order = ["To: ", "Cc: ", "Bcc: "].compactMap { name in lines.firstIndex { $0.hasPrefix(name) } }
        #expect(order == order.sorted() && order.count == 3)
        #expect(!Self.words(raw).contains("private@example.org"))
        #expect(!MailCompose.raw(MailDraft(to: [anna], body: "Hi"), from: MailPerson(name: "", address: me)).contains("Bcc:"))
    }

    // MARK: - the quote

    @Test func theQuoteSaysWhoWroteAndMarksEveryLineDeeperForAQuote() {
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let text = "Thursday works.\r\n\r\n\(long)\n\nOn Mon, Sep 28, 2026 at 9:00 AM, Me <me@example.com> wrote:\n> Shall we meet?\n>> Earlier words\n\n\n"
        let quote = MailCompose.quote(mail("a1", from: anna, to: [], text: text), zone: utc)
        #expect(quote == """
        On Tue, Sep 29, 2026 at 10:00 AM, Anna Lindqvist <anna@fold.studio> wrote:
        > Thursday works.
        >
        > \(long)
        >
        > On Mon, Sep 28, 2026 at 9:00 AM, Me <me@example.com> wrote:
        >> Shall we meet?
        >>> Earlier words
        """)
        // A long line stays one line, marked once.
        #expect(quote.components(separatedBy: "\n").filter { $0.contains("word word") }.count == 1)
        // Under the words, a blank line between, as it goes.
        var reply = MailDraft(to: [anna], subject: "Re: Offsite plans", body: "See you then.\n\n", quote: quote)
        #expect(MailCompose.text(reply) == "See you then.\n\n" + quote)
        reply.body = ""
        #expect(MailCompose.text(reply) == quote)
        // And so the thread folds it behind •••, the reply's own words apart.
        let back = MailDesk.Message.split("See you then.\n\n" + quote)
        #expect(back.own == "See you then.")
        #expect(back.quote == quote)
        let forwarded = MailDesk.Message.split("FYI.\n\n" + MailCompose.forwardLine + "\nFrom: Anna\n\nHello")
        #expect(forwarded.own == "FYI.")
        // As Gmail hands a plain mail back, lines ending in \r\n: "On … wrote:" goes behind ••• with the rest.
        let crlf = MailDesk.Message.split("Reply sent from Yab.\r\n\r\nOn Mon, Oct 5, 2026 at 9:28 AM, sam wrote:\r\n> Demo mail\r\n")
        #expect(crlf.own == "Reply sent from Yab.")
        #expect(crlf.quote == "On Mon, Oct 5, 2026 at 9:28 AM, sam wrote:\n> Demo mail")
        // A long one wrapped before "wrote:", as Gmail wraps it.
        let wrapped = MailDesk.Message.split("Sounds good.\n\nOn Mon, Oct 5, 2026 at 9:28 AM Anna Lindqvist <anna@fold.studio>\nwrote:\n> Shall we?")
        #expect(wrapped.own == "Sounds good.")
        #expect(wrapped.quote?.hasPrefix("On Mon, Oct 5, 2026") == true)
        // Under its bar a quote shows one ">" fewer; nested ones keep the rest.
        #expect(MailDesk.Message.unmarked("On Mon, Anna wrote:\n> Shall we?\n>> Earlier\n>") == "On Mon, Anna wrote:\nShall we?\n> Earlier\n")
    }

    @Test func aMailOnlyInHTMLIsQuotedFromItsWordsItsQuotesNested() throws {
        let html = """
        <div dir="ltr">Sounds <b>good</b>.</div><div class="gmail_quote"><div class="gmail_attr">On Mon, Me wrote:</div>\
        <blockquote class="gmail_quote" style="margin:0">Shall we meet?<br><blockquote>Earlier words</blockquote></blockquote></div>
        """
        let json: [String: Any] = ["id": "h1", "threadId": "t1", "internalDate": "1790676000000", "snippet": "Sounds good.",
                                   "payload": ["mimeType": "text/html", "headers": [["name": "From", "value": "Anna Lindqvist <anna@fold.studio>"]],
                                               "body": ["data": MailGmail.encode(html)]]]
        let message = try #require(MailGmail.message(json, full: true))
        #expect(message.html != nil)
        #expect(MailCompose.quote(message, zone: utc) == """
        On Tue, Sep 29, 2026 at 10:00 AM, Anna Lindqvist <anna@fold.studio> wrote:
        > Sounds good.
        > On Mon, Me wrote:
        >> Shall we meet?
        >>> Earlier words
        """)
    }

    // MARK: - Quick Quote

    @Test func quickQuoteIsExactlyTheWordsChosen() {
        #expect(MailCompose.quickQuote("  can we do Thursday at 3?\n") == "> can we do Thursday at 3?\n\n")
        #expect(MailCompose.quickQuote("first line\r\nsecond line") == "> first line\n> second line\n\n")
        #expect(MailCompose.quickQuote(" \n ").isEmpty)
    }

    /// What a drag in a mail's own words leaves chosen (SwiftUI's
    /// selectable text, whose view is the window's first responder): Quick
    /// Quote reads exactly that, and nothing from words being written.
    @MainActor @Test func quickQuoteReadsWhatIsChosenInTheThread() async throws {
        let words = "Can we do the review this week? Thursday or Friday both work."
        let host = NSHostingView(rootView: Text(words).textSelection(.enabled).frame(width: 420, height: 80))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 420, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        var all: [NSView] = []
        func walk(_ view: NSView) { all.append(view); view.subviews.forEach(walk) }
        // SwiftUI installs its selectable text after the hosting view's first turn.
        // Yield the main actor until it is present, rather than inspecting a blank host.
        for _ in 0..<100 {
            all = []
            host.layoutSubtreeIfNeeded()
            walk(host)
            if all.contains(where: { $0.accessibilityValue() as? String == words || ($0 as? NSTextField)?.stringValue == words }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try #require(all.first { $0.accessibilityValue() as? String == words || ($0 as? NSTextField)?.stringValue == words })
        #expect(window.makeFirstResponder(text))
        let chosen = try #require(words.range(of: "Thursday or Friday"))
        text.setAccessibilitySelectedTextRange(NSRange(chosen, in: words))
        #expect(MailDesk.chosen(in: window) { _ in } == "Thursday or Friday")
        // Nothing chosen, nothing quoted.
        text.setAccessibilitySelectedTextRange(NSRange(location: 3, length: 0))
        #expect(MailDesk.chosen(in: window) { _ in } == nil)
        // Words being written are not the thread's.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        host.addSubview(editor)
        editor.string = "my own reply"
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(MailDesk.chosen(in: window) { _ in } == nil)
    }

    // MARK: - kept

    @Test func aDraftKeepsItsBccQuoteAndWhatItForwards() {
        let store = MailStore(file: MailStore.memory)
        let forward = MailDraft(id: "forward:t1", thread: "t1", to: [carol], bcc: [bob], subject: "Fwd: Deck v3", body: "",
                                inReplyTo: "<a2@mail>", references: "<a1@mail> <a2@mail>", quote: "---------- Forwarded message ---------\nHello",
                                forwarded: "a2")
        store.save(forward)
        #expect(store.draft("forward:t1") == forward)
        // In Kept with no note: a forward with someone to go to.
        #expect(store.drafts().map(\.id) == ["forward:t1"])
        #expect(store.drafts().first?.forwarded == "a2")
        store.save(MailDraft(id: "forward:t2", thread: "t2", subject: "Fwd: Other", forwarded: "b1"))
        #expect(store.drafts().map(\.id) == ["forward:t1"])
    }

    @Test func aReplyReadyUnderAThreadMaySayWhomItAnswers() {
        let all = MailDesk.Ready(stored: MailDesk.Ready.stored("Thursday works for both of us.", everyone: true), by: "Written by Claude")
        #expect(all.text == "Thursday works for both of us.")
        #expect(all.everyone == true)
        #expect(all.label == "Thursday works")
        #expect(MailDesk.Ready(stored: MailDesk.Ready.stored("Yes.", everyone: false), by: "").everyone == false)
        let ahead = MailDesk.Ready(stored: "Both join\u{1F}Lena and Tom join.", by: "Written ahead")
        #expect(ahead.named == "Both join")
        #expect(ahead.everyone == nil)
    }

    @MainActor @Test func theKeysAreTheKeymapsToChange() {
        #expect(Shortcut.byAction[.mailReplyAll]?.key == Hotkey("↩", []))
        #expect(Shortcut.byAction[.mailForwardMail]?.key == Hotkey("f", []))
        #expect(Shortcut.byAction[.mailBcc]?.key == Hotkey("b", [.shift, .command]))
        #expect(Shortcut.byAction[.mailSubject]?.key == Hotkey("s", [.shift, .command]))
        // ↩ is the thread's reply to all alone; R stays the sender's.
        #expect(Keymap.valid(Hotkey("↩", []), for: .mailReplyAll))
        #expect(Keymap.valid(Hotkey("a", []), for: .mailReplyAll))
        #expect(!Keymap.valid(Hotkey("↩", []), for: .mailForwardMail))
        // Bcc and the subject work while words are written: never a bare key.
        #expect(!Keymap.valid(Hotkey("b", []), for: .mailBcc))
        #expect(!Keymap.valid(Hotkey("s", []), for: .mailSubject))
        #expect([.mailReplyAll, .mailForwardMail, .mailBcc, .mailSubject].allSatisfy { Shortcut.context($0) == .mail })
    }

    // MARK: - the message as it goes

    /// Its headers, before the blank line.
    static func head(_ raw: String) -> String { raw.components(separatedBy: "\r\n\r\n").first ?? "" }

    /// Its words, out of base64.
    static func words(_ raw: String) -> String {
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n").replacingOccurrences(of: "\r\n", with: "")
        return Data(base64Encoded: body).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// A reply to all and a forward through the engine, against a Gmail kept
/// in memory: Reply-To and Cc as the sync keeps them, Bcc in what Gmail is
/// handed, a forward in its thread. With MailSyncTests, one at a time: the
/// fake Gmail is one for the whole run (FakeGmail.current).
extension MailSyncAppTests {
    @Test func replyToAllAndAForwardGoOutAsGmailTakesThem() async throws {
        let (store, gmail, fake) = world()
        let now = Date()
        fake.add(.init(id: "o1", thread: "to", from: "Anna Lindqvist <anna@fold.studio>", to: "me@example.com, Bob Reyes <bob@northwind.vc>",
                       subject: "Offsite plans", body: "Shall we keep Thursday?", at: now.addingTimeInterval(-600), labels: ["INBOX", "UNREAD"],
                       rfc: "<o1@fold.studio>", replyTo: "Offsite <offsite@fold.studio>", cc: "Carol Diaz <carol@lumen.studio>"), record: false)
        try await MailSync(store: store, gmail: gmail).sync()
        // The sync keeps what a reply needs: Reply-To, Cc.
        let kept = try #require(store.message("o1"))
        #expect(kept.replyTo == [MailPerson(name: "Offsite", address: "offsite@fold.studio")])
        #expect(kept.cc == [MailPerson(name: "Carol Diaz", address: "carol@lumen.studio")])

        var reply = try #require(MailCompose.reply(to: store.messages(thread: "to"), me: store.me, all: true))
        #expect(reply.to.map(\.address) == ["offsite@fold.studio", "bob@northwind.vc"])
        #expect(reply.cc.map(\.address) == ["carol@lumen.studio"])
        reply.id = "reply:to"
        reply.bcc = [MailPerson(name: "", address: "assistant@example.com")]
        reply.body = "Thursday it is."
        reply.messageID = MailCompose.messageID(from: store.me)
        store.save(reply)
        MailOps.act(.send, thread: reply.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        let raw = try #require(fake.sent.first)
        #expect(fake.messages["s1"]?.thread == "to")
        #expect(fake.messages["s1"]?.bcc == "assistant@example.com")
        #expect(MailComposeTests.head(raw).contains("To: \"Offsite\" <offsite@fold.studio>, \"Bob Reyes\" <bob@northwind.vc>"))
        let words = MailComposeTests.words(raw)
        #expect(words.hasPrefix("Thursday it is.\r\n\r\nOn "))
        #expect(words.contains("Anna Lindqvist <anna@fold.studio> wrote:\r\n> Shall we keep Thursday?"))

        // Forward the original message; the sent reply is already in the cache.
        var forward = try #require(MailCompose.forward([kept]))
        forward.id = "forward:to"
        forward.to = [MailPerson(name: "Tim Okafor", address: "tim@okafor.co")]
        forward.body = "FYI."
        store.save(forward)
        MailOps.act(.send, thread: forward.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 2)
        #expect(fake.messages["s2"]?.thread == "to")
        #expect(fake.messages["s2"]?.subject == "Fwd: Offsite plans")
        #expect(MailComposeTests.head(fake.sent[1]).contains("In-Reply-To: <o1@fold.studio>"))
        #expect(MailComposeTests.words(fake.sent[1]).contains("---------- Forwarded message ---------\r\nFrom: Anna Lindqvist <anna@fold.studio>"))
        #expect(store.draft("forward:to") == nil)
    }
}
