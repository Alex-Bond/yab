import Foundation
import Testing
@testable import MailCore

// What reading purchases out of a heap of mail costs (a real mailbox,
// 2026-10-25: 8,000 candidates over two accounts kept a core busy without
// rest). Receipts as the big senders write them: tables of inline styles,
// a Cyrillic line, the total near the end. The time is printed for A/B runs
// against the parent commit; the bound only catches it getting far worse.
struct MailPurchasesSpeedTests {
    static let now = Date(timeIntervalSince1970: 1_792_900_000)

    static func receipt(_ n: Int, size: Int) -> MailMessage {
        var html = "<html><head><style>td{font-family:Helvetica}</style></head><body><table width=\"100%\">"
        var row = 0
        while html.utf8.count < size {
            html += "<tr><td style=\"padding:8px 16px;color:#333333;font-size:14px;line-height:20px\">"
            html += "Item \(row) · Pro plan add-on, billed monthly, Спасибо за покупку</td>"
            html += "<td style=\"text-align:right;padding:8px 16px\">$\(row % 90 + 10).00</td></tr>"
            row += 1
        }
        html += "<tr><td>Total</td><td>$\(n % 500 + 20).99</td></tr></table>"
        html += "<p>Order number: A\(100_000 + n)-77</p><p>Visa ending in 4411</p></body></html>"
        return MailMessage(id: "m\(n)", thread: "t\(n)", from: MailPerson.one("Store <receipts@store\(n % 40).com>")!,
                           subject: "Your receipt from Store \(n % 40) #\(n)", snippet: "Thanks for your order",
                           date: now.addingTimeInterval(-Double(n) * 3_600), labels: ["INBOX"], listUnsubscribe: true, html: html)
    }

    @Test func aHeapOfReceiptsReadsQuickly() {
        let mail = (0..<200).map { Self.receipt($0, size: 40_000) }
        let clock = ContinuousClock()
        var read = 0
        let took = clock.measure {
            for message in mail where MailPurchases.read(message, now: Self.now) != nil { read += 1 }
        }
        let ms = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        print(String(format: "purchases-speed: %d mails of 40 KB, %d read, %.0f ms, %.2f ms a mail", mail.count, read, ms, ms / Double(mail.count)))
        #expect(read > mail.count / 2)
        #expect(ms < 60_000)
    }

    /// "Order" and then a long run of blanks, as a table comes out in a
    /// plain part: it took the number's pattern cubic time in the blanks.
    @Test func aRunOfBlanksAfterOrderIsNoWork() {
        let text = String(repeating: "Order" + String(repeating: " ", count: 2_000) + "?\n", count: 20) + "Order number: A100-77"
        let clock = ContinuousClock()
        var number: String?
        let took = clock.measure { number = MailPurchases.orderNumber(in: text) }
        #expect(number == "A100-77")
        #expect(took < .seconds(1))
    }

    /// A very long mail is read by its start and its end.
    @Test func aVeryLongMailKeepsItsStartAndEnd() {
        let body = "Receipt from Figma\n" + String(repeating: "Спасибо за покупку, line of a digest\n", count: 5_000) + "Total: $144.00"
        let short = MailPurchases.clipped(body)
        #expect(short.utf16.count < 60_010)
        #expect(short.hasPrefix("Receipt from Figma"))
        #expect(short.hasSuffix("Total: $144.00"))
        #expect(MailPurchases.clipped("Total: $144.00") == "Total: $144.00")
    }

    /// The code read skips elements too big to be one, never the code in a
    /// mail that big.
    @Test func aReceiptWithACodeInACellIsStillACode() {
        let cell = "<td style=\"font-size:32px;letter-spacing:4px\">482913</td>"
        let html = "<html><body><table><tr><td>" + String(repeating: "<p>filler words</p>", count: 2_000) + "</td></tr><tr>" + cell + "</tr></table></body></html>"
        let read = MailCodeWords.read(subject: "Your login code", text: "", html: html, received: Self.now)
        #expect(read?.code == "482913")
    }
}
