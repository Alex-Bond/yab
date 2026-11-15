import Foundation

// Purchases read out of mail kept on this Mac: a subscription's receipt or
// renewal notice, an order and its shipping mail, a plain receipt. They feed
// the Purchases place (subscriptions with a monthly total, orders on the
// way, receipts) and Now's "Figma renews tomorrow". Rules alone, no model:
// read off the main thread over a few thousand messages, so every pattern
// is compiled once. Strict on the way in: only robots' mail counts, and a
// promotion without a charge in it is never a purchase.

public struct MailPurchase: Equatable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case subscription, order, receipt }
    public enum Period: String, Codable, Sendable { case week, month, year }
    public enum Shipping: String, Codable, Sendable { case ordered, shipped, outForDelivery, delivered }
    public var kind: Kind
    /// The mail it was read from (MailMessage.id), and its thread.
    public var message: String
    public var thread: String
    /// The mail's date.
    public var date: Date
    /// As a list shows it: "Figma", "Anthropic", "Apple".
    public var merchant: String
    /// The merchant's own domain, "figma.com"; never a payment processor's.
    public var host: String?
    /// What was bought: "Figma Professional", "AirPods Pro 3", or the
    /// merchant when the mail says nothing better.
    public var title: String
    public var amount: Double?
    /// ISO code: "USD", "EUR", "RUB".
    public var currency: String?
    public var period: Period?
    /// The card's last four digits, and its brand ("Visa", "Apple Pay").
    public var card: String?
    public var brand: String?
    /// The next charge, when the mail says it.
    public var renews: Date?
    /// Access until, for a canceled plan.
    public var ends: Date?
    public var canceled: Bool
    public var order: String?
    public var tracking: String?
    public var carrier: String?
    public var shipping: Shipping?
    /// Expected delivery, when the mail says it.
    public var arrives: Date?

    public init(kind: Kind, message: String, thread: String, date: Date, merchant: String, host: String? = nil, title: String,
                amount: Double? = nil, currency: String? = nil, period: Period? = nil, card: String? = nil, brand: String? = nil,
                renews: Date? = nil, ends: Date? = nil, canceled: Bool = false, order: String? = nil, tracking: String? = nil,
                carrier: String? = nil, shipping: Shipping? = nil, arrives: Date? = nil) {
        self.kind = kind
        self.message = message
        self.thread = thread
        self.date = date
        self.merchant = merchant
        self.host = host
        self.title = title
        self.amount = amount
        self.currency = currency
        self.period = period
        self.card = card
        self.brand = brand
        self.renews = renews
        self.ends = ends
        self.canceled = canceled
        self.order = order
        self.tracking = tracking
        self.carrier = carrier
        self.shipping = shipping
        self.arrives = arrives
    }
}

public enum MailPurchases {
    // MARK: - one mail

    /// One mail read as a purchase, or nil. Its words are its plain body,
    /// else its HTML as text, else its snippet: old mail has only that.
    public static func read(_ message: MailMessage, now: Date) -> MailPurchase? {
        if !message.labels.isDisjoint(with: ["SENT", "SPAM", "TRASH", "DRAFT"]) { return nil }
        if MailSense.kind(message, bulk: message.listUnsubscribe) == .code { return nil }
        guard robot(message) else { return nil }
        // Only then its HTML made text: a person's mail is never read.
        let body = message.text ?? message.html.map(HTMLText.plain) ?? message.snippet
        let text = message.subject + "\n" + body

        // The carrier is often named only by who sent it: "FedEx <TrackingUpdates@fedex.com>".
        let tracked = tracking(in: message.from.name + " " + message.from.address + "\n" + text)
        let status = shipping(in: text, subject: message.subject)
        let receipted = has(receiptWords, text)
        let charged = has(chargeWords, text)
        // "Save 50% on your subscription" sells; it charges nothing.
        if has(promoWords, text), !charged, tracked == nil, status == nil { return nil }

        let money = amount(in: text)
        let renewing = has(renewWords, text)
        let canceled = has(canceledWords, text)
        let number = orderNumber(in: text)
        let kind: MailPurchase.Kind
        var shipped: MailPurchase.Shipping?
        if status != nil || tracked != nil {
            kind = .order
            shipped = status ?? .shipped
        } else if has(subscriptionWords, text), receipted || renewing || canceled {
            kind = .subscription
        } else if has(orderWords, text), money != nil || number != nil {
            kind = .order
            shipped = .ordered
        } else if receipted, money != nil {
            kind = .receipt
        } else {
            return nil
        }

        let (merchant, host, appTitle) = seller(message, text: text, body: body, kind: kind)
        var purchase = MailPurchase(kind: kind, message: message.id, thread: message.thread, date: message.date,
                                    merchant: merchant, host: host, title: merchant)
        purchase.title = appTitle ?? title(message, body: body, merchant: merchant, kind: kind) ?? merchant
        if let money {
            purchase.amount = money.value
            purchase.currency = money.currency
        }
        if let paid = card(in: text) {
            purchase.card = paid.last4
            purchase.brand = paid.brand
        }
        if purchase.brand == nil, let wallet = first(walletWords, text) {
            purchase.brand = wallets[wallet.lowercased()] ?? wallet
        }
        switch kind {
        case .subscription:
            purchase.period = period(in: text)
            purchase.canceled = canceled
            if canceled {
                purchase.ends = date(after: endWords, in: text, base: message.date)
            } else {
                purchase.renews = date(after: renewWords, in: text, base: message.date)
            }
        case .order:
            purchase.order = number
            purchase.tracking = tracked?.number
            purchase.carrier = tracked?.carrier ?? first(carrierNames, text)
            purchase.shipping = shipped
            if shipped != .delivered { purchase.arrives = date(after: arriveWords, in: text, base: message.date) }
        case .receipt:
            purchase.order = number
        }
        _ = now
        return purchase
    }

    /// Mail no person writes: a no-reply, billing or orders box, or a
    /// list. A reply or a forward is a conversation, and free mail is a
    /// person's, list or not. The sense rules' invoice alone isn't enough:
    /// a person's "thanks for the receipt" reads as one.
    static func robot(_ message: MailMessage) -> Bool {
        let subject = message.subject.lowercased()
        if ["re:", "fwd:", "fw:", "aw:", "wg:"].contains(where: subject.hasPrefix) { return false }
        let address = message.from.address.lowercased()
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if freeMail.contains(parts[1]) { return false }
        if message.listUnsubscribe { return true }
        if MailSense.automated(address, conversation: false) { return true }
        let local = parts[0].filter { $0.isLetter }
        return robotBoxes.contains { local.contains($0) }
    }

    private static let freeMail: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com",
                                                "hotmail.com", "live.com", "yahoo.com", "aol.com", "proton.me", "protonmail.com",
                                                "yandex.ru", "ya.ru", "mail.ru", "gmx.de", "gmx.net", "web.de", "fastmail.com"]
    private static let robotBoxes = ["noreply", "donotreply", "receipt", "billing", "order", "invoice", "payment", "purchase",
                                     "shipment", "shipping", "tracking", "confirm", "store", "subscription", "renewal", "autoreply", "team", "hello"]

    // MARK: - words

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func first(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return group(match, match.numberOfRanges > 1 ? 1 : 0, text)
    }

    private static func group(_ match: NSTextCheckingResult, _ n: Int, _ text: String) -> String? {
        guard n < match.numberOfRanges, let range = Range(match.range(at: n), in: text) else { return nil }
        return String(text[range])
    }

    private static let receiptWords = re(
        #"\b(receipts?|invoices?|paid|charged|purchased?|payment (received|confirmation|successful|processed)|order confirmation|thanks? (you )?for (your )?(order|purchase|payment)|чек\w*|квитанци\w*|оплат\w*|счет|счёт|rechnung\w*|zahlung\w*|quittung|beleg)\b"#)
    private static let chargeWords = re(
        #"\b(receipts?|invoices?|charged|amount paid|you paid|payment (received|confirmation|successful|processed)|order confirmation|thanks? (you )?for (your )?(order|purchase)|чек|оплачен\w*|списан\w*|rechnung\w*|zahlungsbest\w*)\b"#)
    private static let promoWords = re(
        #"(\d+\s?% off|[$€£]\s?\d+ off|\bsave\b|\bdeals?\b|\bsale\b|\bdiscount\w*|\bcoupon\w*|\bpromo\b|limited time|special offer|скидк\w*|распродаж\w*|\brabatt\w*|\bangebot\w*)"#)
    private static let subscriptionWords = re(
        #"\b(subscri\w+|renews?|renewed|renewal|renewing|auto-renew\w*|plan|membership|monthly|annual|annually|yearly|billed (monthly|annually|yearly|every)|next (billing|payment|charge)|подписк\w*|продлен\w*|продлён\w*|ежемесячн\w*|abonnement\w*|abo|mitgliedschaft|monatlich|jährlich)\b"#)
    private static let renewWords = re(
        #"(\bauto-renews?( on)?|\brenews?( on)?|\brenewal date|\bwill renew( on)?|\bnext (billing|payment|charge)( date)?|\bwill be (charged|billed)( on)?|продлится|продлена до|продлён до|следующ\w* (списани\w*|плат[её]ж\w*)|verlängert sich( am)?|nächste zahlung)"#)
    private static let canceledWords = re(
        #"\b(cancell?ed|has ended|been terminated|отмен[её]н\w*|отключен\w*|gekündigt|storniert)\b"#)
    private static let endWords = re(
        #"(\baccess until|\bactive until|\bavailable until|\buntil|\bends? on|\bwill end( on)?|\bexpires?( on)?|доступ\w* до|действует до|\bbis( zum)?)"#)
    private static let arriveWords = re(
        #"(\barriving|\barrives?|\bestimated delivery( date)?|\bexpected delivery( date)?|\bdelivery (by|date|estimate)|\bdeliver(ed)? by|\bwill be delivered|\bget it by|ожидаемая дата доставки|доставим|voraussichtliche zustellung)"#)
    private static let orderWords = re(
        #"(\border confirmation|\bthanks? (you )?for (your )?order|\byour order|\border\s*(#|number|no\.?)|\bordered:|заказ\w*|\bbestellung\w*|bestellbestätigung)"#)
    private static let walletWords = re(#"\b(apple pay|google pay|paypal|shop pay|amazon pay)\b"#)
    private static let wallets = ["apple pay": "Apple Pay", "google pay": "Google Pay", "paypal": "PayPal",
                                  "shop pay": "Shop Pay", "amazon pay": "Amazon Pay"]
    private static let carrierNames = re(#"\b(UPS|USPS|FedEx|DHL|Royal Mail|Canada Post|OnTrac|DPD|GLS|Hermes|СДЭК|Почта России)\b"#, [])

    // MARK: - shipping

    private static let deliveredWords = re(
        #"((has|have|was|were|got|successfully) been delivered|\b(was|were) delivered|^delivered\b|\bdelivered:|\bdelivered today\b|доставлен\w*|zugestellt)"#,
        [.caseInsensitive, .anchorsMatchLines])
    private static let deliveredSubject = re(#"(?<!be )\bdelivered\b"#)
    private static let outWords = re(#"(\bout for delivery\b|передан\w* курьеру|in zustellung)"#)
    private static let shippedWords = re(
        #"(\b(has|have|was|were) shipped\b|\bshipped\b|\bon (its|it's|the|their) way\b|\bin transit\b|\btracking (number|#|no|id)|\btrack (your|my) (package|order|shipment)|отправлен\w*|в пути|versandt|unterwegs)"#)

    /// How far an order got, by its words; nil when none say it.
    static func shipping(in text: String, subject: String) -> MailPurchase.Shipping? {
        if has(deliveredWords, text) || has(deliveredSubject, subject) { return .delivered }
        if has(outWords, text) { return .outForDelivery }
        if has(shippedWords, text) { return .shipped }
        return nil
    }

    private static let orderNumberRe = re(
        #"(?:\border|заказ\w*|bestellung)\s*(?:number|no\.?|nummer|id|#|№)?\s*[:#№]?\s*#?\s*([A-Z0-9][A-Z0-9-]{4,})"#)

    static func orderNumber(in text: String) -> String? {
        for match in orderNumberRe.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let number = group(match, 1, text), number.contains(where: \.isNumber) { return number }
        }
        return nil
    }

    // MARK: - amounts

    private static let symbols: [String: String] = ["$": "USD", "us$": "USD", "ca$": "CAD", "c$": "CAD", "a$": "AUD", "€": "EUR",
                                                    "£": "GBP", "¥": "JPY", "₽": "RUB", "₹": "INR", "руб": "RUB", "руб.": "RUB", "р.": "RUB"]
    private static let codes = "USD|EUR|GBP|JPY|RUB|CAD|AUD|CHF|INR|CNY|SEK|NOK|DKK|PLN|BRL|MXN|KZT|UAH|TRY|NZD|SGD|HKD"
    private static let number = #"(\d{1,3}(?:[,.  ]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![\d])"#
    private static let symbolFirst = re(#"(US\$|CA\$|C\$|A\$|[$€£¥₽₹])\s?"# + number)
    private static let symbolAfter = re(#"(?<![\d.,])"# + number + #"\s?([€£¥₽]|руб\.?|р\.)"#)
    private static let codeFirst = re(#"\b("# + codes + #")\s?"# + number, [])
    private static let codeAfter = re(#"(?<![\d.,])"# + number + #"\s?("# + codes + #")\b"#, [])
    /// Words a total stands after, strongest first.
    private static let totals: [NSRegularExpression] = [
        re(#"(amount paid|total charged|amount charged|grand total|order total|total paid|you paid|итого|к оплате|gesamtbetrag|rechnungsbetrag)"#),
        re(#"((?<!sub)total|сумма|gesamt|summe|betrag)"#),
        re(#"(amount|charged|paid|price|оплачено|списано)"#),
    ]

    private struct Money { var value: Double; var currency: String; var range: NSRange }

    private static func amounts(in text: String) -> [Money] {
        let all = NSRange(text.startIndex..., in: text)
        var out: [Money] = []
        for (regex, markFirst) in [(symbolFirst, true), (symbolAfter, false), (codeFirst, true), (codeAfter, false)] {
            for match in regex.matches(in: text, range: all) {
                guard let a = group(match, 1, text), let b = group(match, 2, text) else { continue }
                let (mark, digits) = markFirst ? (a, b) : (b, a)
                guard let worth = value(digits), worth > 0 else { continue }
                let code = symbols[mark.lowercased()] ?? mark.uppercased()
                // One amount found by two patterns ("$15 USD") counts once.
                if out.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { continue }
                out.append(Money(value: worth, currency: code, range: match.range))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The amount charged: the one after "Total" or "Amount paid", else
    /// the largest one named.
    public static func amount(in text: String) -> (value: Double, currency: String)? {
        let found = amounts(in: text)
        guard !found.isEmpty else { return nil }
        let all = NSRange(text.startIndex..., in: text)
        for words in totals {
            for match in words.matches(in: text, range: all) {
                let end = match.range.location + match.range.length
                if let money = found.first(where: { $0.range.location >= end && $0.range.location - end <= 40 }) {
                    return (money.value, money.currency)
                }
            }
        }
        let most = found.max { $0.value < $1.value }!
        return (most.value, most.currency)
    }

    /// "1,240.00", "1.240,00", "9,99", "1 299": the last separator is the
    /// decimal one when two kinds are written, else one followed by one or
    /// two digits is.
    static func value(_ digits: String) -> Double? {
        var text = digits.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        let commas = text.filter { $0 == "," }.count, dots = text.filter { $0 == "." }.count
        if commas > 0, dots > 0 {
            let decimal: Character = text.lastIndex(of: ",")! > text.lastIndex(of: ".")! ? "," : "."
            text = String(text.filter { $0 != (decimal == "," ? "." : ",") }).replacingOccurrences(of: ",", with: ".")
        } else if commas + dots > 0 {
            let separator: Character = commas > 0 ? "," : "."
            let after = text.count - 1 - text.distance(from: text.startIndex, to: text.lastIndex(of: separator)!)
            if commas + dots == 1, after <= 2 {
                text = text.replacingOccurrences(of: ",", with: ".")
            } else {
                text = String(text.filter { $0 != separator })
            }
        }
        return Double(text)
    }

    // MARK: - tracking

    private static let ups = re(#"\b(1Z[0-9A-Z]{16})\b"#)
    private static let usps = re(#"(?<![\d])(9[2345](?:\s?\d){18,20})(?![\d])"#)
    private static let fedex = re(#"(?<![\d])(\d{15}|\d{12})(?![\d])"#)
    private static let dhl = re(#"(?<![\d])(\d{10})(?![\d])"#)
    private static let trackWords = re(#"(tracking|track|sendungsnummer|отслеживани\w*|трек|waybill)"#)

    /// A tracking number and its carrier: UPS's 1Z, USPS's 20 to 22
    /// digits, FedEx's 12 or 15 and DHL's 10 when the mail names them.
    /// A carrier named in the mail wins over a guess by format, except
    /// for UPS's own 1Z.
    public static func tracking(in text: String) -> (number: String, carrier: String)? {
        let all = NSRange(text.startIndex..., in: text)
        if let match = ups.firstMatch(in: text, range: all), let number = group(match, 1, text) {
            return (number.uppercased(), "UPS")
        }
        let named = Set(carrierNames.matches(in: text, range: all).compactMap { group($0, 1, text) })
        let near = trackWords.matches(in: text, range: all).map { $0.range.location + $0.range.length }
        func pick(_ regex: NSRegularExpression) -> String? {
            let found = regex.matches(in: text, range: all)
            let close = found.first { match in near.contains { match.range.location >= $0 && match.range.location - $0 <= 60 } }
            return (close ?? found.first).flatMap { group($0, 1, text) }?.filter(\.isNumber)
        }
        if let number = pick(usps), (20...22).contains(number.count) {
            return (number, named.count == 1 ? named.first! : "USPS")
        }
        let lower = text.lowercased()
        if lower.contains("fedex"), let number = pick(fedex) { return (number, "FedEx") }
        if lower.contains("dhl"), let number = pick(dhl) { return (number, "DHL") }
        return nil
    }

    // MARK: - cards

    private static let brandFirst = re(
        #"\b(visa|mastercard|master card|amex|american express|discover|maestro|jcb|unionpay|mir|мир)\b[^\d\n]{0,25}?(?<!\d)(\d{4})(?!\d)"#)
    private static let lastFour = re(
        #"(?:ending in|ending with|ends in|ending|card|карт[аы]|karte)\s*(?:number\s*)?[:#]?\s*[•*·x.]*\s*(?<!\d)(\d{4})(?!\d)|(?:[•*]{2,}|x{4})\s?(\d{4})(?!\d)"#)
    private static let brandWords = re(#"\b(visa|mastercard|master card|amex|american express|discover|maestro|jcb|unionpay|mir|мир)\b"#)
    private static let brands = ["visa": "Visa", "mastercard": "Mastercard", "master card": "Mastercard", "amex": "Amex",
                                 "american express": "Amex", "discover": "Discover", "maestro": "Maestro", "jcb": "JCB",
                                 "unionpay": "UnionPay", "mir": "Mir", "мир": "Mir"]

    /// The card charged: its last four digits, and its brand when named.
    public static func card(in text: String) -> (last4: String, brand: String?)? {
        let all = NSRange(text.startIndex..., in: text)
        if let match = brandFirst.firstMatch(in: text, range: all), let brand = group(match, 1, text), let digits = group(match, 2, text) {
            return (digits, brands[brand.lowercased()])
        }
        guard let match = lastFour.firstMatch(in: text, range: all) else { return nil }
        guard let digits = group(match, 1, text) ?? group(match, 2, text) else { return nil }
        // A brand named just before it: "Visa card ending in 4411".
        let start = max(0, match.range.location - 30)
        let before = NSRange(location: start, length: match.range.location - start)
        let brand = brandWords.firstMatch(in: text, range: before).flatMap { group($0, 1, text) }
        return (digits, brand.flatMap { brands[$0.lowercased()] })
    }

    // MARK: - periods

    private static let yearly = re(
        #"(\byearly\b|\bannual(ly)?\b|/\s?(yr|year)\b|\bper year\b|\ba year\b|\b1 year\b|\b12 months\b|\(year\)|в год|годов\w*|\bгод\b|jährlich|pro jahr)"#)
    private static let monthlyRe = re(
        #"(\bmonthly\b|/\s?(mo|month)\b|\bper month\b|\ba month\b|\b1 month\b|\bevery month\b|в месяц|ежемесячн\w*|\bмесяц\w*|monatlich|pro monat)"#)
    private static let weekly = re(#"(\bweekly\b|/\s?(wk|week)\b|\bper week\b|\bevery week\b|в неделю|wöchentlich)"#)

    static func period(in text: String) -> MailPurchase.Period? {
        if has(yearly, text) { return .year }
        if has(monthlyRe, text) { return .month }
        if has(weekly, text) { return .week }
        return nil
    }

    // MARK: - who sold it

    private static let processors: Set<String> = ["stripe.com", "paddle.com", "paddle.net", "paypal.com", "fastspring.com",
                                                  "chargebee.com", "recurly.com", "gumroad.com", "lemonsqueezy.com",
                                                  "braintreepayments.com", "2checkout.com", "squareup.com"]
    private static let processorNames: Set<String> = ["stripe", "paddle", "paypal", "fastspring", "chargebee", "recurly",
                                                      "gumroad", "lemon squeezy", "braintree", "square"]
    private static let known = ["makenotion": "Notion", "usps": "USPS", "ups": "UPS", "dhl": "DHL", "fedex": "FedEx",
                                "hbomax": "HBO Max", "youtube": "YouTube", "linkedin": "LinkedIn", "github": "GitHub", "openai": "OpenAI"]
    private static let fromSubject = re(
        #"(?:receipt|invoice|payment|purchase|order|subscription|чек|счет|счёт|rechnung)\s+(?:from|for|to|with|от|von)\s+(.+?)(?:\s*[#№(\[]|\s+[-|:]\s|[.!\n]|$)"#)
    private static let fromBody = re(
        #"(?:receipt|invoice|payment|purchase)\s+(?:from|to)\s+([A-Z][\w&.,' -]{1,40}?)(?:\s*[#№(\[]|\s+[-|:]\s|[.!\n]|$)"#)
    private static let noise = re(
        #"\b(receipts?|billing|team|no-?reply|noreply|via \w+|inc|llc|ltd|pbc|gmbh|corp|co|payments?|notifications?|support|orders?|store|customer service|subscriptions?|accounts?|online services)\b\.?"#)
    private static let links = re(#"(?:https?://|\bwww\.)([a-z0-9.-]+\.[a-z]{2,})"#)

    /// Who sold it, their domain, and for an App Store receipt what was
    /// bought: the app's name stands for the merchant there, not Apple.
    static func seller(_ message: MailMessage, text: String, body: String, kind: MailPurchase.Kind) -> (String, String?, String?) {
        let domain = message.from.address.split(separator: "@").last.map { registrable(String($0)) } ?? ""
        let name = message.from.name
        if domain == "apple.com", kind == .subscription || name.lowercased().contains("app store") || body.contains("App Store"),
           let found = appStore(body) {
            return (found.app, nil, found.item)
        }
        if processors.contains(domain) || name.range(of: #"\bvia (stripe|paddle|paypal)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let said = first(fromSubject, message.subject).map(clean)
                ?? (processorNames.contains(clean(name).lowercased()) ? nil : nonEmpty(clean(name)))
                ?? first(fromBody, body).map(clean)
            guard let merchant = said.flatMap(nonEmpty) else {
                return (brand(domain), nil, nil)
            }
            return (merchant, link(matching: merchant, in: text), nil)
        }
        // A carrier's mail about someone's parcel: "Your package from Apple".
        if ["ups.com", "usps.com", "fedex.com", "dhl.com", "dhl.de"].contains(domain),
           let shop = text.range(of: #"(?<=(package|shipment|order|parcel|delivery) from )[A-Z][\w&.'-]+( [A-Z][\w&.'-]+)?"#, options: .regularExpression) {
            return (String(text[shop]), nil, nil)
        }
        let merchant = nonEmpty(clean(name)).flatMap { processorNames.contains($0.lowercased()) ? nil : $0 } ?? brand(domain)
        return (merchant, domain.isEmpty ? nil : domain, nil)
    }

    /// A display name without the words round a brand: "Figma Billing",
    /// "Anthropic, PBC", "Amazon.com".
    static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: #"\.(com|io|ai|app|co|net|org)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = noise.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-|:;\"'").union(.whitespacesAndNewlines))
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// "figma.com" as a name: "Figma".
    static func brand(_ domain: String) -> String {
        guard let head = domain.split(separator: ".").first.map(String.init), !head.isEmpty else { return domain }
        return known[head] ?? head.prefix(1).uppercased() + head.dropFirst()
    }

    /// The domain a site goes by: "figma.com" for "email.figma.com",
    /// "amazon.co.uk" for "a.amazon.co.uk".
    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let n = labels.count
        if labels[n - 1].count == 2, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(labels[n - 2]) {
            return labels[(n - 3)...].joined(separator: ".")
        }
        return labels[(n - 2)...].joined(separator: ".")
    }

    /// A link's domain that carries the merchant's name: a processor's
    /// receipt names the shop's own site somewhere.
    private static func link(matching merchant: String, in text: String) -> String? {
        let key = merchant.lowercased().filter { $0.isLetter || $0.isNumber }
        guard key.count >= 3 else { return nil }
        for match in links.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let host = group(match, 1, text) else { continue }
            let domain = registrable(host)
            if processors.contains(domain) { continue }
            let head = domain.split(separator: ".").first.map(String.init) ?? ""
            if head.contains(key) || key.contains(head) && head.count >= 3 { return domain }
        }
        return nil
    }

    private static let appPeriod = re(#"\s*\((monthly|yearly|annual|weekly|1 month|1 year|\d+ (months?|years?|weeks?))\)"#)
    private static let appHeader = re(#"(app store|apple account|apple id|order id|document|receipt|billed|subtotal|total|tax|date|renews)"#)

    /// An App Store receipt's app and subscription: the line saying
    /// "(Monthly)" and the app's name above it.
    private static func appStore(_ body: String) -> (app: String, item: String)? {
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (n, line) in lines.enumerated() {
            let all = NSRange(line.startIndex..., in: line)
            let periodic = appPeriod.firstMatch(in: line, range: all) != nil
            let renewsNext = n + 1 < lines.count && lines[n + 1].lowercased().hasPrefix("renews")
            guard periodic || renewsNext, !has(appHeader, line) else { continue }
            let item = appPeriod.stringByReplacingMatches(in: line, range: all, withTemplate: "").trimmingCharacters(in: .whitespaces)
            var app = item
            if n > 0, !has(appHeader, lines[n - 1]), !lines[n - 1].contains(":"), !lines[n - 1].contains("@") { app = lines[n - 1] }
            return (app, item)
        }
        return nil
    }

    // MARK: - what was bought

    private static let planName = re(
        #"((?:[A-Z0-9][\w+&.'’-]*[ \t]+){0,3}[A-Z0-9][\w+&.'’-]*)[ \t]+(?:[Pp]lan|[Ss]ubscription|[Mm]embership|[Tt]ier)\b"#, [])
    private static let lead: Set<String> = ["your", "the", "our", "this", "thanks", "thank", "welcome", "for", "to", "of", "a", "an",
                                            "you", "we", "monthly", "annual", "yearly", "new", "current", "active"]
    private static let yourThing = re(
        #"\b[Yy]our ((?:[A-Z0-9][\w+&.'-]*[ \t]){0,3}[A-Z0-9][\w+&.'-]*) (?:receipt|invoice|payment|order|membership|subscription)\b"#, [])
    private static let quoted = re(#"["“„]([^"”“]{2,80})["”“]"#)
    private static let orderOf = re(#"(?:order of|ordered:|purchase of|you bought)\s+(.{2,60}?)(?:\s+(?:has|have|is|was|and)\b|[.\n]|$)"#)
    private static let qtyLine = re(#"^(qty|quantity|кол-во|menge)\b"#)
    private static let qtyInline = re(#"^(.{2,60}?)\s+(?:×|x|qty:?|quantity:?)\s*\d+\b"#)

    static func title(_ message: MailMessage, body: String, merchant: String, kind: MailPurchase.Kind) -> String? {
        let text = message.subject + "\n" + body
        if kind == .subscription {
            for match in planName.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard var words = group(match, 1, text)?.split(separator: " ").map(String.init) else { continue }
                while let head = words.first, lead.contains(head.lowercased()) { words.removeFirst() }
                guard !words.isEmpty, words.contains(where: { $0.contains(where: \.isLetter) }) else { continue }
                let name = words.joined(separator: " ")
                // A tier alone says little: "Professional" is "Figma Professional".
                if words.count == 1, !name.lowercased().contains(merchant.lowercased()) { return merchant + " " + name }
                return name
            }
        }
        if let said = first(quoted, message.subject).map(trimmed), !said.isEmpty { return said }
        if let said = first(orderOf, message.subject).map(trimmed), !said.isEmpty { return said }
        // "Your Spotify Premium receipt": more than the merchant alone.
        if let said = first(yourThing, message.subject).map(trimmed), !said.isEmpty, clean(said).lowercased() != merchant.lowercased() {
            return said
        }
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (n, line) in lines.enumerated() {
            if n > 0, has(qtyLine, line) {
                let item = trimmed(lines[n - 1])
                if !item.isEmpty, !item.contains(":") { return item }
            }
            if let match = qtyInline.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let item = group(match, 1, line).map(trimmed), !item.isEmpty, !item.contains(":") { return item }
        }
        return nil
    }

    /// A title without the amount beside it and the marks round it.
    private static func trimmed(_ text: String) -> String {
        var text = text
        for regex in [symbolFirst, symbolAfter, codeFirst, codeAfter] {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-|:;\"'“”").union(.whitespacesAndNewlines)).prefix(80))
    }

    // MARK: - dates

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()
    private static let monthDay = re(
        #"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?!\d)(?:,?\s+(\d{4}))?"#)
    private static let dayMonth = re(
        #"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\.?\s+(?:of\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec|январ[яь]|феврал[яь]|марта?|апрел[яь]|ма[яй]|июн[яь]|июл[яь]|августа?|сентябр[яь]|октябр[яь]|ноябр[яь]|декабр[яь]|januar|februar|märz|maerz|mai|juni|juli|oktober|dezember)\b\.?(?:\s+(\d{4}))?"#)
    private static let iso = re(#"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    private static let slashed = re(#"(?<![\d/])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?![\d/])"#)
    private static let dotted = re(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4})(?!\d)"#)
    private static let relative = re(#"\b(today|tomorrow|tonight|сегодня|завтра|heute|morgen)\b"#)
    private static let weekday = re(#"\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#)

    private static func month(_ word: String) -> Int? {
        let word = word.lowercased()
        let russian = ["январ": 1, "феврал": 2, "март": 3, "апрел": 4, "мая": 5, "май": 5, "июн": 6, "июл": 7, "август": 8,
                       "сентябр": 9, "октябр": 10, "ноябр": 11, "декабр": 12]
        if let hit = russian.first(where: { word.hasPrefix($0.key) }) { return hit.value }
        let german = ["mai": 5, "juni": 6, "juli": 7, "märz": 3, "maerz": 3, "oktober": 10, "dezember": 12, "januar": 1, "februar": 2]
        if let hit = german[word] { return hit }
        let english = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return english.firstIndex(of: String(word.prefix(3))).map { $0 + 1 }
    }

    /// The first date named in the words just after one of `words`: "renews
    /// on November 5", "access until Oct 22", "arriving Friday".
    private static func date(after words: NSRegularExpression, in text: String, base: Date) -> Date? {
        for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let start = Range(match.range, in: text)?.upperBound else { continue }
            let window = String(text[start...].prefix(60))
            if let found = date(in: window, base: base) { return found }
        }
        return nil
    }

    /// The first date in some words, the day it starts. A month and day
    /// without a year is the next such day on or after `base`; a weekday
    /// is the next one on or after it.
    static func date(in text: String, base: Date) -> Date? {
        let all = NSRange(text.startIndex..., in: text)
        let today = calendar.startOfDay(for: base)
        var found: [(Int, Date)] = []
        func day(_ year: Int?, _ month: Int?, _ day: Int?) -> Date? {
            guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
            var parts = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: day)
            guard var date = calendar.date(from: parts) else { return nil }
            if year == nil, date < today {
                parts.year! += 1
                date = calendar.date(from: parts) ?? date
            }
            return date
        }
        for match in monthDay.matches(in: text, range: all) {
            if let at = day(group(match, 3, text).flatMap { Int($0) }, group(match, 1, text).flatMap(month), group(match, 2, text).flatMap { Int($0) }) {
                found.append((match.range.location, at))
            }
        }
        for match in dayMonth.matches(in: text, range: all) {
            if let at = day(group(match, 3, text).flatMap { Int($0) }, group(match, 2, text).flatMap(month), group(match, 1, text).flatMap { Int($0) }) {
                found.append((match.range.location, at))
            }
        }
        for match in iso.matches(in: text, range: all) {
            if let at = day(group(match, 1, text).flatMap { Int($0) }, group(match, 2, text).flatMap { Int($0) }, group(match, 3, text).flatMap { Int($0) }) {
                found.append((match.range.location, at))
            }
        }
        for match in slashed.matches(in: text, range: all) {
            let year = group(match, 3, text).flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
            if let at = day(year, group(match, 1, text).flatMap { Int($0) }, group(match, 2, text).flatMap { Int($0) }) {
                found.append((match.range.location, at))
            }
        }
        for match in dotted.matches(in: text, range: all) {
            if let at = day(group(match, 3, text).flatMap { Int($0) }, group(match, 2, text).flatMap { Int($0) }, group(match, 1, text).flatMap { Int($0) }) {
                found.append((match.range.location, at))
            }
        }
        for match in relative.matches(in: text, range: all) {
            let word = group(match, 1, text)?.lowercased() ?? ""
            let ahead = ["tomorrow", "завтра", "morgen"].contains(word) ? 1 : 0
            if let at = calendar.date(byAdding: .day, value: ahead, to: today) { found.append((match.range.location, at)) }
        }
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for match in weekday.matches(in: text, range: all) {
            guard let word = group(match, 1, text)?.lowercased(), let want = names.firstIndex(of: word) else { continue }
            let now = calendar.component(.weekday, from: today) - 1
            if let at = calendar.date(byAdding: .day, value: (want - now + 7) % 7, to: today) { found.append((match.range.location, at)) }
        }
        return found.min { $0.0 < $1.0 }?.1
    }

    // MARK: - lists

    private static func days(_ period: MailPurchase.Period) -> Double {
        switch period {
        case .week: return 7
        case .month: return 30.44
        case .year: return 365.25
        }
    }

    private static func step(_ period: MailPurchase.Period) -> DateComponents {
        switch period {
        case .week: return DateComponents(day: 7)
        case .month: return DateComponents(month: 1)
        case .year: return DateComponents(year: 1)
        }
    }

    /// Subscriptions: one per merchant (latest wins), period inferred from
    /// words or from the gap between two charges of the same amount (25 to
    /// 35 days is a month, 350 to 380 a year). `renews` filled as last
    /// charge + period when the mail didn't say, rolled forward past `now`.
    /// Canceled ones kept with `ends` while it is ahead. Ones whose last
    /// charge is older than 1.5 periods (and not said to renew) are
    /// dropped; one with no period known is kept for 45 days.
    public static func subscriptions(_ purchases: [MailPurchase], now: Date) -> [MailPurchase] {
        let today = calendar.startOfDay(for: now)
        let groups = Dictionary(grouping: purchases.filter { $0.kind == .subscription }) { ($0.host ?? $0.merchant).lowercased() }
        var out: [MailPurchase] = []
        for (_, group) in groups {
            let sorted = group.sorted { $0.date < $1.date }
            guard var one = sorted.last else { continue }
            let charges = sorted.filter { $0.amount != nil && !$0.canceled }
            if one.amount == nil, let paid = sorted.last(where: { $0.amount != nil }) {
                one.amount = paid.amount
                one.currency = paid.currency
            }
            if one.card == nil, let paid = sorted.last(where: { $0.card != nil }) {
                one.card = paid.card
                one.brand = paid.brand
            }
            if one.title == one.merchant, let named = sorted.last(where: { $0.title != $0.merchant }) { one.title = named.title }
            if one.host == nil { one.host = sorted.last(where: { $0.host != nil })?.host }
            one.period = one.period ?? sorted.last(where: { $0.period != nil })?.period ?? gap(charges)
            let last = charges.last?.date ?? one.date

            if one.canceled {
                one.renews = nil
                if let ends = one.ends {
                    if ends < today { continue }
                } else if now.timeIntervalSince(one.date) > 45 * 86_400 {
                    continue
                }
                out.append(one)
                continue
            }
            let said = one.renews.map { $0 >= today } ?? false
            if let period = one.period {
                if !said, now.timeIntervalSince(last) > 1.5 * days(period) * 86_400 { continue }
                var renews = one.renews ?? calendar.date(byAdding: step(period), to: calendar.startOfDay(for: last))
                while let at = renews, at < today { renews = calendar.date(byAdding: step(period), to: at) }
                one.renews = renews
            } else if !said, now.timeIntervalSince(last) > 45 * 86_400 {
                continue
            }
            out.append(one)
        }
        return out.sorted { ($0.renews ?? $0.ends ?? .distantFuture, $0.merchant) < ($1.renews ?? $1.ends ?? .distantFuture, $1.merchant) }
    }

    /// A period from charges of one amount: the gap between the last two.
    private static func gap(_ charges: [MailPurchase]) -> MailPurchase.Period? {
        guard let last = charges.last, let amount = last.amount else { return nil }
        let same = charges.filter { $0.currency == last.currency && abs(($0.amount ?? 0) - amount) < 0.01 }
        guard same.count >= 2 else { return nil }
        let days = same[same.count - 1].date.timeIntervalSince(same[same.count - 2].date) / 86_400
        switch days {
        case 6...8: return .week
        case 25...35: return .month
        case 350...380: return .year
        default: return nil
        }
    }

    /// Orders not delivered yet, or delivered within the last 2 days; one
    /// per order or tracking number, latest status wins; ones whose last
    /// mail is older than 30 days are dropped. Newest first.
    public static func onTheWay(_ purchases: [MailPurchase], now: Date) -> [MailPurchase] {
        let orders = purchases.filter { $0.kind == .order }
        // A shipping mail naming both numbers joins the order's mail to
        // the carrier's, which names only the tracking.
        var orderOf: [String: String] = [:]
        for one in orders { if let tracking = one.tracking, let order = one.order { orderOf[tracking] = order } }
        let groups = Dictionary(grouping: orders) { one in
            one.order ?? one.tracking.flatMap { orderOf[$0] } ?? one.tracking ?? one.message
        }
        let stage: [MailPurchase.Shipping: Int] = [.ordered: 0, .shipped: 1, .outForDelivery: 2, .delivered: 3]
        var out: [MailPurchase] = []
        for (_, group) in groups {
            let sorted = group.sorted { ($0.date, stage[$0.shipping ?? .ordered]!) < ($1.date, stage[$1.shipping ?? .ordered]!) }
            guard var one = sorted.last else { continue }
            if now.timeIntervalSince(one.date) > 30 * 86_400 { continue }
            if one.shipping == .delivered, now.timeIntervalSince(one.date) > 2 * 86_400 { continue }
            if one.title == one.merchant || one.title == one.carrier,
               let named = sorted.last(where: { $0.title != $0.merchant && $0.title != $0.carrier }) {
                one.title = named.title
                if one.merchant == one.carrier { one.merchant = named.merchant; one.host = named.host }
            }
            one.order = one.order ?? sorted.last(where: { $0.order != nil })?.order
            one.tracking = one.tracking ?? sorted.last(where: { $0.tracking != nil })?.tracking
            one.carrier = one.carrier ?? sorted.last(where: { $0.carrier != nil })?.carrier
            if one.amount == nil, let paid = sorted.last(where: { $0.amount != nil }) {
                one.amount = paid.amount
                one.currency = paid.currency
            }
            if one.shipping != .delivered, one.arrives == nil { one.arrives = sorted.last(where: { $0.arrives != nil })?.arrives }
            if one.shipping == .delivered { one.arrives = nil }
            out.append(one)
        }
        return out.sorted { $0.date > $1.date }
    }

    /// A subscription's price as a monthly amount: a yearly plan's twelfth.
    public static func monthly(_ p: MailPurchase) -> Double? {
        guard let amount = p.amount else { return nil }
        switch p.period {
        case .year: return amount / 12
        case .week: return amount * 52 / 12
        case .month, nil: return amount
        }
    }

    /// An amount in its currency as en_US writes it, without ".00" for a
    /// whole one: "$15", "$15.49", "€9.99", "RUB 299".
    public static func said(_ value: Double, _ currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        if value.rounded() == value { formatter.maximumFractionDigits = 0; formatter.minimumFractionDigits = 0 }
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }
}
