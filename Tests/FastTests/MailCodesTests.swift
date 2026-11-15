import Foundation
import Testing
@testable import Fast

// The code a site sent, found in its mail or text and offered under the box
// that asks for it (docs/mail.md, Codes from mail).
struct MailCodesTests {
    @Test func findsTheCodeNearItsWord() {
        #expect(MailCodes.code(in: "Your Linear login code is 481902. It expires in 10 minutes.") == "481902")
        #expect(MailCodes.code(in: "Verification code: 123 456") == "123456")
        #expect(MailCodes.code(in: "G-482913 is your Google verification code.") == "482913")
        #expect(MailCodes.code(in: "Ihr Bestätigungscode lautet 772019") == "772019")
    }

    @Test func leavesOtherNumbersAlone() {
        // No word saying it is a code.
        #expect(MailCodes.code(in: "Order 552199 has shipped") == nil)
        // A price, a year, a time, a phone number.
        #expect(MailCodes.code(in: "Confirm your payment of $1240 by Oct 3") == nil)
        #expect(MailCodes.code(in: "Security update for 2026: nothing to do, see you in March") == nil)
        #expect(MailCodes.code(in: "Your sign-in at 12:30 from a new device") == nil)
        #expect(MailCodes.code(in: "Confirm by calling 415 555 0100") == nil)
        #expect(MailCodes.code(in: "Security alert: a new sign-in from a device with screen width 1600") == nil)
        #expect(MailCodes.code(in: "Confirm your login. Reference 5872. If this wasn't you, review your account.") == nil)
    }

    @Test func picksTheNumberNearestTheWord() {
        let mail = "Invoice 20261104 for your account. Your one-time passcode is 902114. Order 7781."
        #expect(MailCodes.code(in: mail) == "902114")
    }

    @Test func aYearRightAfterItsWordIsACode() {
        #expect(MailCodes.code(in: "Your code: 2024") == "2024")
    }

    @Test func mailFromTheSiteIsItsOwn() {
        #expect(MailCodes.belongs(address: "no-reply@linear.app", from: "Linear", subject: "Your login code", to: "linear.app"))
        #expect(MailCodes.belongs(address: "noreply@accounts.google.com", from: "Google", subject: "", to: "accounts.google.com"))
        // A sender on another domain cannot claim the site in its name or subject.
        #expect(!MailCodes.belongs(address: "hello@mail.notion.so", from: "Notion Team", subject: "Notion code", to: "www.notion.com"))
        #expect(!MailCodes.belongs(address: "billing@ledgerly.io", from: "Ledgerly", subject: "Invoice", to: "linear.app"))
        #expect(!MailCodes.belongs(address: "unknown", from: "Linear", subject: "Linear code", to: "linear.app"))
    }

    @Test func readsGmailsFeed() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for me@gmail.com</title><fullcount>2</fullcount>
        <entry><title>Your Linear login code</title><summary>Your login code is 481902. It expires in 10 minutes.</summary>
        <link rel="alternate" href="https://mail.google.com/mail/u/0?account_id&amp;message_id=1" type="text/html" />
        <modified>2026-09-28T10:00:20Z</modified><issued>2026-09-28T10:00:20Z</issued>
        <author><name>Linear</name><email>notifications@linear.app</email></author></entry>
        <entry><title>Lunch &amp; plans</title><summary>See you at 12</summary>
        <modified>2026-09-28T09:00:00Z</modified><issued>2026-09-28T09:00:00Z</issued>
        <author><name>Anna</name><email>anna@fold.studio</email></author></entry>
        </feed>
        """
        let mail = MailCodes.feed(xml)
        #expect(mail.count == 2)
        #expect(mail[0].from == "Linear")
        #expect(mail[0].address == "notifications@linear.app")
        #expect(mail[1].subject == "Lunch & plans")

        let now = ISO8601DateFormatter().date(from: "2026-09-28T10:01:00Z")!
        let codes = MailCodes.codes(in: mail, for: "linear.app", now: now)
        #expect(codes.map(\.code) == ["481902"])
        #expect(codes.first?.mine == true)
        // Ten minutes on, it is no longer offered.
        #expect(MailCodes.codes(in: mail, for: "linear.app", now: now.addingTimeInterval(700)).isEmpty)
    }

    @Test func theSitesOwnComeFirstAndUsedOnesGo() {
        let now = Date()
        func code(_ id: String, _ digits: String, _ source: SentCode.Source, mine: Bool, ago: TimeInterval?) -> SentCode {
            SentCode(id: id, code: digits, from: id, at: ago.map { now.addingTimeInterval(-$0) }, source: source, mine: mine)
        }
        let all = [
            code("other", "111111", .mail, mine: false, ago: 5),
            code("key", "222222", .key, mine: true, ago: nil),
            code("old", "333333", .mail, mine: true, ago: 120),
            code("new", "444444", .text, mine: true, ago: 10),
            code("again", "444444", .mail, mine: true, ago: 11),
        ]
        #expect(MailCodes.ordered(all, without: []).map(\.id) == ["key", "new", "old"])
        #expect(MailCodes.ordered(all, without: ["new"]).map(\.id) == ["key", "again", "old"])
        // A saved TOTP changes every period and remains available on the next challenge.
        #expect(MailCodes.ordered(all, without: ["key", "new"]).map(\.id) == ["key", "again", "old"])
        #expect(MailCodes.ordered(Array(all.reversed()), without: []).map(\.id) == ["key", "new", "old"])
    }

    @Test func aChallengeRequiresItsOwnSourceAndLength() {
        let codes = [
            SentCode(id: "mail-number", code: "1600", from: "Site", at: Date(), source: .mail, mine: true),
            SentCode(id: "mail-code", code: "135790", from: "Site", at: Date(), source: .mail, mine: true),
            SentCode(id: "short-text", code: "2468", from: "Site", at: Date(), source: .text, mine: true),
            SentCode(id: "text-code", code: "246801", from: "Site", at: Date(), source: .text, mine: true),
            SentCode(id: "saved-key", code: "357902", from: "Site", at: nil, source: .key, mine: true),
        ]
        #expect(codes.filter(CodeRequest(source: .text, digits: 6).accepts).map(\.id) == ["text-code"])
        #expect(codes.filter(CodeRequest(source: .mail, digits: 6).accepts).map(\.id) == ["mail-code"])
        #expect(codes.filter(CodeRequest(source: .key, digits: 6).accepts).map(\.id) == ["saved-key"])
        #expect(codes.filter(CodeRequest(digits: 6).accepts).count == 3)
        #expect(codes.filter(CodeRequest().accepts) == codes)
    }

    @Test func anAuthenticatorBoxTakesApplePasswordsCodes() {
        let apple = SentCode(id: "apple", code: "482913", from: "erik@example.com", at: nil, source: .apple, mine: true)
        let locked = SentCode(id: "locked", code: "", from: "erik@example.com", at: nil, source: .apple, mine: true)
        #expect(CodeRequest(source: .key, digits: 6).accepts(apple))
        #expect(CodeRequest(digits: 6).accepts(apple))
        // Touch ID first: no digits to count until it is picked.
        #expect(CodeRequest(source: .key, digits: 6).accepts(locked))
        #expect(!CodeRequest(source: .text).accepts(apple))
        #expect(!CodeRequest(source: .mail).accepts(locked))
        // Made for now, like Yab's own keys: first, and never used up.
        let mail = SentCode(id: "mail", code: "135790", from: "Site", at: Date(), source: .mail, mine: true)
        #expect(MailCodes.ordered([mail, apple], without: ["apple"]).map(\.id) == ["apple", "mail"])
    }

    @Test func onlyCodesForTheCurrentRequestAreOffered() {
        let now = Date()
        let mail = [
            Mailed(from: "Brex", address: "security@brex.com", subject: "Your code", text: "Code: 111111", at: now.addingTimeInterval(-30)),
            Mailed(from: "Fireflies", address: "security@fireflies.ai", subject: "Brex verification", text: "Code: 222222", at: now.addingTimeInterval(-20)),
            Mailed(from: "Brex", address: "security@brex.com", subject: "Your code", text: "Code: 333333", at: now.addingTimeInterval(-500)),
            Mailed(from: "Brex", address: "security@brex.com", subject: "Your code", text: "Code: 444444", at: now.addingTimeInterval(90)),
        ]
        #expect(MailCodes.codes(in: mail, for: "app.brex.com", now: now, since: now.addingTimeInterval(-120)).map(\.code) == ["111111"])
    }

    @Test func applePasswordHintBelongsToOneSiteAndAccount() {
        let github = AppleCodeHints.id(host: "github.com", user: "Person@Example.com")
        #expect(github == AppleCodeHints.id(host: "www.github.com", user: "person@example.com"))
        #expect(github != AppleCodeHints.id(host: "brex.com", user: "person@example.com"))
        #expect(github != AppleCodeHints.id(host: "github.com", user: "other@example.com"))
        #expect(AppleCodeHints.id(host: "github.com", user: " ") == nil)
    }

    @Test func spacedInHalves() {
        #expect(MailCodes.spaced("481902") == "481 902")
        #expect(MailCodes.spaced("12345678") == "1234 5678")
        #expect(MailCodes.spaced("5521") == "5521")
    }
}
