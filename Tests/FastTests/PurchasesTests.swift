import Foundation
import Testing
@testable import Fast
import MailCore

// Purchases: the renewal row in Now, the monthly total, what an agent is
// told, the place's rows and what Do It tells the agent.
@MainActor
@Suite(.serialized)
struct PurchasesTests {
    static let now = ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z")!
    static let day: TimeInterval = 86_400
    /// Tomorrow at nine, wherever the Mac is: within a day and a half.
    static let tomorrow = Calendar.current.date(byAdding: .hour, value: 33, to: Calendar.current.startOfDay(for: now))!

    static func sub(_ merchant: String, host: String, title: String, amount: Double, currency: String = "USD", period: MailPurchase.Period,
                    renews: TimeInterval?, canceled: Bool = false, paid: TimeInterval = -20) -> MailPurchase {
        MailPurchase(kind: .subscription, message: "m-" + merchant, thread: "t-" + merchant, date: now.addingTimeInterval(paid * day),
                     merchant: merchant, host: host, title: title, amount: amount, currency: currency, period: period, card: "4411", brand: "Visa",
                     renews: renews.map { $0 == -1 ? tomorrow : now.addingTimeInterval($0) }, ends: canceled ? now.addingTimeInterval(day) : nil, canceled: canceled)
    }

    static var world: [(purchase: MailPurchase, account: String, opened: Date?)] {
        [(sub("Figma", host: "figma.com", title: "Figma Professional", amount: 180, period: .year, renews: -1, paid: -340),
          "me@x.test", now.addingTimeInterval(-41 * day)),
         (sub("Notion", host: "notion.so", title: "Notion Plus", amount: 10, period: .month, renews: 12 * day),
          "me@x.test", now.addingTimeInterval(-34 * day)),
         (sub("Claude", host: "claude.ai", title: "Claude Max", amount: 100, period: .month, renews: -1),
          "me@x.test", now.addingTimeInterval(-3600)),
         (sub("Spotify", host: "spotify.com", title: "Spotify Premium", amount: 9.99, currency: "EUR", period: .month, renews: 9 * day),
          "me@x.test", now.addingTimeInterval(-2 * day)),
         (MailPurchase(kind: .order, message: "m-airpods", thread: "t-airpods", date: now.addingTimeInterval(-2 * day), merchant: "Apple",
                       host: "apple.com", title: "AirPods Pro 3", amount: 249, currency: "USD", tracking: "1Z999AA10123456784", carrier: "UPS",
                       shipping: .outForDelivery, arrives: now.addingTimeInterval(8 * 3600)), "me@x.test", nil)]
    }

    static func book() -> Purchases {
        let book = Purchases()
        book.testing = world
        book.refresh(force: true, now: now)
        return book
    }

    @Test func aSubscriptionYouDontOpenGetsARowTheDayBefore() {
        let rows = Self.book().rows(now: Self.now)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.title == "Figma renews tomorrow")
        #expect(row.detail == "Figma Professional, $180 a year · not opened in 41 days")
        #expect(row.kind == Noticing.Kind.renewal.rawValue)
        #expect(row.cancel == true)
        #expect(row.url?.host() == "figma.com")
        #expect(row.source == .noticed)
        #expect(row.day == true)
        #expect(HintList.status(row, now: Self.now) == "")
    }

    @Test func nowKeepsTheRenewalRowInItsOrder() {
        let row = Self.book().rows(now: Self.now)[0]
        let mail = Hint(id: "mail.t1", icon: .face, title: "Reply to Anna", detail: "", source: .noticed, kind: Noticing.Kind.mailWaiting.rawValue)
        let order = Hints.order(found: [], noticed: [mail, row], setup: [], now: Self.now)
        #expect(order.map(\.id) == [row.id, mail.id])
    }

    @Test func oneYouUseOrOneFarOffKeepsQuiet() {
        let book = Purchases()
        book.testing = [Self.world[2], Self.world[1]]
        book.refresh(force: true, now: Self.now)
        // Claude renews tomorrow but was opened an hour ago; Notion isn't used, but renews in twelve days.
        #expect(book.rows(now: Self.now).isEmpty)
        book.testing = [(Self.sub("Figma", host: "figma.com", title: "Figma Professional", amount: 180, period: .year, renews: -1, canceled: true), "me@x.test", nil)]
        book.refresh(force: true, now: Self.now)
        #expect(book.rows(now: Self.now).isEmpty)
    }

    @Test func theMonthlyTotalCountsAYearAsItsTwelfthInTheUsualCurrency() {
        let book = Self.book()
        let total = book.monthly
        #expect(total?.currency == "USD")
        #expect(total.map { abs($0.value - 125) < 0.01 } == true)
        #expect(total?.count == 4)
        #expect(book.monthlySaid == "$125 a month")
        #expect(book.orders.map(\.purchase.title) == ["AirPods Pro 3"])
    }

    @Test func anAgentIsToldPricesCardsRenewalsAndUse() {
        let book = Self.book()
        let said = book.describe(kind: "subscriptions", query: "", now: Self.now)
        #expect(said.hasPrefix("4 subscriptions, $125 a month."))
        #expect(said.contains("- Figma (Figma Professional): $180 a year, Visa 4411, renews"))
        #expect(said.contains("site last opened 41 days ago"))
        #expect(said.contains("mail me@x.test|t-Figma"))
        #expect(book.describe(kind: "subscriptions", query: "notion", now: Self.now).components(separatedBy: "\n").count == 1)
        let orders = book.describe(kind: "orders", query: "", now: Self.now)
        #expect(orders.contains("AirPods Pro 3 from Apple: Out for delivery"))
        #expect(orders.contains("UPS 1Z999AA10123456784"))
        #expect(orders.contains("https://www.ups.com/track?tracknum=1Z999AA10123456784"))
        #expect(book.describe(kind: "receipts", query: "nothing like this", now: Self.now) == "No receipts found.")
    }

    @Test func doItStopsARenewalAtTheMerchantsLastButton() {
        let row = Self.book().rows(now: Self.now)[0]
        let words = Browser.doItWords(row, now: Self.now)
        #expect(words.contains("Stop this subscription from renewing: Figma renews tomorrow"))
        #expect(words.contains("stop"))
        #expect(words.contains("https://figma.com"))
        #expect(words.contains("Never pay"))
    }

    @Test func questionsAboutMoneyAndParcelsAreKnown() {
        for yes in ["how much do I spend on subscriptions", "where are my AirPods, the package", "when does Figma renew",
                    "сколько я трачу на подписки", "где моя посылка"] {
            #expect(Purchases.asks(yes), "\(yes)")
        }
        for no in ["what is the capital of Peru", "summarize this page", "tell me about Arc"] {
            #expect(!Purchases.asks(no), "\(no)")
        }
    }

    @Test func carriersHaveTheirOwnTrackingPages() {
        func order(_ carrier: String?) -> MailPurchase {
            MailPurchase(kind: .order, message: "m", thread: "t", date: Self.now, merchant: "Shop", title: "Box", tracking: "9400 1000 0000", carrier: carrier)
        }
        #expect(Purchases.tracking(order("UPS"))?.absoluteString == "https://www.ups.com/track?tracknum=940010000000")
        #expect(Purchases.tracking(order("USPS"))?.host() == "tools.usps.com")
        #expect(Purchases.tracking(order("FedEx"))?.host() == "www.fedex.com")
        #expect(Purchases.tracking(order(nil)) == nil)
    }

    @Test func thePlaceListsSubscriptionsWithTheTotalAndUnusedOnesSaySo() {
        Purchases.shared.testing = Self.world
        defer {
            Purchases.shared.testing = nil
            Browser.placeMemo = nil
        }
        Purchases.shared.refresh(force: true, now: Self.now)
        let id = UUID()
        let browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.place = .purchases
        browser.query.placeFilter = 0
        let items = browser.placeItems
        #expect(items.first?.section == "Subscriptions · $125 a month")
        let figma = items.first { $0.title == "Figma Professional" }
        #expect(figma?.tag == "Unused")
        #expect(figma?.alarm == true)
        #expect(figma?.source.hasPrefix("Not opened in") == true)
        #expect(items.first { $0.title == "Claude Max" }?.tag == nil)
        browser.query.placeFilter = 1
        Browser.placeMemo = nil
        #expect(browser.placeItems.map(\.title) == ["AirPods Pro 3"])
        let actions = browser.placeActions(browser.placeItems[0]).map(\.title)
        #expect(actions.first == "Open UPS Tracking")
        #expect(actions.contains("Show the Mail"))
    }

    /// A mail read once is read again only when more of it came (its words
    /// after its snippet) or it went to the bin; what was read keeps
    /// between launches as it was.
    @Test func aMailIsReadOnceUntilItChanges() throws {
        let from = MailPerson.one("Figma <billing@figma.com>")!
        var mail = MailMessage(id: "m1", thread: "t1", from: from, subject: "Your Figma receipt", snippet: "Total $144",
                               date: Self.now, labels: ["INBOX"])
        let first = Purchases.key(mail, account: "me@x.test")
        #expect(Purchases.key(mail, account: "me@x.test") == first)
        #expect(Purchases.key(mail, account: "other@x.test") != first)
        mail.text = "Thanks for your payment. Total: $144.00"
        let worded = Purchases.key(mail, account: "me@x.test")
        #expect(worded != first)
        mail.labels.insert("TRASH")
        #expect(Purchases.key(mail, account: "me@x.test") != worded)

        var known = Purchases.Known()
        known.found[first] = Self.world[0].purchase
        known.none.insert(worded)
        let back = try JSONDecoder().decode(Purchases.Known.self, from: JSONEncoder().encode(known))
        #expect(back.found == known.found)
        #expect(back.none == known.none)
        #expect(back.build == Purchases.build)
    }

    /// Two accounts of receipts read as refresh reads them, twice: the
    /// first pass reads every mail, the next only what is new. Before,
    /// every pass was the first (A/B in the printed line).
    @Test func theNextPassReadsOnlyNewMail() {
        let since = Self.now.addingTimeInterval(-400 * Self.day)
        var engines: [(String, MailStore)] = []
        for account in ["me@x.test", "work@x.test"] {
            let store = MailStore(file: MailStore.memory)
            _ = store.put((0..<150).map { MailPurchasesSpeedTests.receipt($0, size: 40_000) }.map { mail in
                var mail = mail
                mail.id = account + mail.id
                // Kept mail has its plain words beside the HTML.
                mail.text = HTMLText.plain(mail.html ?? "")
                return mail
            })
            engines.append((account, store))
        }
        let clock = ContinuousClock()
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        var first: (items: [Purchases.Item], kept: Purchases.Known, fresh: Int) = ([], Purchases.Known(), 0)
        let full = ms(clock.measure { first = Purchases.pass(engines, since: since, now: Self.now, before: Purchases.Known()) })
        var second = first
        let next = ms(clock.measure { second = Purchases.pass(engines, since: since, now: Self.now, before: first.kept) })
        print(String(format: "purchases-pass: %d mails, first pass %.0f ms (%d read), next pass %.0f ms (%d read)",
                     first.kept.count, full, first.fresh, next, second.fresh))
        #expect(first.fresh == 300)
        #expect(second.fresh == 0)
        #expect(second.items.map(\.id) == first.items.map(\.id))
        #expect(next < full / 4)
    }
}
