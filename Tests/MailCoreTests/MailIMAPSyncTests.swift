import Foundation
import Testing
@testable import MailCore

// An IMAP account end to end against evals/mail/fake_imap.py, started for
// each test on ports of its own (docs/mail-providers.md, M3): the first
// sync, archive, trash, star and read going out, ⌘Z before they do, new
// mail, flags and expunges from the server, a send by SMTP into Sent, and
// mail_probe's steps. With CONDSTORE, MOVE and UIDPLUS on and off.

/// The fake running, its ports, its state over HTTP.
final class FakeIMAPServer: @unchecked Sendable {
    let process = Process()
    let imap: Int, smtp: Int, http: Int

    init(_ flags: [String] = []) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("evals/mail/fake_imap.py").path] + flags
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        let until = Date().addingTimeInterval(15)
        while !line.contains(10), Date() < until {
            let got = out.fileHandleForReading.availableData
            if got.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { line.append(got) }
        }
        let ports = (try? JSONSerialization.jsonObject(with: line) as? [String: Int]) ?? [:]
        guard let imap = ports["imap"], let smtp = ports["smtp"], let http = ports["http"] else {
            process.terminate()
            throw MailServerTrouble.unreadable("fake_imap.py didn't start")
        }
        (self.imap, self.smtp, self.http) = (imap, smtp, http)
        // Listening before it is used: a connect that goes through.
        let ready = Date().addingTimeInterval(5)
        while Date() < ready, !Self.listens(imap) { Thread.sleep(forTimeInterval: 0.05) }
    }

    static func listens(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    deinit { process.terminate() }

    func state() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(http)/fake/state")!)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(http)/fake/\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func subjects(_ folder: String) async throws -> [String] {
        let folders = try await state()["folders"] as? [String: [[String: Any]]] ?? [:]
        return (folders[folder] ?? []).compactMap { $0["subject"] as? String }
    }

    func flags(_ folder: String, subject: String) async throws -> [String] {
        let folders = try await state()["folders"] as? [String: [[String: Any]]] ?? [:]
        return (folders[folder] ?? []).first { $0["subject"] as? String == subject }?["flags"] as? [String] ?? []
    }

    func uid(_ folder: String, subject: String) async throws -> Int? {
        let folders = try await state()["folders"] as? [String: [[String: Any]]] ?? [:]
        return (folders[folder] ?? []).first { $0["subject"] as? String == subject }?["uid"] as? Int
    }

    var setup: MailServerSetup {
        MailServerSetup(address: "me@example.com", name: "Me", imapHost: "127.0.0.1", imapPort: imap, imapSecurity: .none,
                        smtpHost: "127.0.0.1", smtpPort: smtp, smtpSecurity: .none, provider: "fake")
    }

    func calls(_ verb: String) async throws -> Int {
        (try await state()["calls"] as? [String: Int])?[verb] ?? 0
    }

    func logins() async throws -> [String] {
        try await state()["logins"] as? [String] ?? []
    }
}

/// A known provider's own setup, as Add Account finds it, its hosts answered
/// by a fake through the test world's stand-ins (MailStandIn).
struct StandIns {
    let hosts: [String]

    init(_ provider: MailKnownProvider, fake: FakeIMAPServer) {
        hosts = [provider.imap.host, provider.smtp.host]
        let map = [provider.imap.host: fake.imap, provider.smtp.host: fake.smtp]
        Store.settings.set(String(decoding: try! JSONSerialization.data(withJSONObject: map), as: UTF8.self), forKey: MailStandIn.key)
    }

    func end() { Store.settings.removeObject(forKey: MailStandIn.key) }
}

@Suite(.serialized) struct MailIMAPSyncTests {
    func world(_ flags: [String] = []) throws -> (FakeIMAPServer, MailStore, MailIMAPAccount) {
        let fake = try FakeIMAPServer(flags)
        let store = MailStore(file: MailStore.memory)
        let account = MailIMAPAccount(setup: fake.setup, store: store, password: { "app-password" })
        return (fake, store, account)
    }

    func thread(_ store: MailStore, subject: String) -> MailThread? {
        store.view(label: nil, limit: 500).threads.first { $0.subject == subject || $0.subject == "Re: " + subject }
    }

    @Test func theFirstSyncKeepsFoldersAsLabels() async throws {
        let (fake, store, account) = try world()
        // The fake lives as long as the test: dropped, its process ends.
        defer { withExtendedLifetime(fake) {} }
        #expect(try await account.sync())
        let inbox = store.view(label: "INBOX", limit: 100).threads
        #expect(Set(inbox.map(\.subject)) == ["Offsite dates", "Contract draft", "Weekly digest", "Lunch Thursday?"])
        // The thread of three: two in the inbox, yours in Sent.
        let offsite = try #require(thread(store, subject: "Offsite dates"))
        #expect(store.messages(thread: offsite.id).count == 3)
        #expect(offsite.labels.isSuperset(of: ["INBOX", "SENT", "UNREAD"]))
        let digest = try #require(thread(store, subject: "Weekly digest"))
        #expect(digest.labels.contains("STARRED") && !digest.labels.contains("UNREAD"))
        // Archive: no label; Receipts: the person's own.
        let statement = try #require(thread(store, subject: "Statement ready"))
        #expect(!statement.labels.contains("INBOX"))
        let order = try #require(thread(store, subject: "Your order"))
        #expect(order.labels.contains("Label_f:Receipts"))
        #expect(store.labels().contains { $0.id == "Label_f:Projects/Yab" && $0.name == "Projects/Yab" })
        // The newest came whole; a file's bytes by its id.
        let contractThread = try #require(thread(store, subject: "Contract draft"))
        let contract = try #require(store.messages(thread: contractThread.id).first)
        #expect(contract.text == "The contract is attached.")
        let file = try #require(contract.files?.first)
        #expect(file.name == "contract.pdf")
        #expect(try await account.attachment(message: contract.id, id: file.attachmentID) == Data("%PDF-1.4 fake".utf8))
        // Nothing new: nothing changed.
        #expect(try await account.sync() == false)
        await account.close()
    }

    func acts(_ flags: [String]) async throws {
        let (fake, store, account) = try world(flags)
        try await account.sync()
        let lunch = try #require(thread(store, subject: "Lunch Thursday?"))
        let contract = try #require(thread(store, subject: "Contract draft"))
        let offsite = try #require(thread(store, subject: "Offsite dates"))
        let digest = try #require(thread(store, subject: "Weekly digest"))
        let lunchID = try #require(store.messages(thread: lunch.id).first?.id)
        // ⌘Z before it went: the server never hears of it.
        let undone = MailOps.act(.archive, thread: contract.id, after: 60, in: store)
        #expect(MailOps.undo(undone, in: store))
        MailOps.act(.archive, thread: lunch.id, in: store)
        MailOps.act(.star, thread: contract.id, in: store)
        MailOps.act(.read, thread: offsite.id, in: store)
        MailOps.act(.trash, thread: digest.id, in: store)
        try await MailOps.flush(store, provider: account)
        #expect(store.pendingOps == 0)
        #expect(try await fake.subjects("INBOX").contains("Contract draft"))
        #expect(try await fake.subjects("INBOX").contains("Lunch Thursday?") == false)
        #expect(try await fake.subjects("Archive").contains("Lunch Thursday?"))
        #expect(try await fake.flags("INBOX", subject: "Contract draft").contains("\\Flagged"))
        #expect(try await fake.flags("INBOX", subject: "Offsite dates").contains("\\Seen"))
        #expect(try await fake.flags("INBOX", subject: "Re: Offsite dates").contains("\\Seen"))
        #expect(try await fake.subjects("Deleted Messages").contains("Weekly digest"))
        // Synced again: the same rows, where the server has them now.
        try await account.sync()
        #expect(store.message(lunchID)?.labels.contains("INBOX") == false)
        #expect(thread(store, subject: "Weekly digest")?.labels.contains("TRASH") == true)
        #expect(thread(store, subject: "Contract draft")?.labels.contains("STARRED") == true)
        // Back to the inbox (⇧E), out of Trash (#).
        MailOps.act(.unarchive, thread: lunch.id, in: store)
        MailOps.act(.untrash, thread: digest.id, in: store)
        try await MailOps.flush(store, provider: account)
        #expect(try await fake.subjects("INBOX").contains("Lunch Thursday?"))
        #expect(try await fake.subjects("INBOX").contains("Weekly digest"))
        try await account.sync()
        #expect(store.message(lunchID)?.labels.contains("INBOX") == true)
        await account.close()
    }

    @Test func actsGoOutAsMovesAndFlags() async throws { try await acts([]) }

    @Test func actsWithoutMoveCondstoreOrUIDPlus() async throws { try await acts(["--no-move", "--no-condstore", "--no-uidplus", "--no-special-use"]) }

    @Test func theServersChangesComeBack() async throws {
        let (fake, store, account) = try world()
        try await account.sync()
        try await fake.post("add", ["folder": "INBOX", "sender": "Zoe <zoe@example.org>", "subject": "New one", "body": "Fresh mail."])
        #expect(try await account.sync())
        let fresh = try #require(thread(store, subject: "New one"))
        #expect(fresh.labels.contains("INBOX") && fresh.labels.contains("UNREAD"))
        #expect(store.messages(thread: fresh.id).first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) == "Fresh mail.")
        // Read elsewhere: \Seen on the server.
        let uid = try #require(try await fake.uid("INBOX", subject: "New one"))
        try await fake.post("flags", ["folder": "INBOX", "uid": uid, "add": ["\\Seen"]])
        #expect(try await account.sync())
        #expect(thread(store, subject: "New one")?.labels.contains("UNREAD") == false)
        // Deleted elsewhere: gone here.
        try await fake.post("expunge", ["folder": "INBOX", "uid": uid])
        #expect(try await account.sync())
        #expect(thread(store, subject: "New one") == nil)
        await account.close()
    }

    @Test func aNewValidityStartsTheFolderAgain() async throws {
        let (fake, store, account) = try world()
        try await account.sync()
        let before = store.view(label: "INBOX", limit: 100).threads.map(\.id).sorted()
        try await fake.post("validity", ["folder": "INBOX"])
        try await account.sync()
        #expect(store.view(label: "INBOX", limit: 100).threads.map(\.id).sorted() == before)
        await account.close()
    }

    @Test func aReplyGoesBySMTPAndIntoSent() async throws {
        let (fake, store, account) = try world()
        try await account.sync()
        store.set("me", "me@example.com")
        let lunch = try #require(thread(store, subject: "Lunch Thursday?"))
        var draft = try #require(MailCompose.reply(to: store.messages(thread: lunch.id), me: "me@example.com"))
        draft.body = "Thursday works."
        draft.messageID = MailCompose.messageID(from: "me@example.com")
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, provider: account)
        let state = try await fake.state()
        let sent = try #require((state["sent"] as? [[String: Any]])?.first)
        #expect(sent["to"] as? [String] == ["ravi@example.net"])
        #expect((sent["data"] as? String)?.contains("Subject: Re: Lunch Thursday?") == true)
        #expect((sent["data"] as? String)?.contains("In-Reply-To: <lunch@example.net>") == true)
        #expect(try await fake.subjects("Sent Messages").contains("Re: Lunch Thursday?"))
        // In its thread, in Sent, before and after the next sync, once.
        #expect(store.messages(thread: lunch.id).count == 2)
        try await account.sync()
        #expect(store.messages(thread: lunch.id).count == 2)
        #expect(thread(store, subject: "Lunch Thursday?")?.labels.contains("SENT") == true)
        await account.close()
    }

    @Test func theServerFindsOlderMail() async throws {
        let (fake, store, account) = try world()
        // Older than the sixty days a sync keeps: in Archive on the server alone.
        try await fake.post("add", ["folder": "Archive", "sender": "Passport Office <office@gov.example>", "subject": "Passport renewal",
                                    "body": "Your passport renewal is ready to collect.", "ago": 86_400 * 200, "flags": ["\\Seen"]])
        try await account.sync()
        #expect(thread(store, subject: "Passport renewal") == nil)
        let got = try await account.search(MailQuery.parse("passport renewal"), take: 25, pages: 1)
        let found = try #require(thread(store, subject: "Passport renewal"))
        #expect(got.threads == [found.id])
        #expect(!found.labels.contains("INBOX"))
        // Words in a folder named: there alone.
        #expect(try await account.search(MailQuery.parse("in:inbox passport"), take: 25, pages: 1).threads.isEmpty)
        let lunch = try await account.search(MailQuery.parse("from:ravi"), take: 25, pages: 1)
        #expect(lunch.threads == [try #require(thread(store, subject: "Lunch Thursday?")).id])
        // What SEARCH can't say: the store answers alone.
        #expect(try await account.search(MailQuery.parse("has:attachment contract"), take: 25, pages: 1).threads.isEmpty)
        await account.close()
    }

    @Test func theProbeSaysEachStep() async throws {
        let fake = try FakeIMAPServer()
        let good = await MailProbe.run("me@example.com", setup: fake.setup, password: "app-password")
        #expect(good.imap?.auth == "ok" && good.smtp?.auth == "ok" && good.ok)
        let bad = await MailProbe.run("me@example.com", setup: fake.setup, password: "wrong")
        #expect(bad.imap?.auth == "rejected" && bad.imap?.hint == "authRejected" && bad.imap?.said.contains("Authentication failed") == true)
        #expect(bad.smtp?.auth == "rejected")
        let none = await MailProbe.run("me@example.com", setup: fake.setup, password: nil)
        #expect(none.imap?.tcp == "ok" && none.imap?.auth.hasPrefix("not tried") == true)
        // Nothing listening there.
        var closed = fake.setup
        closed.imapPort = 9
        let refused = await MailProbe.run("me@example.com", step: "imap", setup: closed, password: "x")
        #expect(refused.imap?.hint == "tcpRefused" && refused.smtp == nil)
        try await fake.post("options", ["app_password_hint": true])
        let hinted = await MailProbe.run("me@example.com", step: "imap", setup: fake.setup, password: "wrong")
        #expect(hinted.imap?.hint == "appPasswordRequired")
        // Never a password in what it says.
        let said = String(decoding: try JSONSerialization.data(withJSONObject: good.json), as: UTF8.self)
        #expect(!said.contains("app-password"))
    }
}

// iCloud and Zoho as Add Account finds them (feedback #146), each against a
// fake shaped as that provider's servers are said to be (fake_imap.py
// --provider): their known hosts answered by the fake, iCloud's STARTTLS on
// 587 and Zoho's TLS on 465 left out on the stand-in's plain line.
@Suite(.serialized) struct MailProviderShapeTests {
    static let icloud = "sam.rivers@icloud.com"
    static let zoho = "sam@zohomail.com"

    func thread(_ store: MailStore, subject: String) -> MailThread? {
        store.view(label: nil, limit: 500).threads.first { $0.subject == subject || $0.subject == "Re: " + subject }
    }

    @Test func aStandInAnswersOnlyForTheHostsItNames() throws {
        Store.settings.removeObject(forKey: MailStandIn.key)
        let none = MailStandIn.route("imap.mail.me.com", 993, .tls)
        #expect(none.0 == "imap.mail.me.com" && none.1 == 993 && none.2 == .tls && !none.3)
        Store.settings.set(#"{"imap.mail.me.com": 40143}"#, forKey: MailStandIn.key)
        defer { Store.settings.removeObject(forKey: MailStandIn.key) }
        let fake = MailStandIn.route("IMAP.mail.me.com", 993, .tls)
        #expect(fake.0 == "127.0.0.1" && fake.1 == 40143 && fake.2 == .none && fake.3)
        #expect(MailStandIn.covers("imap.mail.me.com") && !MailStandIn.covers("smtp.mail.me.com"))
        // Any other host keeps its TLS: a plain line still goes only to this Mac.
        #expect(throws: MailServerTrouble.self) { _ = try MailSocket(host: "imap.example.com", port: 993, security: .none) }
    }

    /// #441: an app password pasted off Apple's page with what came with
    /// it, the line's end or a space, was sent as it was and refused every
    /// time; the agent's way, which reads it off the page, already left
    /// them off. As pasted now, both servers take it.
    @Test func anAppPasswordPastedWithItsLineEndIsTaken() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let fake = try FakeIMAPServer(["--provider", "icloud", "--user", Self.icloud])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        let setup = provider.setup(for: Self.icloud)
        for pasted in ["app-password\n", " app-password ", "app-password\t", "app- pass word"] {
            let raw = await MailProbe.run(Self.icloud, setup: setup, password: pasted)
            #expect(!raw.ok, "sent as pasted, \(pasted.debugDescription) is refused: the fake is strict")
            let cleaned = MailSecret.cleaned(pasted, appPassword: provider.appPassword)
            #expect(cleaned == "app-password")
            let probe = await MailProbe.run(Self.icloud, setup: setup, password: cleaned)
            #expect(probe.ok, "\(pasted.debugDescription): \(probe.json)")
        }
        // A password of the person's own keeps a space inside it.
        #expect(MailSecret.cleaned(" my pass\n", appPassword: false) == "my pass")
    }

    @Test func iCloudSignsInByTheNameBeforeTheAtAndKeepsItsOwnSentCopy() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let fake = try FakeIMAPServer(["--provider", "icloud", "--user", Self.icloud])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        let setup = provider.setup(for: Self.icloud, name: "Sam Rivers")
        #expect(setup.imapUser == "sam.rivers" && setup.smtpUser == Self.icloud && setup.savesSent)
        #expect(setup.smtpSecurity == .starttls && setup.smtpPort == 587)
        // The probe Add Account runs: both servers by their names, the password taken.
        let probe = await MailProbe.run(Self.icloud, setup: setup, password: "app-password")
        #expect(probe.ok, "\(probe.json)")
        #expect(probe.imap?.host == "imap.mail.me.com" && probe.imap?.dns == "ok" && probe.smtp?.tls == "none (this Mac)")
        let logins = try await fake.logins()
        #expect(logins.contains("sam.rivers") && logins.contains("smtp:" + Self.icloud), "\(logins)")

        let store = MailStore(file: MailStore.memory)
        let account = MailIMAPAccount(setup: setup, store: store, password: { "app-password" })
        #expect(try await account.sync())
        let inbox = Set(store.view(label: "INBOX", limit: 100).threads.map(\.subject))
        #expect(inbox == ["Offsite dates", "Contract draft", "Weekly digest", "Lunch Thursday?"])
        // Notes is iCloud's own, not mail.
        #expect(thread(store, subject: "Grocery list") == nil)
        #expect(!store.labels().contains { $0.name == "Notes" })
        #expect(thread(store, subject: "Offsite dates")?.labels.contains("SENT") == true)

        // A reply: SMTP keeps the copy itself, so Yab appends none.
        store.set("me", Self.icloud)
        let lunch = try #require(thread(store, subject: "Lunch Thursday?"))
        var draft = try #require(MailCompose.reply(to: store.messages(thread: lunch.id), me: Self.icloud))
        draft.body = "Thursday works."
        draft.messageID = MailCompose.messageID(from: Self.icloud)
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, provider: account)
        #expect(try await fake.calls("APPEND") == 0)
        #expect(try await fake.subjects("Sent Messages").filter { $0 == "Re: Lunch Thursday?" }.count == 1)
        try await account.sync()
        #expect(store.messages(thread: lunch.id).count == 2)
        await account.close()
    }

    @Test func zohoKeepsItsFoldersByNameAndMakesArchive() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "zohomail.com"))
        let fake = try FakeIMAPServer(["--provider", "zoho", "--user", Self.zoho])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        let setup = provider.setup(for: Self.zoho, name: "Sam Rivers")
        #expect(setup.imapHost == "imap.zoho.com" && setup.smtpPort == 465 && setup.imapUser == Self.zoho && !setup.savesSent)
        let store = MailStore(file: MailStore.memory)
        let account = MailIMAPAccount(setup: setup, store: store, password: { "app-password" })
        #expect(try await account.sync())
        #expect(try await fake.logins().first == Self.zoho)
        let inbox = Set(store.view(label: "INBOX", limit: 100).threads.map(\.subject))
        #expect(inbox == ["Kickoff agenda", "Invoice 0147 for October", "Reminder: design review at 3pm", "Photos from Saturday"])
        // Sent, Trash and Spam by their names alone (no SPECIAL-USE); Templates, Snoozed and Outbox not kept.
        let kickoff = try #require(thread(store, subject: "Kickoff agenda"))
        #expect(kickoff.labels.contains("SENT"))
        #expect(store.messages(thread: kickoff.id).count == 3)
        #expect(thread(store, subject: "Weekly update template") == nil && thread(store, subject: "Book club pick") == nil)
        let labels = store.labels().map(\.id)
        #expect(labels.contains("Label_f:Clients") && labels.contains("Label_f:Clients/Northwind"), "\(labels)")
        let notKept = ["Label_f:Templates", "Label_f:Snoozed", "Label_f:Outbox", "Label_f:Sent", "Label_f:Spam", "Label_f:Trash"]
        #expect(!labels.contains { notKept.contains($0) }, "\(labels)")
        #expect(thread(store, subject: "Northwind renewal")?.labels.contains("Label_f:Clients") == true)

        // Archive: no folder yet, so one is made, then a copy and an expunge (no MOVE).
        let photos = try #require(thread(store, subject: "Photos from Saturday"))
        let invoice = try #require(thread(store, subject: "Invoice 0147 for October"))
        MailOps.act(.archive, thread: photos.id, in: store)
        MailOps.act(.trash, thread: invoice.id, in: store)
        try await MailOps.flush(store, provider: account)
        #expect(try await fake.calls("CREATE") == 1)
        #expect(try await fake.subjects("Archive") == ["Photos from Saturday"])
        #expect(try await fake.subjects("Trash") == ["Invoice 0147 for October"])
        #expect(try await fake.subjects("INBOX").contains("Photos from Saturday") == false)

        // A reply from the account's own address; Zoho keeps no copy, so Yab appends one to Sent.
        store.set("me", Self.zoho)
        var draft = try #require(MailCompose.reply(to: store.messages(thread: kickoff.id), me: Self.zoho))
        draft.body = "Thanks, see you Monday."
        draft.messageID = MailCompose.messageID(from: Self.zoho)
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, provider: account)
        let sent = try #require((try await fake.state()["sent"] as? [[String: Any]])?.first)
        #expect(sent["from"] as? String == Self.zoho && sent["to"] as? [String] == ["dana@harbor.example"])
        #expect(try await fake.calls("APPEND") == 1)
        #expect(try await fake.subjects("Sent").filter { $0 == "Re: Kickoff agenda" }.count == 2)
        try await account.sync()
        #expect(store.messages(thread: kickoff.id).count == 4)
        // Search on the server: SEARCH's words for older mail, in every kept folder.
        try await fake.post("add", ["folder": "Clients", "sender": "Priya Raman <priya@northwind.example>", "subject": "Signed MSA 2025",
                                    "body": "The signed master agreement.", "ago": 86_400 * 300, "flags": ["\\Seen"]])
        let found = try await account.search(MailQuery.parse("master agreement"), take: 25, pages: 1)
        #expect(found.threads.count == 1)
        #expect(thread(store, subject: "Signed MSA 2025")?.labels.contains("Label_f:Clients") == true)
        await account.close()
    }

    @Test func zohoRefusesAWrongPasswordAsAnAppPasswordWanted() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "zohomail.com"))
        let fake = try FakeIMAPServer(["--provider", "zoho", "--user", Self.zoho])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        let probe = await MailProbe.run(Self.zoho, setup: provider.setup(for: Self.zoho), password: "my-sign-in-password")
        #expect(probe.imap?.auth == "rejected" && probe.imap?.hint == "appPasswordRequired")
        #expect(probe.smtp?.auth == "rejected" && !probe.ok)
        let said = String(decoding: try JSONSerialization.data(withJSONObject: probe.json), as: UTF8.self)
        #expect(!said.contains("my-sign-in-password"))
    }

    // #441, still on 0.38.8: a fresh app password, and "iCloud closed the
    // connection before it took the password". The line closed at the
    // sign-in with nothing said, so no refusal to read and no other name
    // tried. The fake acts each suspect: PLAIN closing the line where LOGIN
    // takes the same password (MailKit #295, Thunderbird 694753 on iCloud),
    // the name before @ closing it (Apple: "if it can't connect, use the
    // full address"), a refusal said as a BYE.

    /// What Add Account ran before: PLAIN on both servers, the whole address
    /// tried only after a NO.
    func before(_ setup: MailServerSetup, password: String) async -> MailProbe.Result {
        let known = MailKnownProviders.by(id: setup.provider)
        var result = MailProbe.Result(address: setup.address)
        result.imap = await MailProbe.imap(setup, password: password, known: known, auth: nil)
        result.smtp = await MailProbe.smtp(setup, password: password, known: known, auth: nil)
        if ["authRejected", "appPasswordRequired"].contains(result.imap?.hint ?? ""), setup.imapUser != setup.address {
            var whole = setup
            whole.imapUser = setup.address
            let again = await MailProbe.imap(whole, password: password, known: known, auth: nil)
            if again.ok { result.imap = again }
        }
        return result
    }

    @Test func iCloudSignsInByLoginWherePlainClosesTheLine() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let fake = try FakeIMAPServer(["--provider", "icloud", "--user", Self.icloud])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        try await fake.post("options", ["plain_drops": true])
        let setup = provider.setup(for: Self.icloud)
        #expect(setup.imapAuth == .login && setup.smtpAuth == .login)

        // Before: the reporter's line, on both servers.
        let old = await before(setup, password: "app-password")
        #expect(!old.ok && old.imap?.hint == "closed" && old.smtp?.hint == "closed", "\(old.json)")
        #expect(old.imap?.auth == "closed")

        // Now: LOGIN first, nothing sent by PLAIN.
        let calls = try await fake.logins().count
        let (probe, kept) = await MailProbe.connect(setup, password: "app-password")
        #expect(probe.ok, "\(probe.json)")
        #expect(probe.imap?.json["auth_way"] as? String == "login" && probe.smtp?.json["auth_way"] as? String == "login")
        let now = Array(try await fake.logins().dropFirst(calls))
        #expect(now == ["sam.rivers", "smtp:" + Self.icloud], "\(now)")
        #expect(kept.imapAuth == .login && kept.smtpAuth == .login && kept.imapUser == "sam.rivers")

        // An account kept before this (no way named) gets there too: PLAIN
        // closes, a moment, LOGIN on a new line, and that way is kept.
        var older = setup
        older.imapAuth = nil
        older.smtpAuth = nil
        let (again, fixed) = await MailProbe.connect(older, password: "app-password")
        #expect(again.ok, "\(again.json)")
        #expect(fixed.imapAuth == .login && fixed.smtpAuth == .login)

        // The sync signs in as the setup did.
        let store = MailStore(file: MailStore.memory)
        let account = MailIMAPAccount(setup: kept, store: store, password: { "app-password" })
        #expect(try await account.sync())
        #expect(!store.view(label: "INBOX", limit: 100).threads.isEmpty)
        await account.close()
    }

    @Test func aLineClosedOnTheNameBeforeTheAtTriesTheWholeAddress() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let fake = try FakeIMAPServer(["--provider", "icloud", "--user", Self.icloud])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        try await fake.post("options", ["name_drops": true])
        let setup = provider.setup(for: Self.icloud)

        let old = await before(setup, password: "app-password")
        #expect(!old.ok && old.imap?.hint == "closed", "\(old.json)")

        let (probe, kept) = await MailProbe.connect(setup, password: "app-password")
        #expect(probe.ok, "\(probe.json)")
        #expect(kept.imapUser == Self.icloud)
        #expect(try await fake.logins().contains(Self.icloud))
    }

    @Test func aRefusalSaidAsByeKeepsItsWords() async throws {
        let provider = try #require(MailKnownProviders.by(domain: "icloud.com"))
        let fake = try FakeIMAPServer(["--provider", "icloud", "--user", Self.icloud])
        let standIns = StandIns(provider, fake: fake)
        defer { standIns.end() }
        try await fake.post("options", ["bye_refusals": true])
        let (probe, _) = await MailProbe.connect(provider.setup(for: Self.icloud), password: "not-the-password")
        #expect(!probe.ok)
        #expect(probe.imap?.auth == "rejected" && probe.imap?.hint == "appPasswordRequired", "\(probe.json)")
        #expect(probe.imap?.said.contains("Too many failed sign-ins") == true, "\(probe.json)")
        // A right password is still taken, and a plain closed line stays "closed".
        let (good, _) = await MailProbe.connect(provider.setup(for: Self.icloud), password: "app-password")
        #expect(good.ok, "\(good.json)")
    }

    @Test func aSetupKeptBeforeSignInWaysStillReads() throws {
        let text = #"{"address":"a@icloud.com","name":"","imapHost":"imap.mail.me.com","imapPort":993,"imapSecurity":"tls","imapUser":"a","smtpHost":"smtp.mail.me.com","smtpPort":587,"smtpSecurity":"starttls","smtpUser":"a@icloud.com","provider":"icloud","foundBy":"known","savesSent":true}"#
        let setup = try JSONDecoder().decode(MailServerSetup.self, from: Data(text.utf8))
        #expect(setup.imapAuth == nil && setup.smtpAuth == nil && setup.imapUser == "a")
        var login = setup
        login.imapAuth = .login
        let back = try JSONDecoder().decode(MailServerSetup.self, from: JSONEncoder().encode(login))
        #expect(back.imapAuth == .login)
    }
}
