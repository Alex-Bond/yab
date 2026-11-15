import Foundation
import Testing
@testable import MailCore

// Purchases read out of kept mail (MailPurchases): receipts, renewals,
// cancellations, orders and their shipping, and the lists made of them.
struct MailPurchasesTests {
    // Wednesday, Oct 21 2026, 10:00 local.
    static let now: Date = day(2026, 10, 21, hour: 10)

    static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var parts = DateComponents(year: year, month: month, day: day, hour: hour)
        parts.calendar = Calendar.current
        return parts.date!
    }

    func message(_ from: String, _ subject: String, _ text: String, at: Date = MailPurchasesTests.now.addingTimeInterval(-3600),
                 bulk: Bool = false, labels: Set<String> = ["INBOX"]) -> MailMessage {
        MailMessage(id: UUID().uuidString, thread: UUID().uuidString, from: MailPerson.one(from)!, subject: subject,
                    snippet: String(text.prefix(120)), date: at, labels: labels, listUnsubscribe: bulk, text: text)
    }

    func read(_ from: String, _ subject: String, _ text: String, at: Date = MailPurchasesTests.now.addingTimeInterval(-3600),
              bulk: Bool = false) -> MailPurchase? {
        MailPurchases.read(message(from, subject, text, at: at, bulk: bulk), now: Self.now)
    }

    func same(_ a: Date?, _ b: Date) -> Bool {
        a.map { Calendar.current.isDate($0, inSameDayAs: b) } ?? false
    }

    // MARK: - fixtures

    func figma(at: Date) -> MailPurchase? {
        read("Figma <billing@figma.com>", "Your Figma receipt [#4411-2026]", """
        Thanks for your payment.
        Figma Professional plan, billed annually
        1 editor × $144.00/year
        Total: $144.00
        Charged to Visa ending in 4411
        """, at: at)
    }

    func notion(at: Date, words: String = "Notion Plus plan, billed monthly") -> MailPurchase? {
        read("Notion Team <team@makenotion.com>", "Your Notion receipt", """
        \(words)
        Amount paid $10.00
        Visa •••• 1881
        """, at: at)
    }

    // MARK: - subscriptions

    @Test func aYearlyFigmaReceipt() throws {
        let p = try #require(figma(at: Self.day(2025, 10, 22, hour: 9)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Figma")
        #expect(p.host == "figma.com")
        #expect(p.title == "Figma Professional")
        #expect(p.amount == 144)
        #expect(p.currency == "USD")
        #expect(p.period == .year)
        #expect(p.card == "4411")
        #expect(p.brand == "Visa")
        #expect(!p.canceled)
    }

    @Test func aMonthlyNotionReceipt() throws {
        let p = try #require(notion(at: Self.day(2026, 10, 1, hour: 9)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Notion")
        #expect(p.host == "makenotion.com")
        #expect(p.title == "Notion Plus")
        #expect(p.amount == 10)
        #expect(p.period == .month)
        #expect(p.card == "1881")
        #expect(p.brand == "Visa")
    }

    @Test func netflixSaysItsNextBillingDate() throws {
        let p = try #require(read("Netflix <info@account.netflix.com>", "Your monthly Netflix payment", """
        We received your payment of $15.49 for your Standard plan.
        Next billing date: Nov 9, 2026
        Payment method: Mastercard •••• 5100
        """, at: Self.day(2026, 10, 9, hour: 8)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Netflix")
        #expect(p.host == "netflix.com")
        #expect(p.title == "Netflix Standard")
        #expect(p.amount == 15.49)
        #expect(p.period == .month)
        #expect(same(p.renews, Self.day(2026, 11, 9)))
        #expect(p.card == "5100")
        #expect(p.brand == "Mastercard")
    }

    @Test func anAppStoreReceiptNamesTheApp() throws {
        let p = try #require(read("Apple <no_reply@email.apple.com>", "Your receipt from Apple.", """
        Receipt
        Apple Account: sam@icloud.com
        Date: Oct 3, 2026
        Order ID: MT8K2LQ9ZP
        App Store
        Bear Markdown Notes
        Bear Pro (Monthly)
        Renews Nov 3, 2026
        $2.99
        Total $2.99
        Billed to Visa •••• 4411
        """, at: Self.day(2026, 10, 3, hour: 7)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Bear Markdown Notes")
        #expect(p.title == "Bear Pro")
        #expect(p.host == nil)
        #expect(p.amount == 2.99)
        #expect(p.period == .month)
        #expect(same(p.renews, Self.day(2026, 11, 3)))
        #expect(p.card == "4411")
    }

    @Test func spotifyPaidWithApplePay() throws {
        let p = try #require(read("Spotify <no-reply@spotify.com>", "Your Spotify Premium receipt", """
        Spotify Premium Individual
        Monthly subscription
        Total $11.99
        Paid with Apple Pay
        """, at: Self.day(2026, 10, 12, hour: 6)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Spotify")
        #expect(p.title == "Spotify Premium")
        #expect(p.amount == 11.99)
        #expect(p.period == .month)
        #expect(p.card == nil)
        #expect(p.brand == "Apple Pay")
    }

    @Test func claudeThroughStripeIsAnthropics() throws {
        let p = try #require(read("Anthropic, PBC <receipts@stripe.com>", "Your receipt from Anthropic, PBC #2391-4412", """
        Receipt from Anthropic, PBC
        Receipt #2391-4412
        Claude Pro
        Qty 1
        $20.00
        Billed monthly
        Total $20.00
        Amount paid $20.00
        Payment method Visa – 4242
        Questions? Visit https://support.anthropic.com
        Powered by https://stripe.com
        """, at: Self.day(2026, 10, 14, hour: 12)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Anthropic")
        #expect(p.host == "anthropic.com")
        #expect(p.title == "Claude Pro")
        #expect(p.amount == 20)
        #expect(p.period == .month)
        #expect(p.card == "4242")
        #expect(p.brand == "Visa")
    }

    @Test func googleOne() throws {
        let p = try #require(read("Google Payments <payments-noreply@google.com>", "Your Google One membership receipt", """
        Google One 100 GB (Monthly)
        Total: $1.99/mo
        Visa-4411
        Next charge: Nov 15, 2026
        """, at: Self.day(2026, 10, 15, hour: 9)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Google")
        #expect(p.host == "google.com")
        #expect(p.title == "Google One")
        #expect(p.amount == 1.99)
        #expect(p.period == .month)
        #expect(same(p.renews, Self.day(2026, 11, 15)))
    }

    @Test func aRenewalReminder() throws {
        let p = try #require(read("Headspace <no-reply@headspace.com>", "Your subscription renews on November 5", """
        Your annual Headspace subscription renews on November 5 for $69.99. No action is needed.
        """, at: Self.day(2026, 10, 20, hour: 9), bulk: true))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Headspace")
        #expect(p.amount == 69.99)
        #expect(p.period == .year)
        #expect(same(p.renews, Self.day(2026, 11, 5)))
        // A month and day without a year is the next one after the mail.
        let late = try #require(read("Headspace <no-reply@headspace.com>", "Your subscription renews on November 5",
                                     "Your annual Headspace subscription renews on November 5 for $69.99.",
                                     at: Self.day(2026, 12, 1)))
        #expect(same(late.renews, Self.day(2027, 11, 5)))
    }

    @Test func aCancellation() throws {
        let p = try #require(read("Linear <billing@linear.app>", "Your plan has been canceled", """
        Your Linear Standard plan has been canceled. You'll have access until Oct 22.
        """, at: Self.day(2026, 10, 15, hour: 9)))
        #expect(p.kind == .subscription)
        #expect(p.canceled)
        #expect(p.title == "Linear Standard")
        #expect(p.renews == nil)
        #expect(same(p.ends, Self.day(2026, 10, 22)))
    }

    @Test func aRussianReceipt() throws {
        let p = try #require(read("Яндекс Плюс <noreply@plus.yandex.ru>", "Чек об оплате подписки", """
        Ваша подписка продлена на 1 месяц.
        Итого: 299 ₽
        Карта *4411
        Следующее списание 21 ноября
        """, at: Self.day(2026, 10, 21, hour: 8)))
        #expect(p.kind == .subscription)
        #expect(p.merchant == "Яндекс Плюс")
        #expect(p.host == "yandex.ru")
        #expect(p.amount == 299)
        #expect(p.currency == "RUB")
        #expect(p.period == .month)
        #expect(p.card == "4411")
        #expect(same(p.renews, Self.day(2026, 11, 21)))
    }

    @Test func aGermanInvoice() throws {
        let p = try #require(read("Hetzner Online GmbH <billing@hetzner.com>", "Ihre Rechnung R0012345678", """
        Sehr geehrter Kunde,
        anbei Ihre Rechnung vom 01.10.2026.
        Rechnungsbetrag: 29,99 €
        Der Betrag wird von Ihrer Kreditkarte (Mastercard, endet auf 5100) abgebucht.
        """, at: Self.day(2026, 10, 1, hour: 9)))
        #expect(p.kind == .receipt)
        #expect(p.merchant == "Hetzner Online")
        #expect(p.host == "hetzner.com")
        #expect(p.amount == 29.99)
        #expect(p.currency == "EUR")
        #expect(p.card == "5100")
        #expect(p.brand == "Mastercard")
    }

    // MARK: - orders

    @Test func anAmazonOrder() throws {
        let p = try #require(read("Amazon.com <auto-confirm@amazon.com>", "Your Amazon.com order of \"Anker 737 Power Bank\" and 1 more item", """
        Thanks for your order, Sam!
        Arriving Friday
        Order #112-4433221-5566778
        Order Total: $89.98
        """, at: Self.day(2026, 10, 20, hour: 9)))
        #expect(p.kind == .order)
        #expect(p.shipping == .ordered)
        #expect(p.merchant == "Amazon")
        #expect(p.host == "amazon.com")
        #expect(p.title == "Anker 737 Power Bank")
        #expect(p.order == "112-4433221-5566778")
        #expect(p.amount == 89.98)
        #expect(same(p.arrives, Self.day(2026, 10, 23)))
    }

    func appleShipped(at: Date) -> MailPurchase? {
        read("Apple Store <noreply@email.apple.com>", "Your order has shipped", """
        Your order has shipped.
        Order Number: W1234567890
        AirPods Pro 3
        Qty 1
        Shipped via UPS
        Tracking number 1Z999AA10123456784
        Estimated delivery: Oct 23
        """, at: at)
    }

    @Test func appleShippedByUPS() throws {
        let p = try #require(appleShipped(at: Self.day(2026, 10, 20, hour: 15)))
        #expect(p.kind == .order)
        #expect(p.shipping == .shipped)
        #expect(p.merchant == "Apple")
        #expect(p.host == "apple.com")
        #expect(p.title == "AirPods Pro 3")
        #expect(p.order == "W1234567890")
        #expect(p.tracking == "1Z999AA10123456784")
        #expect(p.carrier == "UPS")
        #expect(same(p.arrives, Self.day(2026, 10, 23)))
    }

    func uspsOut(at: Date) -> MailPurchase? {
        read("USPS <USPSInformeddelivery@email.informeddelivery.usps.com>", "Your package is out for delivery", """
        Your package is out for delivery.
        Tracking Number: 9400111899223197428490
        Expected Delivery by 8:00pm today
        """, at: at)
    }

    @Test func uspsOutForDelivery() throws {
        let p = try #require(uspsOut(at: Self.day(2026, 10, 21, hour: 7)))
        #expect(p.kind == .order)
        #expect(p.shipping == .outForDelivery)
        #expect(p.tracking == "9400111899223197428490")
        #expect(p.carrier == "USPS")
        #expect(p.merchant == "USPS")
        #expect(same(p.arrives, Self.day(2026, 10, 21)))
    }

    func fedexDelivered(at: Date) -> MailPurchase? {
        read("FedEx <TrackingUpdates@fedex.com>", "Your package from Bellroy has been delivered", """
        Delivered: Tue 10/20/2026 at 2:14 PM
        Tracking number 748912345678
        """, at: at)
    }

    @Test func fedexDelivered() throws {
        let p = try #require(fedexDelivered(at: Self.day(2026, 10, 20, hour: 14)))
        #expect(p.shipping == .delivered)
        #expect(p.tracking == "748912345678")
        #expect(p.carrier == "FedEx")
        #expect(p.merchant == "Bellroy")
        #expect(p.arrives == nil)
    }

    @Test func dhlOnItsWay() throws {
        let p = try #require(read("DHL Express <noreply@dhl.com>", "Your DHL shipment is on its way", """
        Waybill 1234567890
        Expected delivery: Thursday
        """, at: Self.day(2026, 10, 20, hour: 9)))
        #expect(p.shipping == .shipped)
        #expect(p.tracking == "1234567890")
        #expect(p.carrier == "DHL")
        #expect(same(p.arrives, Self.day(2026, 10, 22)))
    }

    // MARK: - not purchases

    @Test func notPurchases() {
        // A newsletter's coupon.
        #expect(read("Sweetgreen <news@sweetgreen.com>", "Fall menu is here", "Get $5 off your next order this week. Order now.", bulk: true) == nil)
        // A promotion about a plan.
        #expect(read("Calm <hello@calm.com>", "Save 50% on your subscription",
                     "Upgrade to the annual plan and save 50%. Just $34.99 a year. Offer ends Sunday.", bulk: true) == nil)
        // A person, about money.
        #expect(read("Alex Kim <alex@gmail.com>", "Dinner", "I paid $84 for dinner, send me your half ($42) when you can.") == nil)
        #expect(read("Maria Lopez <maria@acme.co>", "Lunch", "I'll pay you back the $15 tomorrow, thanks for the receipt photo") == nil)
        #expect(read("Maria Lopez <maria@acme.co>", "Re: Invoice #12", "Paid it, $400 total.") == nil)
        // A code.
        #expect(read("Netflix <info@account.netflix.com>", "Your sign-in code", "Enter this code to sign in: 482913") == nil)
        // A plan's news without a charge.
        #expect(read("Notion <team@makenotion.com>", "What's new in your plan", "Notion Plus is now $12/month with AI included.", bulk: true) == nil)
        // Mail you sent.
        let sent = message("Figma <billing@figma.com>", "Your Figma receipt", "Total: $144.00", labels: ["SENT"])
        #expect(MailPurchases.read(sent, now: Self.now) == nil)
    }

    // MARK: - parts

    @Test func amounts() {
        let cases: [(String, Double, String)] = [
            ("Total $1,240.00", 1240, "USD"), ("USD 20", 20, "USD"), ("Paid 20.00 USD", 20, "USD"), ("€9,99", 9.99, "EUR"),
            ("£4.99 a month", 4.99, "GBP"), ("¥1,200", 1200, "JPY"), ("299 ₽", 299, "RUB"), ("₽ 299", 299, "RUB"),
            ("Total: $15.00", 15, "USD"), ("Amount paid $180.00", 180, "USD"), ("29,99 €", 29.99, "EUR"),
            ("1.240,50 €", 1240.5, "EUR"),
        ]
        for (text, value, currency) in cases {
            let found = MailPurchases.amount(in: text)
            #expect(found?.value == value, "\(text)")
            #expect(found?.currency == currency, "\(text)")
        }
        // The total, not a line above it or a larger number beside it.
        #expect(MailPurchases.amount(in: "Subtotal $14.00\nTax $1.00\nTotal $15.00\nYou saved $30.00")?.value == 15)
        #expect(MailPurchases.amount(in: "No money here, order 42") == nil)
    }

    @Test func trackingNumbers() {
        #expect(MailPurchases.tracking(in: "Tracking: 1Z999AA10123456784")?.carrier == "UPS")
        #expect(MailPurchases.tracking(in: "Tracking: 9400 1118 9922 3197 4284 90")?.number == "9400111899223197428490")
        #expect(MailPurchases.tracking(in: "Tracking: 9400111899223197428490")?.carrier == "USPS")
        #expect(MailPurchases.tracking(in: "FedEx tracking 748912345678")?.carrier == "FedEx")
        #expect(MailPurchases.tracking(in: "Your DHL waybill 1234567890")?.number == "1234567890")
        // Digits alone, with no carrier named, are no tracking number.
        #expect(MailPurchases.tracking(in: "Call 1234567890 or quote 748912345678") == nil)
    }

    @Test func cards() {
        #expect(MailPurchases.card(in: "Charged to Visa ending in 4411")?.last4 == "4411")
        #expect(MailPurchases.card(in: "Charged to Visa ending in 4411")?.brand == "Visa")
        #expect(MailPurchases.card(in: "Mastercard •••• 5100")?.last4 == "5100")
        #expect(MailPurchases.card(in: "Mastercard •••• 5100")?.brand == "Mastercard")
        #expect(MailPurchases.card(in: "American Express ending 1005")?.last4 == "1005")
        #expect(MailPurchases.card(in: "American Express ending 1005")?.brand == "Amex")
        #expect(MailPurchases.card(in: "Card ending in 9012")?.last4 == "9012")
        #expect(MailPurchases.card(in: "Card ending in 9012").map { $0.brand == nil } == true)
        #expect(MailPurchases.card(in: "Карта *4411")?.last4 == "4411")
        #expect(MailPurchases.card(in: "No card here") == nil)
    }

    @Test func amountsSaid() {
        #expect(MailPurchases.said(15, "USD") == "$15")
        #expect(MailPurchases.said(15.49, "USD") == "$15.49")
        #expect(MailPurchases.said(1240, "USD") == "$1,240")
        #expect(MailPurchases.said(9.99, "EUR") == "€9.99")
        #expect(MailPurchases.said(299, "RUB").contains("299"))
        #expect(!MailPurchases.said(299, "RUB").contains(".00"))
    }

    // MARK: - lists

    @Test func subscriptionsOnePerMerchant() throws {
        let figmaOld = try #require(figma(at: Self.day(2024, 10, 22, hour: 9)))
        let figmaLast = try #require(figma(at: Self.day(2025, 10, 22, hour: 9)))
        // No period word: two charges a month apart say it.
        let notionA = try #require(notion(at: Self.day(2026, 9, 3, hour: 9), words: "Notion Plus plan"))
        let notionB = try #require(notion(at: Self.day(2026, 10, 3, hour: 9), words: "Notion Plus plan"))
        #expect(notionB.period == nil)
        // Last charged in June, monthly: gone.
        let stale = try #require(notion(at: Self.day(2026, 6, 1, hour: 9)).map { p -> MailPurchase in
            var p = p
            p.merchant = "Raycast"
            p.host = "raycast.com"
            return p
        })
        let canceled = try #require(read("Linear <billing@linear.app>", "Your plan has been canceled",
                                         "Your Linear Standard plan has been canceled. You'll have access until Oct 22.",
                                         at: Self.day(2026, 10, 15, hour: 9)))
        let canceledLong = try #require(read("Loom <billing@loom.com>", "Your plan has been canceled",
                                             "Your Loom Business plan has been canceled. You'll have access until Sep 30.",
                                             at: Self.day(2026, 9, 1, hour: 9)))
        let reminder = try #require(read("Headspace <no-reply@headspace.com>", "Your subscription renews on November 5",
                                         "Your annual Headspace subscription renews on November 5 for $69.99.",
                                         at: Self.day(2026, 10, 20, hour: 9)))
        let amazon = try #require(read("Amazon.com <auto-confirm@amazon.com>", "Your Amazon.com order of \"Cable\"",
                                       "Thanks for your order\nOrder #112-1\nOrder Total: $9.98", at: Self.day(2026, 10, 20)))

        let list = MailPurchases.subscriptions([figmaOld, figmaLast, notionA, notionB, stale, canceled, canceledLong, reminder, amazon],
                                               now: Self.now)
        #expect(list.map { $0.merchant } == ["Figma", "Linear", "Notion", "Headspace"])
        let figmaRow = try #require(list.first { $0.merchant == "Figma" })
        #expect(figmaRow.message == figmaLast.message)
        // "Figma renews tomorrow."
        #expect(same(figmaRow.renews, Self.day(2026, 10, 22)))
        #expect(MailPurchases.monthly(figmaRow) == 12)
        let notionRow = try #require(list.first { $0.merchant == "Notion" })
        #expect(notionRow.period == .month)
        #expect(same(notionRow.renews, Self.day(2026, 11, 3)))
        let linear = try #require(list.first { $0.merchant == "Linear" })
        #expect(linear.canceled)
        #expect(same(linear.ends, Self.day(2026, 10, 22)))
        #expect(same(list.first { $0.merchant == "Headspace" }?.renews, Self.day(2026, 11, 5)))
    }

    @Test func aRenewalSaidInThePastRollsForward() throws {
        // Charged Sep 25 and said to renew Oct 3, a day now gone: a month on.
        var p = try #require(notion(at: Self.day(2026, 9, 25, hour: 9)))
        p.renews = Self.day(2026, 10, 3)
        let list = MailPurchases.subscriptions([p], now: Self.now)
        #expect(same(list.first?.renews, Self.day(2026, 11, 3)))
    }

    @Test func ordersOnTheWay() throws {
        let confirmed = try #require(read("Apple Store <noreply@email.apple.com>", "Thank you for your order", """
        Thank you for your order.
        Order Number: W1234567890
        AirPods Pro 3
        Qty 1
        Total $249.00
        """, at: Self.day(2026, 10, 18, hour: 9)))
        #expect(confirmed.shipping == .ordered)
        let shipped = try #require(appleShipped(at: Self.day(2026, 10, 20, hour: 15)))
        let out = try #require(uspsOut(at: Self.day(2026, 10, 21, hour: 7)))
        let delivered = try #require(fedexDelivered(at: Self.day(2026, 10, 20, hour: 14)))
        let deliveredLong = try #require(fedexDelivered(at: Self.day(2026, 10, 14, hour: 14)).map { p -> MailPurchase in
            var p = p
            p.tracking = "748900000001"
            return p
        })
        let old = try #require(read("Amazon.com <auto-confirm@amazon.com>", "Your Amazon.com order of \"Lamp\"",
                                    "Thanks for your order\nOrder #112-0000000-0000001\nOrder Total: $19.98",
                                    at: Self.day(2026, 9, 10)))

        let list = MailPurchases.onTheWay([confirmed, shipped, out, delivered, deliveredLong, old], now: Self.now)
        #expect(list.count == 3)
        let apple = try #require(list.first { $0.order == "W1234567890" })
        #expect(apple.shipping == .shipped)
        #expect(apple.title == "AirPods Pro 3")
        #expect(apple.amount == 249)
        #expect(apple.tracking == "1Z999AA10123456784")
        #expect(list.contains { $0.shipping == .outForDelivery })
        #expect(list.contains { $0.shipping == .delivered && $0.tracking == "748912345678" })
    }

    @Test func monthlyAmounts() {
        var p = MailPurchase(kind: .subscription, message: "m", thread: "t", date: Self.now, merchant: "X", title: "X", amount: 120, currency: "USD")
        p.period = .year
        #expect(MailPurchases.monthly(p) == 10)
        p.period = .month
        #expect(MailPurchases.monthly(p) == 120)
        p.amount = nil
        #expect(MailPurchases.monthly(p) == nil)
    }

    @Test func datesInWords() {
        let base = Self.day(2026, 10, 20, hour: 9)
        #expect(same(MailPurchases.date(in: "next billing date: Nov 22, 2026", base: base), Self.day(2026, 11, 22)))
        #expect(same(MailPurchases.date(in: "arriving Friday", base: base), Self.day(2026, 10, 23)))
        #expect(same(MailPurchases.date(in: "by 8 PM today", base: base), Self.day(2026, 10, 20)))
        #expect(same(MailPurchases.date(in: "until 5 January", base: base), Self.day(2027, 1, 5)))
        #expect(same(MailPurchases.date(in: "am 01.11.2026", base: base), Self.day(2026, 11, 1)))
        #expect(same(MailPurchases.date(in: "2026-12-24", base: base), Self.day(2026, 12, 24)))
    }
}
