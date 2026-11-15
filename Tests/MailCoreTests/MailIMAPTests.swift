import Foundation
import Testing
@testable import MailCore

// IMAP's pieces held to fixed inputs (docs/mail-providers.md, M3): the
// response reader, folder names, UID sets, a raw message read as Gmail's
// resource, SMTP's DATA, autoconfig, the known providers and the finding chain.

@Suite struct MailIMAPTests {
    // MARK: - responses

    @Test func aFetchWithALiteralReadsWhole() {
        let header = "Subject: Hi\r\nMessage-ID: <a@b>\r\n\r\n"
        let line = "* 3 FETCH (UID 17 FLAGS (\\Seen \\Flagged) INTERNALDATE \"17-Jul-2026 02:44:25 -0700\" BODY[HEADER] {\(header.utf8.count)}\r\n\(header) MODSEQ (12))"
        let response = IMAPRead.parse(Data(line.utf8))
        #expect(response.numbered?.0 == 3)
        let fetch = IMAPRead.fetch(response)
        #expect(fetch?["UID"]?.number == 17)
        #expect(fetch?["FLAGS"]?.items.compactMap(\.text) == ["\\Seen", "\\Flagged"])
        #expect(fetch?["BODY[HEADER]"]?.text == header)
        #expect(fetch?["MODSEQ"]?.items.first?.number == 12)
        #expect(MailIMAPAccount.internalDate(fetch?["INTERNALDATE"]?.text) != nil)
    }

    @Test func aStatusResponseKeepsItsCode() {
        let r = IMAPRead.parse(Data("* OK [UIDVALIDITY 3857529045] UIDs valid".utf8))
        #expect(r.status == "OK" && r.code == "UIDVALIDITY 3857529045" && r.text == "UIDs valid")
        let done = IMAPRead.parse(Data("Y4 NO [AUTHENTICATIONFAILED] Invalid credentials".utf8))
        #expect(done.tag == "Y4" && done.status == "NO" && done.code == "AUTHENTICATIONFAILED")
        let go = IMAPRead.parse(Data("+ idling".utf8))
        #expect(go.tag == "+")
    }

    @Test func listGivesAttributesAndNames() {
        let r = IMAPRead.parse(Data("* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Messages\"".utf8))
        #expect(r.word == "LIST")
        #expect(r.values[1].items.compactMap(\.text) == ["\\HasNoChildren", "\\Sent"])
        #expect(r.values[2].text == "/" && r.values[3].text == "Sent Messages")
        let folder = IMAPFolder(name: "Sent Messages", delimiter: "/", attributes: ["\\hasnochildren", "\\sent"])
        #expect(MailIMAPAccount.role(folder) == "sent")
        #expect(MailIMAPAccount.label(of: folder) == .some("SENT"))
    }

    @Test func foldersWithoutSpecialUseGoByTheirNames() {
        func role(_ name: String) -> String? { MailIMAPAccount.role(IMAPFolder(name: name, delimiter: "/", attributes: [])) }
        #expect(role("INBOX") == "inbox")
        #expect(role("Deleted Messages") == "trash")
        #expect(role("Junk") == "junk" && role("Spam") == "junk")
        #expect(role("INBOX/Sent") == "sent")
        #expect(role("Projects/Sent") == nil)
        #expect(role("Receipts") == nil)
        let mine = IMAPFolder(name: "Projects/Yab", delimiter: "/", attributes: [])
        #expect(MailIMAPAccount.label(of: mine) == .some("Label_f:Projects/Yab"))
        let archive = IMAPFolder(name: "Archive", delimiter: "/", attributes: [])
        #expect(MailIMAPAccount.label(of: archive) == .some(nil))
        let drafts = IMAPFolder(name: "Drafts", delimiter: "/", attributes: ["\\drafts"])
        #expect(MailIMAPAccount.label(of: drafts) == nil)
    }

    @Test func folderNamesInModifiedUTF7() {
        #expect(IMAPName.encode("Entwürfe") == "Entw&APw-rfe")
        #expect(IMAPName.decode("Entw&APw-rfe") == "Entwürfe")
        #expect(IMAPName.encode("Tom & Jerry") == "Tom &- Jerry")
        #expect(IMAPName.decode("Tom &- Jerry") == "Tom & Jerry")
        for name in ["Envoyés", "日本語", "Inbox/Büro", "a&b/c"] {
            #expect(IMAPName.decode(IMAPName.encode(name)) == name)
        }
    }

    @Test func uidSets() {
        #expect(IMAPSet.string([5, 1, 2, 3, 9, 10, 7]) == "1:3,5,7,9:10")
        #expect(IMAPSet.uids("1:3,5,9:10") == [1, 2, 3, 5, 9, 10])
        #expect(IMAPSet.chunks(Array(1...450), size: 200).map(\.count) == [200, 200, 50])
    }

    @Test func aLiteralAtALinesEnd() {
        #expect(IMAPClient.literal(at: Data("* 1 FETCH (BODY[] {42}".utf8)) == 42)
        #expect(IMAPClient.literal(at: Data("A1 APPEND x {10+}".utf8)) == 10)
        #expect(IMAPClient.literal(at: Data("* OK done".utf8)) == nil)
        #expect(IMAPClient.literal(at: Data("* 1 FETCH (BODY[] {-1}".utf8)) == nil)
    }

    /// Crash #110: a "{" with no "}" after it, a literal longer than the
    /// bytes that came, or one below zero read what is there, not a trap.
    @Test func aBrokenLiteralReadsWhatIsThere() {
        _ = IMAPRead.parse(Data("* 1 FETCH (BODY[] {".utf8))
        _ = IMAPRead.parse(Data("* 1 FETCH (BODY[] {12".utf8))
        _ = IMAPRead.parse(Data("* LIST () \"/\" {5}\r\n".utf8))
        let short = IMAPRead.parse(Data("* 1 FETCH (BODY[] {40}\r\nhello)".utf8))
        #expect(IMAPRead.fetch(short)?["BODY[]"]?.data == Data("hello)".utf8))
        let negative = IMAPRead.parse(Data("* 1 FETCH (UID 7 BODY[] {-3}\r\nabc)".utf8))
        #expect(IMAPRead.fetch(negative)?["UID"]?.text == "7")
        let huge = IMAPRead.parse(Data("* 1 FETCH (BODY[] {9223372036854775807}\r\nab)".utf8))
        #expect(IMAPRead.fetch(huge)?["BODY[]"]?.data == Data("ab)".utf8))
    }

    // MARK: - messages

    static let multipart = """
    From: =?UTF-8?B?Wm/Dqw==?= <anna@example.org>\r
    To: Me <me@example.com>\r
    Cc: Tim <tim@okafor.co>\r
    Subject: =?UTF-8?Q?Caf=C3=A9_plans?=\r
    Date: Tue, 14 Oct 2026 09:30:00 +0200\r
    Message-ID: <cafe@example.org>\r
    In-Reply-To: <root@example.org>\r
    References: <root@example.org>\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="b1"\r
    \r
    --b1\r
    Content-Type: multipart/alternative; boundary="b2"\r
    \r
    --b2\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    Let's meet at the caf=C3=A9 =\r
    on Friday.\r
    --b2\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <p>Let's meet at the café on Friday.</p>\r
    --b2--\r
    --b1\r
    Content-Type: application/pdf; name="menu.pdf"\r
    Content-Disposition: attachment; filename="menu.pdf"\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERi0xLjQgZmFrZQ==\r
    --b1--\r

    """

    @Test func aRawMessageReadsAsGmailsResourceDoes() throws {
        let raw = Data(Self.multipart.utf8)
        let message = try #require(MailRFC822.message(raw, id: "i1", thread: "t1", labels: ["INBOX", "UNREAD"], date: nil, full: true))
        #expect(message.subject == "Café plans")
        #expect(message.from.name == "Zoë" && message.from.address == "anna@example.org")
        #expect(message.cc.map(\.address) == ["tim@okafor.co"])
        #expect(message.text == "Let's meet at the café on Friday.")
        #expect(message.html?.contains("<p>") == true)
        #expect(message.rfcID == "<cafe@example.org>" && message.inReplyTo == "<root@example.org>")
        #expect(message.labels == ["INBOX", "UNREAD"])
        let file = try #require(message.files?.first)
        #expect(file.name == "menu.pdf" && file.mime == "application/pdf" && file.attachmentID == "p:1")
        #expect(message.attached == true)
        #expect(MailRFC822.part(raw, id: file.attachmentID) == Data("%PDF-1.4 fake".utf8))
        #expect(abs(message.date.timeIntervalSince1970 - 1_791_963_000) < 1)
        let head = try #require(MailRFC822.message(raw, id: "i1", thread: "t1", labels: [], date: nil, full: false))
        #expect(head.text == nil && head.subject == "Café plans")
    }

    @Test func aPlainMessageInLatin1() throws {
        var raw = Data("From: a@b.c\r\nSubject: Hi\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n".utf8)
        raw.append(Data([0x63, 0x61, 0x66, 0xE9]))
        let message = try #require(MailRFC822.message(raw, id: "x", thread: "x", labels: [], date: Date(timeIntervalSince1970: 5), full: true))
        #expect(message.text == "café")
        #expect(message.snippet == "café")
        #expect(message.date == Date(timeIntervalSince1970: 5))
    }

    @Test func bccStaysOutOfData() {
        let raw = Data("From: me@example.com\r\nTo: Ann <ann@example.org>\r\nBcc: boss@example.com,\r\n secret@example.com\r\nSubject: Hi\r\n\r\n.hidden dot\r\nbye\r\n".utf8)
        #expect(MailRFC822.recipients(raw) == ["ann@example.org", "boss@example.com", "secret@example.com"])
        let out = String(decoding: MailRFC822.withoutBcc(raw), as: UTF8.self)
        #expect(!out.contains("boss@") && !out.contains("secret@") && out.contains("To: Ann <ann@example.org>\r\nSubject: Hi\r\n\r\n.hidden"))
        let stuffed = String(decoding: MailSMTP.stuffed(MailRFC822.withoutBcc(raw)), as: UTF8.self)
        #expect(stuffed.contains("\r\n..hidden dot\r\n") && stuffed.hasSuffix("bye\r\n.\r\n"))
    }

    @Test func idsAndThreads() {
        #expect(MailRFC822.ids("<a@b> <c@d>\r\n <e@f>") == ["<a@b>", "<c@d>", "<e@f>"])
        let one = MailIMAPAccount.id(rfc: "<A@B>", folder: "INBOX", validity: 1, uid: 4)
        #expect(one == MailIMAPAccount.id(rfc: "<a@b>", folder: "Archive", validity: 9, uid: 77))
        #expect(MailIMAPAccount.id(rfc: "", folder: "INBOX", validity: 1, uid: 4) != MailIMAPAccount.id(rfc: "", folder: "INBOX", validity: 1, uid: 5))
    }

    // MARK: - finding servers

    @Test func knownProviders() throws {
        let icloud = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let setup = icloud.setup(for: "emily.parker@icloud.com")
        #expect(setup.imapHost == "imap.mail.me.com" && setup.imapPort == 993 && setup.imapSecurity == .tls)
        #expect(setup.imapUser == "emily.parker" && setup.smtpUser == "emily.parker@icloud.com")
        #expect(setup.smtpHost == "smtp.mail.me.com" && setup.smtpPort == 587 && setup.smtpSecurity == .starttls)
        #expect(MailKnownProviders.by(domain: "me.com")?.id == "icloud")
        #expect(MailKnownProviders.by(domain: "zoho.com")?.imap.host == "imap.zoho.com")
        #expect(MailKnownProviders.by(domain: "zoho.eu")?.smtp.host == "smtp.zoho.eu")
        #expect(MailKnownProviders.by(domain: "zohomail.in")?.imap.host == "imap.zoho.in")
        // A company's own domain on Zoho EU signs in at imappro.
        #expect(MailKnownProviders.by(mx: "mx.zoho.eu.")?.imap.host == "imappro.zoho.eu")
        #expect(MailKnownProviders.by(mx: "mx2.zoho.com")?.smtp.host == "smtppro.zoho.com")
        #expect(MailKnownProviders.by(mx: "aspmx.l.google.com")?.route == .imap)
        #expect(MailKnownProviders.by(mx: "example-com.mail.protection.outlook.com")?.route == .microsoft)
        #expect(MailKnownProviders.by(domain: "yahoo.co.uk")?.imap.host == "imap.mail.yahoo.com")
        #expect(MailKnownProviders.by(domain: "fastmail.com")?.smtp.port == 465)
    }

    static let autoconfig = """
    <?xml version="1.0"?>
    <clientConfig version="1.1">
      <emailProvider id="hostingco.net">
        <domain>example.net</domain>
        <incomingServer type="pop3"><hostname>pop.hostingco.net</hostname><port>995</port><socketType>SSL</socketType></incomingServer>
        <incomingServer type="imap">
          <hostname>imap.hostingco.net</hostname><port>143</port><socketType>STARTTLS</socketType><username>%EMAILLOCALPART%</username>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>smtp.%EMAILDOMAIN%</hostname><port>465</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    @Test func autoconfigReadsTheFirstIMAPAndSMTP() throws {
        let setup = try #require(MailAutoconfig.read(Data(Self.autoconfig.utf8), address: "ann@example.net"))
        #expect(setup.imapHost == "imap.hostingco.net" && setup.imapPort == 143 && setup.imapSecurity == .starttls && setup.imapUser == "ann")
        #expect(setup.smtpHost == "smtp.example.net" && setup.smtpPort == 465 && setup.smtpSecurity == .tls && setup.smtpUser == "ann@example.net")
        #expect(setup.provider == "hostingco.net" && setup.foundBy == "autoconfig")
    }

    @Test func theChainStopsAtTheFirstAnswer() async {
        let none: @Sendable (URL) async -> Data? = { _ in nil }
        let noMX: @Sendable (String) async -> [String] = { _ in [] }
        let noSRV: @Sendable (String) async -> [(host: String, port: Int)] = { _ in [] }
        // Known: no web, no DNS.
        if case .imap(let setup, let known) = await MailFinding.find("Casey@Zoho.com", fetch: none, mx: noMX, srv: noSRV) {
            #expect(setup.imapHost == "imap.zoho.com" && setup.address == "casey@zoho.com" && known?.id == "zoho")
        } else { Issue.record("zoho not known") }
        #expect(await MailFinding.find("a@gmail.com", fetch: none, mx: noMX, srv: noSRV) == .imap(MailKnownProviders.by(id: "gmail")!.setup(for: "a@gmail.com"), MailKnownProviders.by(id: "gmail")))
        #expect(await MailFinding.find("a@hotmail.com", fetch: none, mx: noMX, srv: noSRV) == .microsoft)
        // The domain's own autoconfig.
        let xml = Data(Self.autoconfig.utf8)
        let hosted: @Sendable (URL) async -> Data? = { url in url.host == "autoconfig.example.net" ? xml : nil }
        if case .imap(let setup, _) = await MailFinding.find("ann@example.net", fetch: hosted, mx: noMX, srv: noSRV) {
            #expect(setup.imapHost == "imap.hostingco.net" && setup.foundBy == "autoconfig")
        } else { Issue.record("autoconfig missed") }
        // A company domain whose MX is Zoho's, and one on Google Workspace.
        let zohoMX: @Sendable (String) async -> [String] = { _ in ["mx.zoho.in"] }
        if case .imap(let setup, _) = await MailFinding.find("raj@company.in", fetch: none, mx: zohoMX, srv: noSRV) {
            #expect(setup.imapHost == "imappro.zoho.in" && setup.foundBy == "mx")
        } else { Issue.record("zoho mx missed") }
        let googleMX: @Sendable (String) async -> [String] = { _ in ["aspmx.l.google.com"] }
        if case .imap(let setup, let provider) = await MailFinding.find("a@startup.io", fetch: none, mx: googleMX, srv: noSRV) {
            #expect(setup.imapHost == "imap.gmail.com" && provider?.id == "gmail")
        } else { Issue.record("Google Workspace did not use IMAP") }
        // SRV, then a guess.
        let srv: @Sendable (String) async -> [(host: String, port: Int)] = { name in name.hasPrefix("_imaps") ? [("mail.small.org", 993)] : [] }
        if case .imap(let setup, _) = await MailFinding.find("x@small.org", fetch: none, mx: noMX, srv: srv) {
            #expect(setup.imapHost == "mail.small.org" && setup.foundBy == "srv")
        } else { Issue.record("srv missed") }
        if case .imap(let setup, _) = await MailFinding.find("x@nowhere.example", fetch: none, mx: noMX, srv: noSRV) {
            #expect(setup.imapHost == "imap.nowhere.example" && setup.foundBy == "guess")
        } else { Issue.record("no guess") }
        #expect(await MailFinding.find("not an address", fetch: none, mx: noMX, srv: noSRV) == .none)
    }

    @Test func refusalsReadForWhatTheyMean() {
        #expect(MailServerTrouble.login("[AUTHENTICATIONFAILED] Application-specific password required").hint == "appPasswordRequired")
        #expect(MailServerTrouble.login("Your account is not enabled for IMAP use").hint == "imapDisabled")
        #expect(MailServerTrouble.login("[AUTHENTICATIONFAILED] Invalid credentials").hint == "authRejected")
        #expect(MailServerTrouble.from(URLError(.cannotFindHost), step: "x") == .dnsNotFound)
        #expect(MailServerTrouble.from(URLError(.cannotConnectToHost), step: "x") == .tcpRefused)
        #expect(MailServerTrouble.from(URLError(.serverCertificateUntrusted), step: "x").hint == "tlsFailed")
        #expect(MailServerTrouble.from(URLError(.timedOut), step: "read") == .timedOut("read"))
    }

    @Test func searchWordsAsIMAPSaysThem() throws {
        let words = IMAPSearch(me: "me@example.com")
        func said(_ text: String) -> IMAPSearch.Asked? { MailQuery.parse(text).root.flatMap(words.read) }
        func line(_ text: String) -> String? { said(text).map { IMAPSearch.line($0.pieces) } }
        #expect(line("from:anna invoice") == "FROM \"anna\" TEXT \"invoice\"")
        #expect(line("subject:offsite is:unread") == "SUBJECT \"offsite\" UNSEEN")
        #expect(line("from:me is:starred") == "FROM \"me@example.com\" FLAGGED")
        #expect(line("lunch OR dinner") == "OR (TEXT \"lunch\") (TEXT \"dinner\")")
        #expect(line("-from:linear") == "NOT (FROM \"linear\")")
        #expect(line("after:2026/01/05")?.hasPrefix("SINCE 5-Jan-2026") == true)
        // Folders it names are where it looks.
        let inbox = try #require(said("in:inbox contract"))
        #expect(inbox.folders == ["inbox"] && IMAPSearch.line(inbox.pieces) == "TEXT \"contract\"")
        #expect(said("label:Receipts")?.folders == ["label_f:receipts"])
        #expect(said("in:trash")?.anywhere == true)
        // What SEARCH can't say leaves the store to answer alone.
        #expect(said("has:attachment report") == nil)
        #expect(said("category:promotions") == nil)
        #expect(said("label:Work label:Travel") == nil)
        // Not 7-bit: a literal, after CHARSET UTF-8.
        #expect(said("Grüße").map { $0.pieces.contains { if case .quoted(let s) = $0 { return !IMAPClient.quotable(s) } else { return false } } } == true)
    }

    @Test func setupsKeepNoSecret() throws {
        let setup = MailKnownProviders.by(domain: "icloud.com")!.setup(for: "a@icloud.com")
        let defaults = try #require(UserDefaults(suiteName: "imap-test-\(UUID().uuidString)"))
        setup.saved(in: defaults)
        #expect(MailServerSetup.kept("A@iCloud.com", in: defaults) == setup)
        #expect(!(defaults.string(forKey: MailServerSetup.key("a@icloud.com")) ?? "").lowercased().contains("password"))
    }
}
