import AppKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// A mail's words with their marks (docs/mail.md, Writing): our own HTML
// writer, line for line (nested lists, links, what HTML would fold or read
// as tags, empty lines), read back exactly and as plain text with no marks;
// HTML from elsewhere (a Gmail signature, a page, Google Docs) kept to the
// set; Gmail's send-as list read, the address a reply goes from, From with
// an alias in the message, and the message as multipart/alternative inside
// multipart/mixed with a file; the text view's marks, lists and pastes.

struct MailRichTests {
    typealias Line = MailRich.Line
    typealias Run = MailRich.Run

    // MARK: - the HTML writer

    @Test func theWriterNestsListsLinksAndMarksAsItShould() {
        let doc: MailRich.Doc = [
            Line([], [Run(text: "Hi "), Run(text: "Anna", bold: true), Run(text: ",")]),
            Line(""),
            Line([.bullet], [Run(text: "one")]),
            Line([.bullet, .bullet], [Run(text: "nested "), Run(text: "deep", italic: true, underline: true)]),
            Line([.bullet], [Run(text: "two")]),
            Line([.number], [Run(text: "first")]),
            Line([], [Run(text: "See "), Run(text: "the deck", link: "https://fold.studio/deck?a=1&b=2"), Run(text: ".")]),
        ]
        let html = MailRich.html(doc)
        #expect(html == "Hi <b>Anna</b>,<br><br><ul><li>one<ul><li>nested <i><u>deep</u></i></li></ul></li><li>two</li></ul>"
                + "<ol><li>first</li></ol>See <a href=\"https://fold.studio/deck?a=1&amp;b=2\">the deck</a>.")
        // Read back line for line, every mark where it was.
        #expect(MailRich.doc(html: html) == doc)
        // The words alone: no tag, no star, a link's address after its words.
        let text = MailRich.text(doc)
        #expect(text == "Hi Anna,\n\n- one\n  - nested deep\n- two\n1. first\nSee the deck <https://fold.studio/deck?a=1&b=2>.")
        #expect(!text.contains("<b>") && !text.contains("*") && !text.contains("_"))
        // Back to text: what the HTML says is what the plain part says.
        #expect(MailRich.text(MailRich.doc(html: html)) == text)
    }

    @Test func marksOpenAndCloseOnlyWhereTheyChange() {
        let line = Line([], [Run(text: "a", link: "https://x.io"), Run(text: "b", bold: true, link: "https://x.io"),
                             Run(text: "c", bold: true, italic: true), Run(text: "d", bold: true), Run(text: "e")])
        let html = MailRich.html([line])
        #expect(html == "<a href=\"https://x.io\">a<b>b</b></a><b><i>c</i>d</b>e")
        #expect(MailRich.doc(html: html) == [line])
    }

    @Test func whatHTMLWouldFoldOrReadAsTagsIsEscaped() {
        let doc: MailRich.Doc = [
            Line("  two  spaces  "),
            Line("a < b && c > d \"quoted\" 'single'"),
            Line("\tindented\u{A0}and no-break"),
            Line("&nbsp; typed as words, and <b>not bold</b>"),
            Line([], [Run(text: "link", link: "https://q.io/?x=\"1\"&y=<2>")]),
        ]
        let html = MailRich.html(doc)
        #expect(html.hasPrefix("&nbsp;&nbsp;two &nbsp;spaces &nbsp;<br>"))
        #expect(html.contains("a &lt; b &amp;&amp; c &gt; d \"quoted\" 'single'<br>"))
        #expect(html.contains("&#9;indented&#160;and no-break<br>"))
        #expect(html.contains("&amp;nbsp; typed as words, and &lt;b&gt;not bold&lt;/b&gt;<br>"))
        #expect(html.contains("<a href=\"https://q.io/?x=&quot;1&quot;&amp;y=&lt;2&gt;\">link</a>"))
        #expect(MailRich.doc(html: html) == doc)
    }

    @Test func emptyLinesStandAsTheyWereWritten() {
        // Before the words, between them, two together, at the end, in a
        // list's item, in a quote, before and after a list.
        let docs: [MailRich.Doc] = [
            [Line(""), Line("a"), Line(""), Line(""), Line("b"), Line("")],
            [Line("")],
            [Line("intro"), Line(""), Line("x", [.bullet]), Line("", [.bullet]), Line("y", [.bullet]), Line(""), Line("after")],
            [Line("a", [.quote]), Line("", [.quote]), Line("b", [.quote]), Line("", [.quote])],
            [Line("", [.bullet]), Line("deeper", [.bullet, .bullet])],
            [Line("x", [.quote, .number]), Line("y", [.quote, .number]), Line("", [.quote]), Line("z", [.quote, .quote])],
        ]
        for doc in docs {
            let html = MailRich.html(doc)
            #expect(MailRich.doc(html: html) == doc, "\(html)")
        }
        #expect(MailRich.html(docs[0]) == "<br>a<br><br><br>b<br><br>")
        #expect(MailRich.html(docs[2]) == "intro<br><br><ul><li>x</li><li><br></li><li>y</li></ul><br>after")
        // Trimmed, as a draft keeps them: none at the end.
        #expect(MailRich.trimmed(docs[0]) == Array(docs[0].prefix(5)))
    }

    @Test func numbersCountAsAMailReaderCountsThem() {
        let doc: MailRich.Doc = [Line("a", [.number]), Line("x", [.number, .number]), Line("y", [.number, .number]), Line("b", [.number]),
                                 Line(""), Line("c", [.number]), Line("d", [.bullet]), Line("e", [.number])]
        #expect(MailRich.numbers(doc) == [1, 1, 2, 2, nil, 1, nil, 1])
        #expect(MailRich.text(doc) == "1. a\n  1. x\n  2. y\n2. b\n\n1. c\n- d\n1. e")
    }

    @Test func onlyMarksPlainTextCantCarryMakeAMailFormatted() {
        #expect(!MailRich.formatted(MailRich.plain("Plain words,\n\nand more.")))
        // A link that says its own address: plain text says as much.
        #expect(!MailRich.formatted([Line([], [Run(text: "fold.studio", link: "http://fold.studio/")])]))
        #expect(!MailRich.formatted([Line([], [Run(text: "me@fold.studio", link: "mailto:me@fold.studio")])]))
        #expect(MailRich.formatted([Line([], [Run(text: "the deck", link: "https://fold.studio/deck")])]))
        #expect(MailRich.formatted([Line([], [Run(text: "x", underline: true)])]))
        #expect(MailRich.formatted([Line("x", [.quote])]))
        // Only http, https and mailto are links a mail carries.
        #expect(MailRich.safe("javascript:alert(1)") == nil)
        #expect(MailRich.safe("file:///etc/passwd") == nil)
        #expect(MailRich.address("www.fold.studio") == "https://www.fold.studio")
        #expect(MailRich.address("https://fold.studio/deck v3") == nil)
        #expect(MailRich.address("hello") == nil)
    }

    // MARK: - HTML from elsewhere

    @Test func aGmailSignatureAsWords() {
        let html = """
        <div dir="ltr"><div><b>Sam Rivera</b></div><div>Founder, <a href="https://acme.example">acme.example</a> &amp; <a href="https://yetanotherbrowser.com/manual">Yab</a></div>\
        <div><img src="https://ci3.googleusercontent.com/logo.png" width="96" alt="logo"></div>\
        <table><tr><td>Tel</td><td>+1&nbsp;555&nbsp;0100</td></tr></table><style>.x{color:red}</style></div>
        """
        let signature = MailSignature(html: html)
        #expect(signature.text == "Sam Rivera\nFounder, acme.example & Yab <https://yetanotherbrowser.com/manual>\nTel +1 555 0100")
        #expect(signature.shown == "Sam Rivera\nFounder, acme.example & Yab\nTel +1 555 0100")
        // Bold and a picture: it needs the HTML part to go as it is.
        #expect(signature.marked)
        #expect(!MailSignature(html: "<div>Sam</div><div>acme.example</div>").marked)
        #expect(MailSignature(html: "<div><br></div>").isEmpty)
        // As a draft shows it: its words and its picture in their order, the picture at its tag's width.
        #expect(signature.pieces == [.words("Sam Rivera\nFounder, acme.example & Yab"),
                                     .picture(URL(string: "https://ci3.googleusercontent.com/logo.png")!, width: 96, height: nil),
                                     .words("Tel +1 555 0100")])
    }

    /// A signature's pictures under a draft's words: one by https or data:
    /// shown, one by cid: (no bytes to fetch) said instead, a tracking
    /// pixel left out as mail leaves it out.
    @Test func aSignaturesPicturesAsADraftShowsThem() {
        let signature = MailSignature(html: #"<div>Sam</div><img src='cid:mark@fold.studio'><img src="https://t.example/o.gif" width="1" height="1">"#
                                      + #"<img src="data:image/png;base64,iVBORw0KGgo=" height="20"><div>Fold</div>"#)
        #expect(signature.pieces == [.words("Sam"), .unshown, .picture(URL(string: "data:image/png;base64,iVBORw0KGgo=")!, width: nil, height: 20),
                                     .words("Fold")])
        #expect(MailSignature.picture(#"<img alt="x" src="https://a.example/l.png?w=1&amp;h=2">"#)
                == .picture(URL(string: "https://a.example/l.png?w=1&h=2")!, width: nil, height: nil))
        #expect(MailSignature.picture("<img src=javascript:alert(1)>") == .unshown)
    }

    @Test func wordsPastedFromGoogleDocsAndPagesKeepOnlyTheSet() {
        // Google Docs wraps everything in a bold that isn't, and says marks by style.
        let docs = """
        <meta charset='utf-8'><b style="font-weight:normal;" id="docs-internal-guid-1"><p dir="ltr" style="line-height:1.38">\
        <span style="font-size:11pt;font-family:Arial;color:#000;font-weight:400">Plain then </span><span style="font-weight:700">bold</span>\
        <span style="font-style:italic"> italic</span></p><p dir="ltr"><span style="text-decoration:underline">under</span></p></b>
        """
        #expect(MailRich.doc(html: docs) == [
            Line([], [Run(text: "Plain then "), Run(text: "bold", bold: true), Run(text: " italic", italic: true)]),
            Line(""),
            Line([], [Run(text: "under", underline: true)]),
        ])
        // A page: headings bold, a script, a style and comments left out, a
        // link that isn't one dropped, lists and a quote kept, a table's cells side by side.
        let page = """
        <!DOCTYPE html><html><head><title>T</title><style>p{color:red}</style></head><body><!-- a comment <b>x</b> -->
        <h2>Title</h2><script>document.write("<p>no</p>")</script><p>Body with <a href="javascript:alert(1)">no link</a> and
        <a href='https://ok.example/a?b=1&amp;c=2'>a link</a>.</p><ul><li><p>item one</p></li><li>item <strong>two</strong>
        <ol><li>inner</li></ol></li></ul><blockquote>said <em>before</em></blockquote><table><tr><td>A</td><td>B</td></tr></table></body></html>
        """
        #expect(MailRich.doc(html: page) == [
            Line([], [Run(text: "Title", bold: true)]),
            Line([], [Run(text: "Body with no link and "), Run(text: "a link", link: "https://ok.example/a?b=1&c=2"), Run(text: ".")]),
            Line("item one", [.bullet]),
            Line([.bullet], [Run(text: "item "), Run(text: "two", bold: true)]),
            Line("inner", [.bullet, .number]),
            Line([.quote], [Run(text: "said "), Run(text: "before", italic: true)]),
            Line("A B"),
        ])
    }

    @Test func wordsFromTextEditKeepTheirBoldAndTheirListWithoutItsMarkers() throws {
        // TextEdit's RTF: a big red bold word, a bulleted list with its
        // markers as TextEdit writes them.
        let rtf = #"""
        {\rtf1\ansi\ansicpg1252\cocoartf2822
        \cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;\f1\fswiss\fcharset0 Helvetica-Bold;}
        {\colortbl;\red255\green255\blue255;\red255\green0\blue0;}
        {\*\expandedcolortbl;;}
        {\*\listtable{\list\listtemplateid1\listhybrid{\listlevel\levelnfc23\levelnfcn23\leveljc0\leveljcn0\levelfollow0\levelstartat1\levelspace360\levelindent0{\*\levelmarker \{disc\}}{\leveltext\leveltemplateid1\'01\uc0\u8226 ;}{\levelnumbers;}\fi-360\li720\lin720 }{\listname ;}\listid1}}
        {\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}}
        \pard\tx720\tx1440\pardirnatural\partightenfactor0

        \f0\fs40 \cf0 Hello 
        \f1\b \cf2 there
        \f0\b0 \cf0 \
        \pard\tx220\tx720\pardeftab720\li720\fi-720\pardirnatural\partightenfactor0
        \ls1\ilvl0\fs24 \cf0 {\listtext\tab \uc0\u8226 \tab }First\
        {\listtext\tab \uc0\u8226 \tab }Second}
        """#
        let board = NSPasteboard(name: NSPasteboard.Name("yab.test.rtf.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Data(rtf.utf8), forType: .rtf)
        #expect(MailRich.doc(from: board) == [Line([], [Run(text: "Hello "), Run(text: "there", bold: true)]), Line("First", [.bullet]), Line("Second", [.bullet])])
    }

    @Test func aBigPageIsReadQuickly() {
        // A newsletter's worth of tables, styles and comments, pasted.
        let row = "<tr><td style=\"padding:16px\"><!-- a comment --><a href=\"https://example.com/a\"><img src=\"x.jpg\"></a>"
            + "<p style=\"font:14px Helvetica\">Ten links worth your time, <b>this week</b> &amp; more.</p></td></tr>"
        let page = "<html><head><style>td{color:#333}</style></head><body><table>" + String(repeating: row, count: 2_000) + "</table></body></html>"
        let started = Date()
        let doc = MailRich.doc(html: page)
        #expect(Date().timeIntervalSince(started) < 2, "reading \(page.count) characters took too long")
        #expect(doc.filter { !$0.runs.isEmpty }.count == 2_000)
    }

    @Test func brokenHTMLStillGivesItsWords() {
        #expect(MailRich.doc(html: "<a =x>link</a> and <b>bold") == [Line([], [Run(text: "link and "), Run(text: "bold", bold: true)])])
        #expect(MailRich.doc(html: "a < b, <3 and <> and </> ok") == [Line("a < b, <3 and <> and </> ok")])
        // End tags with nothing open to end are passed over, as a browser does.
        #expect(MailRich.doc(html: "<p>one<p>two</div></li>three") == [Line("one"), Line("twothree")])
        #expect(MailRich.doc(html: "<!-- never closed <b>x</b>").isEmpty)
        #expect(MailRich.doc(html: "<script>if (a<b) document.write('<p>x</p>')</script>after") == [Line("after")])
    }

    @Test func gmailsOwnLinesComeBackAsLines() {
        let gmail = "<div dir=\"ltr\"><div>Hi Anna,</div><div><br></div><div>The deck is attached.<br></div><div>Thanks</div></div>"
        #expect(MailRich.doc(html: gmail) == [Line("Hi Anna,"), Line(""), Line("The deck is attached."), Line("Thanks")])
    }

    // MARK: - the message

    let me = MailPerson(name: "", address: "me@example.com")
    let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")

    /// Gmail's answer for an account with an alias: the account's own, the
    /// alias as the default with a name, a Reply-To and a signature, and an
    /// address not verified yet.
    static let sendAsJSON: [String: Any] = ["sendAs": [
        ["sendAsEmail": "Sam@Fold.Studio", "displayName": "Sam Rivera", "replyToAddress": "replies@fold.studio",
         "signature": "<div dir=\"ltr\"><b>Sam Rivera</b><div>Fold Studio</div></div>", "isPrimary": false, "isDefault": true,
         "treatAsAlias": true, "verificationStatus": "accepted"],
        ["sendAsEmail": "me@example.com", "displayName": "", "replyToAddress": "", "signature": "", "isPrimary": true, "isDefault": false],
        ["sendAsEmail": "pending@else.org", "displayName": "Pending", "isPrimary": false, "verificationStatus": "pending"],
    ]]

    @Test func sendAsIsReadAccountsOwnFirstAndOnlyWhatGmailSendsFrom() {
        let all = MailSendAs.list(Self.sendAsJSON)
        #expect(all.map(\.address) == ["me@example.com", "sam@fold.studio"])
        #expect(all[0].primary && !all[0].isDefault && all[0].name.isEmpty)
        #expect(all[1].name == "Sam Rivera" && all[1].isDefault && all[1].replyTo == "replies@fold.studio")
        #expect(all[1].signature.contains("<b>Sam Rivera</b>"))
        #expect(MailSendAs.defaultAddress(all, me: "me@example.com") == "sam@fold.studio")
        #expect(MailSendAs.defaultAddress([], me: "me@example.com") == "me@example.com")
        #expect(MailSendAs.list(["nothing": true]).isEmpty)
    }

    @Test func aReplyGoesFromTheAddressTheMailCameTo() {
        let all = MailSendAs.list(Self.sendAsJSON)
        let mail = { (to: [MailPerson], cc: [MailPerson], from: MailPerson) in
            MailMessage(id: "m", thread: "t", from: from, to: to, cc: cc, subject: "Hi", date: Date())
        }
        // To the alias, the account's own in Cc: the alias, To before Cc.
        #expect(MailSendAs.address(answering: mail([MailPerson(name: "Sam", address: "sam@fold.studio")], [me], anna), all, me: me.address)
                == "sam@fold.studio")
        // To the account's own: from it, though the alias is the default.
        #expect(MailSendAs.address(answering: mail([me], [], anna), all, me: me.address) == "me@example.com")
        // Bcc'd, none of yours on it: the default.
        #expect(MailSendAs.address(answering: mail([MailPerson(name: "", address: "team@fold.studio")], [], anna), all, me: me.address)
                == "sam@fold.studio")
        // Your own mail, answered again: from where it went.
        #expect(MailSendAs.address(answering: mail([anna], [], MailPerson(name: "", address: "SAM@fold.studio")), all, me: me.address)
                == "sam@fold.studio")
        // The name a From says: the alias's, or none for the account's own here.
        #expect(MailSendAs.person("sam@fold.studio", all, me: me.address) == MailPerson(name: "Sam Rivera", address: "sam@fold.studio"))
        #expect(MailSendAs.person("", all, me: me.address).address == "sam@fold.studio")
        #expect(MailSendAs.person("me@example.com", all, me: me.address).name == "")
    }

    @Test func fromAnAliasInTheMessageWithItsReplyToAndSignature() throws {
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        store.keep(sendAs: MailSendAs.list(Self.sendAsJSON))
        #expect(store.aliases == ["sam@fold.studio"])
        var draft = MailDraft(to: [anna], subject: "Q3", body: "Numbers attached.", messageID: "<q3@fold.studio>")
        draft.from = "sam@fold.studio"
        draft.signed = true
        let (from, extras) = MailCompose.going(draft, store: store)
        #expect(from == MailPerson(name: "Sam Rivera", address: "sam@fold.studio"))
        let raw = MailCompose.raw(draft, from: from, extras: extras)
        let tree = try #require(MIMETree(raw))
        #expect(tree.head["from"] == "\"Sam Rivera\" <sam@fold.studio>")
        #expect(tree.head["reply-to"] == "replies@fold.studio")
        // A bold signature: the words go as text and HTML, the text with no mark.
        #expect(tree.type == "multipart/alternative")
        #expect(tree.parts.map(\.type) == ["text/plain", "text/html"])
        #expect(tree.parts[0].text == "Numbers attached.\r\n\r\n-- \r\nSam Rivera\r\nFold Studio")
        #expect(tree.parts[1].text.contains("<div class=\"gmail_signature\">-- <br><div dir=\"ltr\"><b>Sam Rivera</b>"))
        // A signature of your own for it, written in Settings › Mail, plain: a plain mail again.
        store.setSignature("Sam<br>Fold", for: "sam@fold.studio")
        let plain = try #require(MIMETree(MailCompose.raw(draft, from: from, extras: MailCompose.going(draft, store: store).extras)))
        #expect(plain.type == "text/plain")
        #expect(plain.text == "Numbers attached.\r\n\r\n-- \r\nSam\r\nFold")
        // Not signed (a reply, as Settings says; an agent's draft; a nudge): no signature at all.
        draft.signed = false
        let bare = try #require(MIMETree(MailCompose.raw(draft, from: from, extras: MailCompose.going(draft, store: store).extras)))
        #expect(bare.type == "text/plain" && bare.text == "Numbers attached.")
        // The account's own address with no name: the address alone, no Reply-To.
        draft.from = "me@example.com"
        let own = MailCompose.going(draft, store: store)
        #expect(own.from == MailPerson(name: "", address: "me@example.com") && own.extras.replyTo.isEmpty)
        #expect(MailCompose.raw(draft, from: own.from, extras: own.extras).hasPrefix("From: me@example.com\r\n"))
    }

    @Test func markedWordsGoAsAlternativeInsideMixedWithAFile() throws {
        let deck = Data("%PDF-1.4 deck".utf8)
        var draft = MailDraft(to: [anna], subject: "Deck", body: "Deck attached, see slide 4.", messageID: "<deck@fold.studio>")
        draft.html = "Deck attached, see <b>slide 4</b>."
        let raw = MailCompose.raw(draft, from: me, files: [.init(name: "Deck v3.pdf", mime: "application/pdf", data: deck)])
        let tree = try #require(MIMETree(raw))
        #expect(tree.type == "multipart/mixed")
        try #require(tree.parts.count == 2)
        let words = tree.parts[0]
        #expect(words.type == "multipart/alternative")
        #expect(words.parts.map(\.type) == ["text/plain", "text/html"])
        // The text part has no mark; the HTML part has the <b>.
        #expect(words.parts[0].text == "Deck attached, see slide 4.")
        #expect(words.parts[1].text == "<div dir=\"auto\">Deck attached, see <b>slide 4</b>.</div>")
        #expect(tree.parts[1].head["content-disposition"]?.hasPrefix("attachment;") == true)
        #expect(tree.parts[1].data == deck)
        // Gmail reads the same message: its first text/plain and text/html, the file beside them.
        let back = try #require(MailGmail.message(FakeMime.payload(raw, id: "s1"), full: true))
        #expect(back.text == "Deck attached, see slide 4.")
        #expect(back.html?.contains("<b>slide 4</b>") == true)
        #expect(back.files?.map(\.name) == ["Deck v3.pdf"])
    }

    @Test func plainWordsStayTextAloneUnlessATwinOrATailAsks() throws {
        let draft = MailDraft(to: [anna], subject: "Hi", body: "Plain words\nand a line.")
        let plain = try #require(MIMETree(MailCompose.raw(draft, from: me)))
        #expect(plain.type == "text/plain" && plain.text == "Plain words\r\nand a line.")
        // P1.11's seam: an HTML twin of plain words, and HTML last in it.
        let twin = try #require(MIMETree(MailCompose.raw(draft, from: me, extras: MailCompose.Extras(twin: true))))
        #expect(twin.type == "multipart/alternative")
        #expect(twin.parts.last?.text == "<div dir=\"auto\">Plain words<br>and a line.</div>")
        let pixel = "<img src=\"https://yetanotherbrowser.com/o/abc\" width=\"1\" height=\"1\" alt=\"\">"
        let tailed = try #require(MIMETree(MailCompose.raw(draft, from: me, extras: MailCompose.Extras(tail: pixel))))
        #expect(tailed.type == "multipart/alternative")
        #expect(tailed.parts.last?.text.hasSuffix("</div>" + pixel) == true)
        #expect(tailed.parts.first?.text.contains("img") == false)
    }

    @Test func aReplysQuoteGoesAsGmailQuotesIt() throws {
        let quote = "On Tue, Sep 29, 2026 at 10:00 AM, Anna Lindqvist <anna@fold.studio> wrote:\n> Shall we?\n>> Earlier\n>"
        var draft = MailDraft(thread: "t", to: [anna], subject: "Re: Hi", body: "Yes, the 12th.", quote: quote)
        draft.html = "<b>Yes</b>, the 12th."
        let html = MailCompose.html(draft)
        #expect(html == "<div dir=\"auto\"><b>Yes</b>, the 12th.</div><div><br></div><div class=\"gmail_quote\"><div dir=\"auto\" class=\"gmail_attr\">"
                + "On Tue, Sep 29, 2026 at 10:00 AM, Anna Lindqvist &lt;anna@fold.studio&gt; wrote:<br></div>"
                + "<blockquote class=\"gmail_quote\" style=\"\(MailCompose.quoteStyle)\">Shall we?<blockquote>Earlier</blockquote><br></blockquote></div>")
        // The plain part as ever.
        #expect(MailCompose.text(draft) == "Yes, the 12th.\n\n" + quote)
        // A forward: its head apart, its words under it.
        let forward = MailCompose.quoteHTML("---------- Forwarded message ---------\nFrom: Mark <mark@x.io>\nSubject: Deck\n\nSlides 4 to 9.\n> his quote", forward: true)
        #expect(forward == "<div class=\"gmail_quote\"><div dir=\"auto\" class=\"gmail_attr\">---------- Forwarded message ---------<br>"
                + "From: Mark &lt;mark@x.io&gt;<br>Subject: Deck<br></div><br>Slides 4 to 9.<blockquote>his quote</blockquote></div>")
    }

    @Test func aSignatureTheWordsHoldAlreadyIsntAddedAgain() {
        var draft = MailDraft(to: [anna], body: "Sounds good.\n\nSam Rivera\nFold Studio")
        draft.signed = true
        let signature = MailSignature(html: "<div>Sam Rivera</div><div>Fold Studio</div>")
        #expect(MailCompose.signing(draft, signature) == nil)
        draft.body = "Sounds good."
        #expect(MailCompose.signing(draft, signature) == signature)
        #expect(MailCompose.text(draft, signature: signature.text) == "Sounds good.\n\n-- \nSam Rivera\nFold Studio")
    }

    @MainActor @Test func quickQuoteIsAQuoteAndThePlainWordsSayItAsBefore() {
        var draft = MailDesk.Draft(id: "reply:t", thread: "t", account: "me@example.com", to: "", subject: "", body: "")
        let caret = MailDesk.quoteFirst(MailCompose.quickQuote("a time for the call"), into: &draft)
        #expect(draft.body == "> a time for the call\n\n")
        #expect(draft.html == "<blockquote>a time for the call</blockquote>")
        // Under the quote and its blank line, as the text view holds them ("a time for the call\n\n").
        #expect(caret == 21)
        var kept = MailDesk.Draft(id: "reply:t", thread: "t", account: "me@example.com", to: "", subject: "", body: "Bold words")
        kept.html = "<b>Bold</b> words"
        _ = MailDesk.quoteFirst(MailCompose.quickQuote("one\n> two"), into: &kept)
        #expect(kept.body == "> one\n>> two\n\nBold words")
        #expect(kept.html == "<blockquote>one<blockquote>two</blockquote></blockquote><br><b>Bold</b> words")
    }

    // MARK: - kept

    @Test func aFormattedDraftAndSignaturesOutliveTheStoreOpenedAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-rich-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let store = MailStore(file: file)
        var draft = MailDraft(id: "new:1", to: [anna], subject: "Plan", body: "- one\n- two")
        draft.html = "<ul><li>one</li><li><b>two</b></li></ul>"
        draft.from = "sam@fold.studio"
        draft.signed = true
        store.save(draft)
        store.keep(sendAs: MailSendAs.list(Self.sendAsJSON))
        store.setSignature("<i>Sam</i>", for: "Sam@Fold.Studio")
        let again = MailStore(file: file)
        let back = try #require(again.draft("new:1"))
        #expect(back.html == draft.html && back.from == draft.from && back.signed && back.body == draft.body)
        #expect(again.sendAs().map(\.address) == ["me@example.com", "sam@fold.studio"])
        #expect(again.signature(for: "sam@fold.studio") == "<i>Sam</i>")
        #expect(again.ownSignature(for: "me@example.com") == nil)
        again.setSignature(nil, for: "sam@fold.studio")
        #expect(again.signature(for: "sam@fold.studio").contains("Fold Studio"))
        #expect(again.value("aliases") == "sam@fold.studio")
    }

    @Test func migrationEighteenKeepsADraftOfBefore() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-rich-old-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        // A store of before (migrations up to 17), a draft in it.
        let old = MailStore(file: file, migrations: MailStore.migrations.filter { $0.0 <= 17 })
        old.save(MailDraft(id: "new:9", to: [anna], subject: "Old", body: "Words of before."))
        #expect(old.value("schema") == "17")
        let now = MailStore(file: file)
        #expect(now.value("schema") == String(MailStore.migrations.map(\.0).max() ?? 0))
        let kept = try #require(now.draft("new:9"))
        #expect(kept.body == "Words of before." && kept.html.isEmpty && kept.from.isEmpty && !kept.signed)
        #expect(now.sendAs().isEmpty)
    }

    // MARK: - the keys

    @MainActor @Test func theMarksKeysAreTheirsOnlyWhileWordsAreWritten() {
        let group = Shortcut.all.first { $0.title == "Mail Formatting" }?.items ?? []
        #expect(group.compactMap(\.action) == [.mailBold, .mailItalic, .mailUnderline, .mailBullets, .mailNumbers, .mailQuote])
        for item in group {
            guard let action = item.action, let key = item.key else { continue }
            #expect(Shortcut.context(action) == .mailWords)
            #expect(Keymap.valid(key, for: action), "\(action.rawValue)")
            #expect(!Keymap.valid(Hotkey(key.key, []), for: action), "\(action.rawValue) alone would type")
            #expect(Browser.command(forKey: action.rawValue) != nil)
        }
        let commandU = Hotkey("u", .command)
        #expect(Shortcut.byAction[.mailUnderline]?.key == commandU && Shortcut.byAction[.mailUnsubscribe]?.key == commandU)
        // ⌘U is Underline in the words and Unsubscribe anywhere else: no clash.
        #expect(!Keymap.conflicts(.mailUnsubscribe, commandU, .mailUnderline, commandU))
        // A mark given a key mail's own take while writing (⇧⌘B, Bcc): a clash.
        let shiftB = Hotkey("b", [.shift, .command])
        #expect(Keymap.conflicts(.mailBold, shiftB, .mailBcc, shiftB))
        // ⇧⌘F picks the From address while writing, never alone.
        #expect(Shortcut.byAction[.mailFrom]?.key == Hotkey("f", [.shift, .command]))
        #expect(Shortcut.context(.mailFrom) == .mail && !Keymap.valid(Hotkey("f", []), for: .mailFrom))
        // Every default in place at once.
        let bindings = Shortcut.items.enumerated().compactMap { order, item in
            item.action.flatMap { action in item.key.map { Keymap.Binding(action: action, key: $0, priority: 1, order: order) } }
        }
        let resolved = Keymap.resolve(bindings)
        for mark in MailRich.Mark.allCases { #expect(resolved[mark.action] == Shortcut.byAction[mark.action]?.key, "\(mark)") }
        #expect(resolved[.mailUnsubscribe] == commandU && resolved[.mailFrom] == Hotkey("f", [.shift, .command]))
    }

    // MARK: - the text view

    @MainActor static func words(_ body: String, _ html: String = "") -> MailWordsView {
        let view = MailWordsView.make()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        view.words = (body, html)
        return view
    }

    @MainActor @Test func wordsAreMarkedAndUnmarked() {
        let view = Self.words("Hello world")
        view.setSelectedRange(NSRange(location: 6, length: 5))
        view.apply(.bold)
        #expect(view.words.html == "Hello <b>world</b>" && view.words.body == "Hello world")
        view.apply(.italic)
        view.apply(.underline)
        #expect(view.words.html == "Hello <b><i><u>world</u></i></b>")
        // All of them bold already: off.
        view.apply(.bold)
        #expect(view.words.html == "Hello <i><u>world</u></i>")
        view.apply(.italic)
        view.apply(.underline)
        #expect(view.words.html.isEmpty && view.words.body == "Hello world")
        // Nothing chosen: what is typed next.
        view.setSelectedRange(NSRange(location: 11, length: 0))
        view.apply(.bold)
        view.insertText("!", replacementRange: view.selectedRange())
        #expect(view.words.html == "Hello world<b>!</b>")
    }

    @MainActor @Test func listsNestEndAndQuote() {
        let view = Self.words("one\ntwo")
        view.setSelectedRange(NSRange(location: 0, length: 7))
        view.apply(.bullets)
        #expect(view.words.html == "<ul><li>one</li><li>two</li></ul>" && view.words.body == "- one\n- two")
        // ⇥ on the second: nested in the first.
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertTab(nil)
        #expect(view.words.html == "<ul><li>one<ul><li>two</li></ul></li></ul>")
        // ⇧⌘7 there: numbered at its level.
        view.apply(.numbers)
        #expect(view.words.html == "<ul><li>one<ol><li>two</li></ol></li></ul>" && view.words.body == "- one\n  1. two")
        // ↩ at its end: a new item; ↩ on that empty item: out a level, into the outer list.
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertText("three", replacementRange: view.selectedRange())
        #expect(view.words.html == "<ul><li>one<ol><li>two</li></ol></li><li>three</li></ul>")
        // ⌫ at an item's start: out of the list, its words kept.
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.deleteBackward(nil)
        #expect(view.words.html == "<ul><li>one<ol><li>two</li></ol></li></ul>three" && view.string == "one\ntwo\nthree")
        // ⇧⌘9: quoted; again, not.
        view.setSelectedRange(NSRange(location: 8, length: 5))
        view.apply(.quote)
        #expect(view.words.html.hasSuffix("</ul><blockquote>three</blockquote>") && view.words.body.hasSuffix("\n> three"))
        view.apply(.quote)
        #expect(view.words.html.hasSuffix("</ul>three"))
        // ⇧⌘8 again on lines all bulleted: plain lines.
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.apply(.bullets)
        #expect(view.words.html == "one<ul><li><ol><li>two</li></ol></li></ul>three")
    }

    @MainActor @Test func anAddressPastedOverWordsLinksThemAndPastesKeepTheSet() {
        let view = Self.words("See the deck here")
        let board = NSPasteboard(name: NSPasteboard.Name("yab.test.words.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("https://fold.studio/deck", forType: .string)
        view.setSelectedRange(NSRange(location: 4, length: 8))
        #expect(view.readSelection(from: board, type: .string))
        #expect(view.words.html == "See <a href=\"https://fold.studio/deck\">the deck</a> here")
        #expect(view.words.body == "See the deck <https://fold.studio/deck> here")
        // Words from another app: their bold kept, their color and size not.
        board.clearContents()
        board.setString("<p style=\"color:red;font-size:30px\"><span style=\"font-weight:bold\">Big</span> news</p>", forType: .html)
        board.setString("Big news", forType: .string)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        #expect(view.readSelection(from: board, type: .html))
        #expect(view.words.html == "See <a href=\"https://fold.studio/deck\">the deck</a> here<b>Big</b> news")
        // Copied from here, the HTML goes with them.
        view.setSelectedRange(NSRange(location: 4, length: 8))
        board.clearContents()
        // As Copy writes it: the view's own types, the HTML with them.
        #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        #expect(board.string(forType: .html) == "<a href=\"https://fold.studio/deck\">the deck</a>")
    }

    // MARK: - a key in a long mail

    /// The writer's say for a character, one at a time, as it was before
    /// it wrote whole stretches: what the stretches must still say.
    static func escapedOneByOne(_ runs: [Run]) -> String {
        var out = ""
        var previous: Character?
        for (n, run) in runs.enumerated() {
            let count = run.text.count
            for (i, char) in run.text.enumerated() {
                let last = n == runs.count - 1 && i == count - 1
                switch char {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case " ": out += previous == nil || previous == " " || last ? "&nbsp;" : " "
                case "\t": out += "&#9;"
                case "\u{A0}": out += "&#160;"
                case "\n", "\r", "\u{2028}", "\u{2029}": out += " "
                default: out += String(char)
                }
                previous = char
            }
        }
        return out
    }

    @Test func theWriterSaysEveryCharacterAsItDidOneByOne() {
        var seed: UInt64 = 7
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let pieces = ["a", "B", " ", "  ", "&", "<", ">", "\t", "\u{A0}", "\r\n", "\r", "\u{2028}", " \u{301}", "é", "日", "👋🏽", "{{", "x y"]
        for _ in 0..<400 {
            let runs = (0..<(1 + next(3))).map { _ in Run(text: (0..<(1 + next(8))).map { _ in pieces[next(pieces.count)] }.joined()) }
            // Unmarked runs are one run to the writer, as to a line.
            let line = Line([], [Run(text: runs.map(\.text).joined())])
            #expect(MailRich.html([line]) == Self.escapedOneByOne(line.runs), "\(line.runs)")
            // Marked apart: the tags between, the characters the same.
            let marked = Line([], runs.enumerated().map { n, run in Run(text: run.text, bold: n % 2 == 1) })
            let tags = try? NSRegularExpression(pattern: "</?b>")
            let html = MailRich.html([marked])
            let bare = tags?.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "") ?? html
            #expect(bare == Self.escapedOneByOne(marked.runs), "\(marked.runs)")
        }
    }

    /// Words with every mark a draft holds, a few hundred lines of them.
    @MainActor static func longWords() -> MailWordsView {
        var html = ""
        for n in 0..<40 {
            html += "<p>Para \(n) with <b>bold</b>, <i>slanted</i> and <a href=\"https://fold.studio/\(n)\">a link</a> in it.</p>"
            if n % 7 == 3 { html += "<ul><li>one</li><li>two<ol><li>deep</li></ol></li></ul>" }
            if n % 11 == 5 { html += "<blockquote>quoted <u>words</u></blockquote>" }
        }
        return words("", html)
    }

    @MainActor @Test func theLinesKeptAtEachEditAreTheLinesReadWhole() {
        let view = Self.longWords()
        guard let storage = view.textStorage else { Issue.record("no storage"); return }
        #expect(view.lines() == MailRich.doc(storage))
        var seed: UInt64 = 11
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(1, bound)))
        }
        let typed = ["x", " ", "word", "\n", "\r", "\r\n", "\u{2028}", "\n\n", "é", "ok\nthen"]
        let bold = MailRich.font(MailRich.words.font, bold: true, italic: false)
        for step in 0..<600 {
            let length = storage.length
            let at = next(length + 1)
            let span = min(next(12), length - at)
            switch next(7) {
            case 0, 1:
                // Typed or pasted where the caret is, over what is chosen.
                storage.replaceCharacters(in: NSRange(location: at, length: span), with: typed[next(typed.count)])
            case 2:
                storage.deleteCharacters(in: NSRange(location: at, length: span))
            case 3:
                if span > 0 { storage.addAttribute(.font, value: bold, range: NSRange(location: at, length: span)) }
            case 4:
                if span > 0 { storage.addAttribute(MailRich.blocksKey, value: ["ul", "q", "q.ol", "ol.ul"][next(4)], range: NSRange(location: at, length: span)) }
            case 5:
                if span > 0 { storage.removeAttribute(MailRich.blocksKey, range: NSRange(location: at, length: span)) }
            default:
                // Several edits in one, as a mark on many lines makes them.
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: at, length: span), with: "a\nb")
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: min(3, storage.length)))
                storage.endEditing()
            }
            #expect(view.lines() == MailRich.doc(storage), "step \(step)")
            if view.lines() != MailRich.doc(storage) { break }
            // And the words written from them, each line's HTML kept: as written whole.
            if step % 5 == 0 {
                let doc = MailRich.doc(storage)
                let whole = MailRich.formatted(doc) ? (MailRich.text(doc), MailRich.html(MailRich.trimmed(doc))) : (storage.string, "")
                #expect(view.words == whole, "step \(step)")
            }
        }
        // Set anew, as Claude's words or a draft opened again are: read whole.
        view.words = ("Fresh words\nand a line", "")
        #expect(view.lines() == MailRich.doc(storage) && view.words.body == "Fresh words\nand a line")
    }

    @MainActor @Test func aKeyInALongMailReadsOnlyItsLine() {
        let view = Self.longWords()
        let whole = view.lines().count
        let read = view.linesRead
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end / 2, length: 0))
        let keys = "typing a sentence in the middle of a long mail "
        for letter in keys {
            view.insertText(String(letter), replacementRange: view.selectedRange())
            _ = view.words
        }
        // Its line and one on each side a key, never the mail's lines again.
        #expect(whole > 60 && view.linesRead - read <= keys.count * 3, "\(view.linesRead - read) lines read for \(keys.count) keys")
        #expect(view.words.body == MailRich.text(MailRich.doc(view.textStorage ?? NSAttributedString())))
    }

    @Test func aKeyIsHeardByMailsViewsOnlyWhenWhatTheyShowChanges() {
        let given = MailDesk.Draft(id: "reply:t1", thread: "t1", account: "me@example.com", to: "anna@fold.studio", subject: "Re: Plan", body: "")
        var typed = given
        typed.body = "H"
        // The first key: no longer empty, and no longer as given.
        #expect(MailDesk.heard(given, typed, given: given))
        var more = typed
        more.body = "Hi"
        // Words that stay words: nothing shown changes.
        #expect(!MailDesk.heard(typed, more, given: given))
        #expect(!MailDesk.heard(typed, more, given: nil))
        // Back to as given, or empty again: heard.
        #expect(MailDesk.heard(typed, given, given: given))
        var empty = more
        empty.body = ""
        #expect(MailDesk.heard(more, empty, given: nil))
        // A snippet's place left to fill: the line over Send follows every key.
        var hole = more
        hole.body = "Hi {{name"
        var filled = hole
        filled.body = "Hi {{name}}"
        #expect(MailDesk.heard(hole, filled, given: nil))
    }

    @MainActor @Test func aDraftsWordsComeBackAsTheyWereWritten() {
        let html = "Hi <b>Anna</b>,<br><br><ul><li>one<ul><li><i>two</i></li></ul></li></ul><blockquote>quoted</blockquote>end"
        let view = Self.words("ignored when there is HTML", html)
        #expect(view.words.html == html)
        #expect(view.string == "Hi Anna,\n\none\ntwo\nquoted\nend")
        #expect(view.words.body == "Hi Anna,\n\n- one\n  - two\n> quoted\nend")
        // Plain words stay plain, as typed.
        let plain = Self.words("Plain\n\nwords  with spaces ")
        #expect(plain.words == ("Plain\n\nwords  with spaces ", ""))
    }
}

/// A message as Gmail's `format=full` gives it back, its parts as Gmail
/// nests them, for the reading half to read (MailGmail.message).
enum FakeMime {
    static func payload(_ raw: String, id: String) -> [String: Any] {
        let tree = MIMETree(raw)
        func part(_ node: MIMETree) -> [String: Any] {
            let headers = node.head.map { ["name": $0.key.capitalized, "value": $0.value] }
            if node.type.hasPrefix("multipart/") {
                return ["mimeType": node.type, "filename": "", "headers": headers, "body": ["size": 0], "parts": node.parts.map(part)]
            }
            let disposition = MailMime.parameters(node.head["content-disposition"] ?? "")
            let name = disposition.params["filename"] ?? ""
            return ["mimeType": node.type, "filename": name, "headers": headers,
                    "body": ["size": node.data.count, "data": FakeGmail.base64url(node.data)] as [String: Any]]
        }
        var payload = tree.map(part) ?? [:]
        payload["headers"] = (tree?.head ?? [:]).map { ["name": $0.key.capitalized, "value": $0.value] }
        return ["id": id, "threadId": id, "labelIds": ["SENT"], "snippet": "", "internalDate": "0", "payload": payload]
    }
}

/// Send-as through the engine, against a Gmail kept in memory: kept at the
/// first sync with meta `aliases`, not asked again within the day, asked
/// again after Connect, and a Gmail that refuses asked again ten minutes
/// on, the sync going on regardless. With MailSyncTests, one at a time.
extension MailSyncAppTests {
    @Test func sendAsComesOnceADayAndAfterConnect() async throws {
        let (store, gmail, fake) = world()
        defer { MailAttachSendTests.clean(store.file) }
        seed(fake)
        fake.sendAs = MailRichTests.sendAsJSON["sendAs"] as? [[String: Any]]
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        #expect(store.sendAs().map(\.address) == ["me@example.com", "sam@fold.studio"])
        #expect(store.aliases == ["sam@fold.studio"])
        #expect(fake.calls.filter { $0 == "GET settings/sendAs" }.count == 1)
        // Within the day: nothing asked.
        try await sync.sync()
        #expect(fake.calls.filter { $0 == "GET settings/sendAs" }.count == 1)
        // Connected again (MailCenter.add forgets when they came): asked anew, the alias gone in Gmail gone here.
        fake.sendAs = Array((fake.sendAs ?? []).dropFirst())
        fake.sendAs?[0]["isDefault"] = true
        store.set("sendas.at", nil)
        try await sync.sync()
        #expect(store.sendAs().map(\.address) == ["me@example.com"])
        #expect(store.aliases.isEmpty)
        // A Gmail that refuses: the sync goes on, the list kept, asked again ten minutes on.
        fake.sendAs = nil
        store.set("sendas.at", nil)
        let now = Date()
        await sync.keepSendAs(now: now)
        #expect(store.sendAs().map(\.address) == ["me@example.com"])
        let refused = fake.calls.filter { $0 == "GET settings/sendAs" }.count
        await sync.keepSendAs(now: now.addingTimeInterval(300))
        #expect(fake.calls.filter { $0 == "GET settings/sendAs" }.count == refused)
        await sync.keepSendAs(now: now.addingTimeInterval(700))
        #expect(fake.calls.filter { $0 == "GET settings/sendAs" }.count == refused + 1)
        #expect(MailGmail.cost("settings/sendAs", method: "GET") == 1)
    }

    @Test func aReplyToMailSentToAnAliasGoesFromTheAlias() async throws {
        let (store, gmail, fake) = world()
        defer { MailAttachSendTests.clean(store.file) }
        seed(fake)
        fake.sendAs = MailRichTests.sendAsJSON["sendAs"] as? [[String: Any]]
        fake.add(.init(id: "f1", thread: "tf", from: "Lena Hoffmann <lena@hoffmann.design>", to: "Sam Rivera <sam@fold.studio>",
                       subject: "Footage", body: "Could you send the raw cut?", at: now.addingTimeInterval(-600), labels: ["INBOX", "UNREAD"]))
        try await MailSync(store: store, gmail: gmail).sync()
        let thread = store.messages(thread: "tf")
        var reply = try #require(MailCompose.reply(to: thread, me: store.me, aliases: store.aliases))
        reply.id = "reply:tf"
        reply.from = MailSendAs.address(answering: thread.last, store.sendAs(), me: store.me)
        reply.signed = true
        reply.body = "Sending it tonight."
        reply.html = "Sending it <b>tonight</b>."
        reply.messageID = MailCompose.messageID(from: store.me)
        #expect(reply.from == "sam@fold.studio")
        store.save(reply)
        MailOps.act(.send, thread: reply.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        let raw = try #require(fake.sent.last)
        let tree = try #require(MIMETree(raw))
        #expect(tree.head["from"] == "\"Sam Rivera\" <sam@fold.studio>")
        #expect(tree.head["reply-to"] == "replies@fold.studio")
        #expect(tree.type == "multipart/alternative")
        #expect(tree.parts[0].text.hasPrefix("Sending it tonight.\r\n\r\n-- \r\nSam Rivera\r\nFold Studio"))
        #expect(!tree.parts[0].text.contains("<b>"))
        #expect(tree.parts[1].text.contains("Sending it <b>tonight</b>."))
        #expect(fake.messages["s1"]?.thread == "tf")
    }
}
