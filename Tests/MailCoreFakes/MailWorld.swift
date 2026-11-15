import Foundation
import MailCore

/// A store and a MailGmail on a FakeGmail of their own, as the sync tests
/// use them. `host` nil: Gmail's own address, answered by FakeGmail.current;
/// a host: a world served beside the others (FakeGmail.serve), for a suite
/// that runs alongside MailSyncTests.
public enum MailWorld {
    public static func make(host: String? = nil) -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let session = URLSession(configuration: config)
        let gmail: MailGmail
        if let host {
            FakeGmail.serve(fake, at: host)
            gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: session, token: { "token" }, tries: 3, wait: 0.01)
        } else {
            FakeGmail.current = fake
            gmail = MailGmail(session: session, token: { "token" }, tries: 3, wait: 0.01)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-\(UUID().uuidString).sqlite")
        return (MailStore(file: file), gmail, fake)
    }

    /// A morning's inbox: Anna's thread with your answer, an invoice, a digest.
    public static func seed(_ fake: FakeGmail, now: Date) {
        fake.add(.init(id: "a1", thread: "ta", from: "Anna Lindqvist <anna@fold.studio>", subject: "Thursday works?",
                       body: "Can we do the review Thursday? Deck v3 attached.", at: now.addingTimeInterval(-3600), labels: ["INBOX", "UNREAD"]), record: false)
        fake.add(.init(id: "a2", thread: "ta", from: "me@example.com", to: "anna@fold.studio", subject: "Re: Thursday works?",
                       body: "Thursday at 3 works.", at: now.addingTimeInterval(-1800), labels: ["SENT"]), record: false)
        fake.add(.init(id: "b1", thread: "tb", from: "Ledgerly <billing@ledgerly.io>", subject: "Invoice #4471 is past due",
                       body: "Your card was declined.", at: now.addingTimeInterval(-7200), labels: ["INBOX"]), record: false)
        fake.add(.init(id: "c1", thread: "tc", from: "News <news@digest.io>", subject: "Weekly digest",
                       body: "Ten links.", at: now.addingTimeInterval(-9000), labels: ["INBOX", "CATEGORY_UPDATES"]), record: false)
    }
}
