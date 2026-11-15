import Foundation
import Testing
@testable import Fast

/// Mail read-only from the owner's mailbox, 2026-10-26. Codes, account names,
/// amounts, merchants and card digits replaced; sender domains and wording kept.
struct MailCodeCorpus {
    struct Sample {
        let sender: String
        let subject: String
        let text: String
        let code: String?
    }
    static let samples: [Sample] = [
        .init(sender: "3ds@brex.com", subject: "Brex Verification Code", text: "Confirm your THB 0.00 payment.\nPlease enter verification code 481902 to confirm your payment from card 555671******4417 to ExampleShop", code: "481902"),
        .init(sender: "support@stripe.com", subject: "Confirm your purchase at ExampleShop", text: "Please confirm your payment of USD 42.00 to ExampleShop using code 482913.", code: "482913"),
        .init(sender: "noreply@github.com", subject: "[GitHub] Sudo email verification code", text: "Here is your GitHub sudo authentication code: 902114\nThis code is valid for 15 minutes and can only be used once.", code: "902114"),
        .init(sender: "noreply@linear.app", subject: "Your Linear workspace delete request", text: "You have requested the deletion of the Example Linear workspace.\nThe verification code to proceed with the delete request of Example is:\n481902", code: "481902"),
        .init(sender: "noreply@google.com", subject: "Google Verification Code", text: "Your Google verification code is:\n482913", code: "482913"),
        .init(sender: "noreply@brex.com", subject: "Your verification code for Apple Pay", text: "Your verification code for your Brex card ending in 4417 for Apple Pay is 912345.\nYour code will expire in 7 days.", code: "912345"),
        .init(sender: "no-reply@slack.com", subject: "Slack confirmation code: 654-321", text: "Confirm your email address\nYour confirmation code is below — enter it in your open browser window and we'll help you get signed in.\n654-321", code: "654321"),
        .init(sender: "verifications@brex.com", subject: "[Action required] New sign-in to Brex", text: "Verify your device. We send this notification when there’s an attempted sign in from an unrecognized device or browser. Never share these links with anyone. They’ll expire in 10 minutes.", code: nil),
        .init(sender: "noreply@apple.com", subject: "Verify your email address", text: "You recently added person@example.test as an additional email address for your Apple ID. To verify that this email address belongs to you, please enter the code below on the email verification page:\n753951", code: "753951"),
        .init(sender: "no.reply.alerts@chase.com", subject: "Your one-time activation code is inside", text: "One-time activation. Use this one-time activation code to verify your card. Your one-time activation code: 135790. Use it to add your Chase credit card to your digital wallet.", code: "135790"),
        // Vercel's human-readable phrase identifies the login link; it is not a code to type.
        .init(sender: "system@vercel.com", subject: "Vercel Login Verification", text: "We have received a login attempt with the following code: Example Blue Bird. To complete the login process, please click on the link.", code: nil),
    ]

    @Test func realMailWithReplacedCodes() {
        for mail in Self.samples {
            #expect(MailCodeWords.read(subject: mail.subject, text: mail.text)?.code == mail.code, "Sender: \(mail.sender)")
        }
    }

    @Test func htmlWinsAndCarriesFacts() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let read = try #require(MailCodeWords.read(subject: "Confirm your purchase", text: "Verification code: 999999. Payment $42.00 at AWS. Card ending in 4417. Expires in 10 minutes.", html: "<table><tr><td style='font-size:30px'><span>481 902</span></td></tr></table>", received: at))
        #expect(read.code == "481902" && read.shown == "481 902" && read.sure)
        #expect(read.purpose == .purchase && read.amount == "$42.00" && read.card == "4417")
        #expect(read.merchant == "AWS")
        #expect(read.expires == at.addingTimeInterval(600))
        #expect(MailCodeWords.read(subject: "Sign in", text: "", html: "<div style='font-family:monospace'>GQX-41T</div>")?.code == "GQX41T")
        #expect(MailCodeWords.read(subject: "Sign in", text: "Code: GQX-41T")?.shown == "GQX-41T")
        #expect(MailCodeWords.read(subject: "Your verification code", text: "Your code is GQX-41T")?.code == "GQX41T")
        #expect(MailCodeWords.read(subject: "Your verification code", text: "Code: GQX-41T")?.code == "GQX41T")
        #expect(MailCodeWords.read(subject: "Verification code", text: "Confirm your purchase with code 481-902. Payment $42.00 at AWS.")?.amount == "$42.00")
    }

    @Test func numbersAndHiddenHtmlAreNotCodes() {
        for text in ["Stripe payout of $1240.00", "Order 552199 has shipped", "Call 415 555 0100", "Security update for 2026"] {
            #expect(MailCodeWords.read(subject: "", text: text) == nil)
        }
        #expect(MailCodeWords.read(subject: "Verification code", text: "", html: "<div style='display:none'><td>481902</td></div><p>Click to sign in</p>") == nil)
        #expect(MailCodeWords.read(subject: "", text: "", html: "<div style='overflow:hidden;font-size:30px'>481902</div>")?.code == "481902")
        #expect(MailCodeWords.read(subject: "Your sign-in code", text: "Use this link: https://example.test/login?code=481902") == nil)
        let signIn = MailCodeWords.read(subject: "Sign-in code", text: "Code: 481902. Your account balance is $42.00.")
        #expect(signIn?.amount == nil && signIn?.expires == nil && signIn?.purpose == .signIn)
    }

    @Test func storeKeepsParseAndUseAfterReopen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mail-code-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let at = Date(timeIntervalSince1970: 1_000)
        let message = MailMessage(id: "message", thread: "thread", from: MailPerson(name: "Brex", address: "noreply@brex.com"), date: at)
        let read = MailCodeRead(code: "481902", shown: "481 902", purpose: .signIn)
        do {
            let store = MailStore(file: file)
            store.keepCode(read, message: message)
            store.useCode(message: message.id, site: "brex.com", at: at)
            store.keepCode(read, message: message)
        }
        let reopened = MailStore(file: file)
        #expect(reopened.code(message: message.id) == read)
        #expect(reopened.codeMessage(thread: "thread") == message.id)
        #expect(reopened.codeUse(message: message.id)?.at == at)
    }
    @Test func ordinaryHtmlNumbersDoNotBecomeCodeMail() {
        let person = MailPerson(name: "Shop", address: "receipts@shop.test")
        let invoice = MailMessage(id: "invoice", thread: "invoice", from: person, subject: "Your invoice 552199",
                                  date: .now, text: "Invoice total $42.00", html: "<table><tr><td>552199</td></tr></table>")
        #expect(MailSense.kind(invoice, bulk: false) == .invoice)
        let order = MailMessage(id: "order", thread: "order", from: person, subject: "Order 552199 has shipped",
                                date: .now, text: "Your order has shipped", html: "<table><tr><td>552199</td></tr></table>")
        #expect(MailSense.kind(order, bulk: false) == .shipping)
    }

}
