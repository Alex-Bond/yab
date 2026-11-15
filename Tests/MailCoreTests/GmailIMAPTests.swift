import Foundation
import Testing
@testable import MailCore

@Suite(.serialized) struct GmailIMAPTests {
    func world(_ extra: [String] = []) throws -> (FakeIMAPServer, MailStore, MailIMAPAccount) {
        let fake = try FakeIMAPServer(["--provider", "gmail", "--user", "sam@gmail.com"] + extra)
        var setup = MailKnownProviders.by(id: "gmail")!.setup(for: "sam@gmail.com", name: "Sam Rivers")
        setup.imapHost = "127.0.0.1"
        setup.smtpHost = "127.0.0.1"
        setup.imapPort = fake.imap
        setup.smtpPort = fake.smtp
        setup.imapSecurity = .none
        setup.smtpSecurity = .none
        let store = MailStore(file: MailStore.memory)
        return (fake, store, MailIMAPAccount(setup: setup, store: store, password: { "app-password" }))
    }

    @Test func addressesAndWorkspaceUseAppPasswords() async throws {
        let gmail = try #require(MailKnownProviders.by(domain: "gmail.com"))
        #expect(gmail.route == .imap)
        #expect(MailKnownProviders.by(domain: "googlemail.com") == gmail)
        #expect(MailKnownProviders.by(mx: "aspmx.l.google.com") == gmail)
        let setup = gmail.setup(for: "sam@workspace.example")
        #expect(setup.imapHost == "imap.gmail.com" && setup.imapPort == 993 && setup.imapSecurity == .tls)
        #expect(setup.smtpHost == "smtp.gmail.com" && setup.smtpPort == 465 && setup.smtpSecurity == .tls)
        #expect(setup.imapUser == setup.address && setup.smtpUser == setup.address && setup.savesSent)
        #expect(gmail.appPasswordPage == "https://myaccount.google.com/apppasswords")
        #expect(MailSecret.cleaned(" \r\nabcd efgh ijkl mnop\n", appPassword: true) == "abcdefghijklmnop")
    }

    @Test func fetchesAllMailAndGmailThreadsAcrossLabels() async throws {
        let (fake, store, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        try await account.sync()
        let thread = try #require(store.view(label: "INBOX", limit: 100).threads.first { $0.subject.contains("Gmail project") })
        #expect(thread.id == "11bdfc5cae0c8191")
        #expect(store.messages(thread: thread.id).count == 2)
        #expect(thread.labels.isSuperset(of: ["INBOX", "SENT", "Label_f:Projects"]))
        #expect(try await account.thread(thread.id, full: true).count == 2)
        let subjects = store.view(label: nil, limit: 100).threads.map(\.subject)
        #expect(subjects.contains("Archived in Gmail"))
        #expect(!subjects.contains("Unsent Gmail draft"))
        let labels = try await account.labels()
        #expect(labels.contains { $0.id == "Label_f:Projects" })
        #expect(try await account.label(id: "INBOX").unread == 1)
        _ = try await account.sync()
        await account.close()
    }

    @Test func archiveAndLabelsPreserveOtherMemberships() async throws {
        let (fake, store, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        try await account.sync()
        let message = try #require(store.view(label: "INBOX", limit: 100).threads.first)
        _ = try await account.makeLabel(named: "Travel")
        try await account.apply(MailEdit( .thread(message.id), add: ["Label_f:Travel"], remove: []), in: store)
        #expect(try await fake.subjects("INBOX").contains("Gmail project"))
        #expect(try await fake.subjects("Travel").contains("Gmail project"))
        try await account.apply(MailEdit( .thread(message.id), add: [], remove: ["INBOX"]), in: store)
        #expect(try await fake.subjects("INBOX").isEmpty)
        #expect(try await fake.subjects("Projects").contains("Gmail project"))
        #expect(try await fake.subjects("[Gmail]/All Mail").contains("Gmail project"))
        #expect(try await fake.calls("CREATE") == 1) // Travel alone, never Archive.
        #expect(try await account.thread(message.id, full: true).count == 2)
        try await account.sync()
        let labels = store.messages(thread: message.id).reduce(into: Set<String>()) { $0.formUnion($1.labels) }
        #expect(!labels.contains("INBOX") && labels.contains("Label_f:Projects") && labels.contains("Label_f:Travel"))
        #expect(store.messages(thread: message.id).count == 2)
        try await account.apply(MailEdit( .thread(message.id), add: ["INBOX"], remove: ["Label_f:Travel"]), in: store)
        try await account.sync()
        #expect(try await fake.subjects("Travel").isEmpty)
        #expect(try await fake.subjects("INBOX").contains("Gmail project"))
        await account.close()
    }

    @Test func smtpKeepsOneSentCopyAndTheAddressAsLogin() async throws {
        let (fake, store, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        try await account.sync()
        let raw = "From: Sam Rivers <sam@gmail.com>\r\nTo: Ann <ann@example.org>\r\nSubject: Gmail SMTP test\r\nMessage-ID: <gmail-send@example.org>\r\n\r\nHello from the fake.\r\n"
        let sent = try await account.send(raw: raw, thread: "")
        let id = try #require(sent.message)
        let immediate = try #require(try await account.message(id, full: true))
        store.put([immediate])
        try await account.sync()
        #expect(try await fake.subjects("[Gmail]/Sent Mail").filter { $0 == "Gmail SMTP test" }.count == 1)
        #expect(try await fake.calls("APPEND") == 0)
        #expect(try await account.message(id, full: true) != nil)
        #expect(store.messages(thread: sent.thread).count == 1)
        #expect(try await account.sentThread(messageID: "<gmail-send@example.org>") == sent.thread)
        #expect(store.view(label: "SENT", limit: 100).threads.filter { $0.subject == "Gmail SMTP test" }.count == 1)
        #expect(try await fake.logins().contains("sam@gmail.com"))
        #expect(try await fake.logins().contains("smtp:sam@gmail.com"))
        await account.close()
    }

    @Test func sentCopyBeforeSMTPAcknowledgmentKeepsOneIdentity() async throws {
        let (fake, store, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        try await account.sync()
        try await fake.post("options", ["smtp_hold_ack": true])
        let raw = "From: Sam <sam@gmail.com>\r\nTo: ann@example.org\r\nSubject: SMTP acknowledgment race\r\nMessage-ID: <gmail-race@example.org>\r\n\r\nOne sent copy.\r\n"
        let sending = Task { try await account.send(raw: raw, thread: "") }
        do {
            for _ in 0..<250 {
                if try await fake.subjects("[Gmail]/Sent Mail").contains("SMTP acknowledgment race") { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(try await fake.subjects("[Gmail]/Sent Mail").contains("SMTP acknowledgment race"))
            try await account.sync()
            #expect(try await fake.calls("SMTP ACK") == 0)
            try await fake.post("options", ["smtp_hold_ack": false])
            let sent = try await sending.value
            let id = try #require(sent.message)
            let immediate = try #require(try await account.message(id, full: true))
            store.put([immediate])
            try await account.sync()
            #expect(store.view(label: "SENT", limit: 100).threads.filter { $0.subject == "SMTP acknowledgment race" }.count == 1)
            #expect(try await account.message(id, full: true) != nil)
        } catch {
            try? await fake.post("options", ["smtp_hold_ack": false])
            _ = try? await sending.value
            await account.close()
            throw error
        }
        await account.close()
    }

    @Test func wrongPasswordIsAnAppPasswordRefusal() async throws {
        let (fake, _, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        let probe = await MailProbe.run("sam@gmail.com", setup: account.setup, password: "wrong-password")
        #expect(!probe.ok && probe.imap?.hint == "appPasswordRequired" && probe.smtp?.hint == "appPasswordRequired")
        await account.close()
    }

    @Test func gmailFoldersStillWorkWithoutExtensions() async throws {
        let (fake, store, account) = try world()
        defer { withExtendedLifetime(fake) {} }
        try await fake.post("options", ["gmail_extensions": false])
        try await account.sync()
        #expect(store.view(label: nil, limit: 100).threads.contains { $0.subject == "Archived in Gmail" })
        let thread = try #require(store.view(label: "INBOX", limit: 100).threads.first)
        try await account.apply(MailEdit( .thread(thread.id), add: [], remove: ["INBOX"]), in: store)
        #expect(try await fake.subjects("INBOX").isEmpty)
        #expect(try await fake.calls("CREATE") == 0)
        await account.close()
    }
}
