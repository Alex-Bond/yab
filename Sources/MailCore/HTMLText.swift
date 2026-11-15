import Foundation

/// HTML as plain text (AgentRead.plain, mail's snippets and bodies).
public enum HTMLText {
    /// A page's words, its lines kept: what a message's print view or a
    /// help page says, without the eighty thousand characters of markup
    /// round it.
    public static func plain(_ html: String) -> String {
        var text = html
        for dead in ["script", "style", "head", "noscript", "svg"] {
            text = text.replacingOccurrences(of: "<\(dead)\\b[^>]*>[\\s\\S]*?</\(dead)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/tr|/li|/h[1-6]|/table|/blockquote)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(td|th)\\b[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = entities(text)
        let lines = text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t\\u{00A0}\\u{200C}\\u{200B}\\u{034F}\\u{FEFF}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entities(_ text: String) -> String {
        var text = text
        for (name, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            text = text.replacingOccurrences(of: name, with: value)
        }
        // Numbered ones, decimal and hex.
        let pattern = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let whole = text as NSString
        var result = ""
        var last = 0
        for match in pattern?.matches(in: text, range: NSRange(location: 0, length: whole.length)) ?? [] {
            result += whole.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = whole.substring(with: match.range(at: 1)) == "x"
            let digits = whole.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
            last = match.range.location + match.range.length
        }
        result += whole.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
