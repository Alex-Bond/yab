import Foundation

/// A one-time code in a mail's or a text's words (MailCodes, MailSense).
public struct MailCodeRead: Equatable, Codable, Sendable {
    public static let defaultLifetime: TimeInterval = 10 * 60
    public enum Purpose: String, Codable, Sendable { case signIn, purchase, confirmEmail, resetPassword, newDevice, other }
    public var code: String
    public var shown: String
    public var purpose: Purpose
    public var amount: String?
    public var merchant: String?
    public var card: String?
    public var expires: Date?
    public var sure: Bool

    public init(code: String, shown: String, purpose: Purpose = .other, amount: String? = nil,
                merchant: String? = nil, card: String? = nil, expires: Date? = nil, sure: Bool = false) {
        self.code = code; self.shown = shown; self.purpose = purpose
        self.amount = amount; self.merchant = merchant; self.card = card; self.expires = expires; self.sure = sure
    }
}

public enum MailCodeWords {

    /// The words sites put near a code, in the languages yab's pages are
    /// read in. Without one of them a number is an order, a price, a year.
    private static let near = try! NSRegularExpression(
        pattern: #"code|codice|código|codigo|one[- ]?time|passcode|код|\botp\b|\bpin\b|認証"#,
        options: [.caseInsensitive]
    )

    private static let lifetime = try! NSRegularExpression(
        pattern: #"(?:expires?|valid)(?:\s+will)?\s+(?:in|for)\s+(\d+\s*(?:minutes?|mins?|min|seconds?|secs?|hours?|days?|минут[а-я]*|分))"#,
        options: [.caseInsensitive]
    )

    /// A code as sites write one: four to eight digits, or two halves.
    private static let digits = try! NSRegularExpression(
        pattern: #"(?<![\w$€£¥#.,:/-])(?<!\d\s)(\d{4,8}|\d{3}[ -]\d{3}|\d{4}[ -]\d{4})(?![\w%:/-])(?![.,]\d)(?!\s?\d)(?!\s?(?:usd|eur|gbp|rub|₽|€|\$))"#,
        options: [.caseInsensitive]
    )

    /// The code in a mail or a text, or nil when there is none: the number
    /// nearest to a word that says it is one.
    private static func number(in text: String) -> String? {
        // Google writes G-123456: the letters are not typed.
        let text = text.replacingOccurrences(of: #"\bG-(\d{6})\b"#, with: " $1", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let whole = NSRange(text.startIndex..., in: text)
        let words = near.matches(in: text, range: whole).map(\.range)
        guard !words.isEmpty else { return nil }
        var best: (code: String, score: Int)?
        for match in digits.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let code = text[range].filter(\.isNumber)
            let at = match.range(at: 1)
            let prefix = (text as NSString).substring(with: NSRange(location: max(0, at.location - 40), length: min(40, at.location)))
            if has(prefix, #"(?:ending\s+(?:in\s+)?|[•*]{2,}|\bx|card\s+)$"#) { continue }
            let distance = words.map { word in
                word.location >= at.location + at.length ? word.location - (at.location + at.length)
                    : at.location >= word.location + word.length ? at.location - (word.location + word.length) : 0
            }.min() ?? .max
            // A year is a code only right after its word: "code: 2024".
            if code.count == 4, let year = Int(code), (1900...2099).contains(year), distance > 3 { continue }
            guard distance <= 80 else { continue }
            // Nearer wins; six digits, the usual code, wins a tie.
            let score = distance * 2 + (code.count == 6 ? 0 : 3)
            if best == nil || score < best!.score { best = (String(code), score) }
        }
        return best?.code
    }

    public static func code(in text: String) -> String? { read(subject: "", text: text)?.code }

    /// `received` anchors a relative lifetime to the message, never to when it was opened.
    public static func read(subject: String, text: String, html: String? = nil, received: Date = Date()) -> MailCodeRead? {
        let html = html.map(visibleHTML)
        let plain = (text.isEmpty ? HTMLText.plain(html ?? "") : text)
            .replacingOccurrences(of: #"(?i)https?://[^\s<>]+"#, with: " ", options: .regularExpression)
        var words = subject + "\n" + plain
        let prominent = html.flatMap(highlighted)
        guard let shown = prominent ?? alphanumeric(words) ?? number(in: words) else { return nil }
        let code = shown.filter { $0.isASCII && $0.isLetter || $0.isNumber }
        guard !code.isEmpty else { return nil }
        if words.range(of: shown) == nil, words.range(of: code) == nil, let html {
            words = subject + "\n" + HTMLText.plain(html) + "\n" + plain
        }
        let around: String
        let separated = code.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ -]?")
        if let at = words.range(of: shown) ?? words.range(of: code) ?? words.range(of: separated, options: .regularExpression) {
            let start = words.index(at.lowerBound, offsetBy: -120, limitedBy: words.startIndex) ?? words.startIndex
            let end = words.index(at.upperBound, offsetBy: 120, limitedBy: words.endIndex) ?? words.endIndex
            around = String(words[start..<end])
        } else { around = subject }
        let context = (subject + " " + around).lowercased()
        let purpose: MailCodeRead.Purpose
        if has(context, #"purchase|payment|card transaction|покуп|плат[её]ж|pagamento|compra|支払"#) { purpose = .purchase }
        else if has(context, #"reset.{0,20}password|password.{0,20}reset|сброс.{0,20}парол"#) { purpose = .resetPassword }
        else if has(context, #"new device|нов.{0,10}устройств|nuovo dispositivo"#) { purpose = .newDevice }
        else if has(context, #"confirm.{0,20}email|verify.{0,20}email|подтверд.{0,20}почт"#) { purpose = .confirmEmail }
        else if has(context, #"sign[ -]?in|log[ -]?in|authentication|вход|accesso|iniciar sesi"#) { purpose = .signIn }
        else { purpose = .other }
        let amount = purpose == .purchase ? capture(#"((?:USD|EUR|GBP|THB|RUB)\s*[\d,]+(?:\.\d{2})?|[$€£¥₽]\s*[\d,]+(?:\.\d{2})?)"#, around) : nil
        let merchant = purpose == .purchase ?
            (capture(#"(?:card\s+[\d*•x]+\s+to|(?:payment|purchase)(?:\s+of\s+(?:[A-Z]{3}\s*)?[\d.,]+)?\s+(?:at|to))\s+([^\n.!]+?)(?=\s+using\s+code|[\n.!]|$)"#, around)
             ?? capture(#"\bat\s+([A-Za-z][\w &'-]{1,40})(?=[\n.!]|$)"#, around)) : nil
        let card = capture(#"(?:ending\s+(?:in\s+)?|[•*]{2,}|\bx)(\d{4})\b"#, around)
        // A mail can say two: Dashlane's preheader has 3 hours, its body 15
        // minutes. The shorter one is the one that holds.
        let lifetimes = lifetime.matches(in: words, range: NSRange(words.startIndex..., in: words)).compactMap { match -> TimeInterval? in
            guard let range = Range(match.range(at: 1), in: words),
                  let count = capture(#"(\d+)"#, String(words[range])).flatMap(Double.init) else { return nil }
            let unit = words[range].lowercased()
            let seconds: Double = has(unit, "day") ? 86400 : has(unit, "hour") ? 3600 : has(unit, "sec") ? 1 : 60
            return count * seconds
        }
        let expires = lifetimes.min().map { received.addingTimeInterval($0) }
        var display = shown
        if shown == code, code.allSatisfy(\.isNumber), code.count == 6 || code.count == 8 {
            let half = code.index(code.startIndex, offsetBy: code.count / 2)
            display = code[..<half] + " " + code[half...]
        }
        return MailCodeRead(code: code, shown: display, purpose: purpose, amount: amount,
                            merchant: merchant, card: card, expires: expires, sure: prominent != nil)
    }

    private static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let spelled = try! NSRegularExpression(
        pattern: #"\b(?:code|passcode|otp|код)\s*(?:is|:|—|-)?\s*((?=[A-Z0-9-]*[0-9])(?=[A-Z0-9-]*[A-Z])(?:[A-Z0-9]{3,5}-[A-Z0-9]{3,5}|[A-Z0-9]{4,10}))\b"#,
        options: [.caseInsensitive])
    /// An HTML tag: its slash, its name, its attributes.
    private static let tags = try! NSRegularExpression(pattern: #"(?is)<(/?)([a-z][a-z0-9]*)\b([^>]*)>"#)
    /// The markup round a code in one element, at the very most. A layout
    /// table holds a whole mail, and its words were made text only to find
    /// they aren't a code: once for every element round it.
    private static let codeElement = 8_192

    private static func alphanumeric(_ text: String) -> String? {
        for match in spelled.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range])
            if value.contains(where: \.isLetter), value.contains(where: \.isNumber), value == value.uppercased() { return value }
        }
        return nil
    }

    /// Hidden preheaders do not supply a code, even when the subject says "code".
    private static func visibleHTML(_ html: String) -> String {
        var source = String(html.prefix(500_000)).replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        var stack: [(tag: String, start: String.Index, hidden: Bool)] = []
        var spans: [Range<String.Index>] = []
        for token in tags.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            func part(_ n: Int) -> String { Range(token.range(at: n), in: source).map { String(source[$0]) } ?? "" }
            guard let range = Range(token.range, in: source) else { continue }
            let tag = part(2).lowercased(), attrs = part(3).lowercased()
            if part(1) == "/" {
                guard let i = stack.lastIndex(where: { $0.tag == tag }) else { continue }
                let node = stack[i]; stack.removeSubrange(i...)
                if node.hidden { spans.append(node.start..<range.upperBound) }
            } else if !["br", "img", "hr", "meta", "link", "input"].contains(tag), !attrs.hasSuffix("/") {
                stack.append((tag, range.lowerBound, has(attrs, #"display\s*:\s*none|visibility\s*:\s*hidden|(?:^|\s)hidden(?:\s|=|$)"#)))
            }
        }
        // Take outer spans first so nested hidden nodes are removed only once.
        var merged: [Range<String.Index>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else { merged.append(span) }
        }
        for span in merged.reversed() { source.replaceSubrange(span, with: " ") }
        return source
    }

    /// Read an element's complete words. Attributes never contribute digits.
    private static func highlighted(_ html: String) -> String? {
        let source = String(html.prefix(500_000)).replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        var stack: [(tag: String, attrs: String, start: String.Index, at: Int, hidden: Bool)] = []
        var candidates: [(String, Int)] = []
        for token in tags.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            func part(_ n: Int) -> String { Range(token.range(at: n), in: source).map { String(source[$0]) } ?? "" }
            guard let range = Range(token.range, in: source) else { continue }
            let tag = part(2).lowercased(), attrs = part(3).lowercased()
            if part(1) == "/" {
                guard let i = stack.lastIndex(where: { $0.tag == tag }) else { continue }
                let node = stack[i]; stack.removeSubrange(i...)
                guard !node.hidden, token.range.location - node.at <= codeElement else { continue }
                let emphatic = has(node.attrs, #"font-size\s*:\s*(?:2[0-9]|[3-9][0-9])(?:\.\d+)?px|letter-spacing|monospace|courier|menlo"#)
                guard emphatic || tag == "td" else { continue }
                let value = HTMLText.plain(String(source[node.start..<range.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
                guard has(value, #"^(?:G-)?(?:[0-9]{4,8}|[0-9]{3}[ -][0-9]{3}|[0-9]{4}[ -][0-9]{4}|[A-Z0-9]{3,5}-[A-Z0-9]{3,5}|[A-Z0-9]{4,10})$"#),
                      value.contains(where: \.isNumber), value.filter(\.isLetter).isEmpty || value == value.uppercased() else { continue }
                let raw = value.hasPrefix("G-") ? String(value.dropFirst(2)) : value
                // A lone year in a footer is not an authentication step.
                if let year = Int(raw), (1900...2099).contains(year) { continue }
                candidates.append((raw, emphatic ? 0 : 1))
            } else if !["br", "img", "hr", "meta", "link", "input"].contains(tag), !attrs.hasSuffix("/") {
                let hidden = stack.last?.hidden == true || has(attrs, #"display\s*:\s*none|visibility\s*:\s*hidden|(?:^|\s)hidden(?:\s|=|$)"#)
                stack.append((tag, attrs, range.upperBound, token.range.location + token.range.length, hidden))
            }
        }
        return candidates.sorted { $0.1 < $1.1 }.first?.0
    }
}
