import Foundation

/// The sign-in link in a mail a site sends for a password-free sign-in, a
/// "magic link": the button that says Sign in, Log in, Continue or Verify
/// (MailLinks). Which hosts count is the browser's call; this only reads
/// the mail.
public enum MailLinkWords {

    /// One link in a mail: where it goes, what it says, how much it looks
    /// like the way in.
    public struct Link: Equatable, Sendable {
        public let url: URL
        public let words: String
        public let score: Int
    }

    /// A mail that is about signing in. Without this a link is a
    /// newsletter's "Log in to read more".
    private static let about = try! NSRegularExpression(
        pattern: #"sign[ -]?in|log[ -]?in|magic link|login link|one[- ]?time link|temporary link|verify your (email|account)|confirm your (email|account)"#,
        options: [.caseInsensitive]
    )

    /// What the way in says on its button.
    private static let button = try! NSRegularExpression(
        pattern: #"sign[ -]?in|log[ -]?in|magic link|verify|confirm|continue to|continue with"#,
        options: [.caseInsensitive]
    )

    /// Where the way in goes, by its path: a hint, not proof.
    private static let path = try! NSRegularExpression(
        pattern: #"log[-_]?in|sign[-_]?in|magic|auth|verify|confirm|callback|token|otp|session"#,
        options: [.caseInsensitive]
    )

    /// What a link in the same mail says when it is anything but the way
    /// in: the small print under the button.
    private static let elsewhere = try! NSRegularExpression(
        pattern: #"unsubscribe|preferences|privacy|terms|policy|help|support|contact|report|not you|didn.t (request|ask)|learn more|download|app store|google play|twitter|linkedin|facebook|instagram"#,
        options: [.caseInsensitive]
    )

    private static let anchor = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a\s*>"#,
        options: [.caseInsensitive]
    )

    private static let altWords = try! NSRegularExpression(pattern: #"alt\s*=\s*"([^"]*)""#, options: [.caseInsensitive])

    private static let bare = try! NSRegularExpression(pattern: #"https?://[^\s<>"'()\]]+"#, options: [.caseInsensitive])

    /// Whether the mail says it is about signing in.
    public static func says(_ words: String) -> Bool {
        about.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
    }

    /// The https links in a mail that could be the way in, likeliest
    /// first: its buttons when it has HTML, else the addresses in its text.
    public static func links(html: String?, text: String?) -> [Link] {
        var found: [Link] = []
        if let html, !html.isEmpty {
            let range = NSRange(html.startIndex..., in: html)
            for match in anchor.matches(in: html, range: range) {
                let href = [1, 2].compactMap { Range(match.range(at: $0), in: html).map { String(html[$0]) } }.first ?? ""
                let inner = Range(match.range(at: 3), in: html).map { String(html[$0]) } ?? ""
                if let link = link(href: entities(href), words: plain(inner)) { found.append(link) }
            }
        }
        if found.isEmpty, let text, !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in bare.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                // The words that lead up to it on its line: "Sign in: https://…".
                let line = text[..<r.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
                if let link = link(href: String(text[r]), words: String(line.suffix(60))) { found.append(link) }
            }
        }
        // Likeliest first; the first in the mail wins a tie, as the button
        // comes before the small print.
        return found.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
    }

    private static func link(href: String, words: String) -> Link? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        // https only; http too to this Mac's own server, a test world's.
        guard let url = URL(string: href), let host = url.host()?.lowercased() else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && (host == "127.0.0.1" || host == "localhost")) else { return nil }
        // The words and where it goes, not its query: a token is random
        // letters, and "help" can be among them.
        let both = words + " " + (url.host() ?? "") + url.path
        if elsewhere.firstMatch(in: both, range: NSRange(both.startIndex..., in: both)) != nil { return nil }
        var score = 0
        if button.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil { score += 3 }
        let rest = url.path + "?" + (url.query ?? "")
        if path.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil { score += 2 }
        // A long token is what a one-time link carries.
        if (url.query ?? "").count + url.path.count > 40 { score += 1 }
        guard score >= 2 else { return nil }
        return Link(url: url, words: words, score: score)
    }

    /// A button's words without its tags, its images and its runs of space.
    private static func plain(_ html: String) -> String {
        let alt = altWords.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
            .flatMap { Range($0.range(at: 1), in: html) }.map { String(html[$0]) } ?? ""
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let words = entities(text + (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " + alt : ""))
        return words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func entities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&rsquo;", with: "’").replacingOccurrences(of: "&#x3D;", with: "=")
            .replacingOccurrences(of: "&#61;", with: "=")
    }
}
