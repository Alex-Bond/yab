import Foundation

// Words a crash leaves behind, the message of a failed check, an
// exception's reason and its stack, cleaned before they leave this Mac:
// addresses of pages, with their queries and fragments, and email addresses
// go; the home folder becomes ~ and the temporary folder <tmp>; long runs of
// hex (keys, tokens, ids, pointers) go. What is left says what went wrong,
// not whose Mac it was or what was open on it.
//
// The idea is DuckDuckGo's String.sanitized(); the rules are Yab's own.
// Only what a crash report sends goes through here, never the report's
// frames and images, which need their ids.

enum Sanitizer {
    /// What stands where something was taken out.
    static let url = "<url>", email = "<email>", hex = "<hex>", temporary = "<tmp>"

    static func clean(_ text: String, home: String = NSHomeDirectory()) -> String {
        var out = text
        // A page's address and all after it to the next space or quote: its
        // query, its fragment, a name and password before its host. The
        // stop or comma after it stays. JSON may write the slashes escaped.
        out = replace(#"\b[A-Za-z][A-Za-z0-9+.\-]*:(?:\\?/){2}(?:[^\s"'<>\\]|\\/)*?(?=[.,;:!?)\]}]*(?:[\s"'<>]|\\(?!/)|$))"#,
                      in: out, with: url)
        out = replace(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"#, in: out, with: email)
        // This Mac's home folder, then anyone's: a build machine's path in a
        // failed check's file name names someone too. /Users/Shared names
        // no one.
        if home.count > 1 {
            out = out.replacingOccurrences(of: home, with: "~")
                .replacingOccurrences(of: home.replacingOccurrences(of: "/", with: "\\/"), with: "~")
        }
        out = replace(#"(?:\\?/)Users(?:\\?/)(?!Shared\b)[^/\\\s"'<>:]+"#, in: out, with: "~")
        out = replace(#"(?:\\?/)(?:private(?:\\?/))?var(?:\\?/)folders(?:\\?/)[^/\\\s"'<>]+(?:\\?/)[^/\\\s"'<>]+"#,
                      in: out, with: temporary)
        // Sixteen hex digits or more, a UUID among them: a key, a token, an
        // id, a pointer. Card numbers are sixteen digits too.
        out = replace(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#, in: out, with: hex)
        out = replace(#"\b(?:0x)?[0-9A-Fa-f]{16,}\b"#, in: out, with: hex)
        return out
    }

    private static var compiled: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        lock.lock()
        let expression = compiled[pattern] ?? (try? NSRegularExpression(pattern: pattern))
        compiled[pattern] = expression
        lock.unlock()
        guard let expression else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
