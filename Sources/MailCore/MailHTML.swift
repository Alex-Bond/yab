import Foundation

/// A mail's own HTML made safe to show: no scripts, forms or frames of its
/// own, links out to tabs, no pixel reporting that it was opened, and the
/// pictures it carries (cid:) drawn from the files kept on this Mac.
public enum MailHTML {
    /// What `clean` takes out, each pattern made once: compiling them for
    /// every mail of every letter opened was half of what cleaning cost.
    private static let dead: [NSRegularExpression] = ["script", "iframe", "object", "embed", "form", "frameset", "noscript"].flatMap { tag in
        ["<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", "<\(tag)\\b[^>]*>"].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    } + [try! NSRegularExpression(pattern: "<(meta|base|link)\\b[^>]*>", options: [.caseInsensitive]),
         // Handlers, in case a frame ever ran script.
         try! NSRegularExpression(pattern: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])]
    private static let script = try! NSRegularExpression(pattern: "(href|src)\\s*=\\s*([\"'])\\s*javascript:[^\"']*\\2", options: [.caseInsensitive])

    /// `account` and `message`: whose HTML it is, for its pictures by
    /// Content-ID (`pictures`); without them they stay as they are.
    public static func clean(_ html: String, account: String = "", message: String = "") -> String {
        var text = html
        for pattern in dead {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        // And javascript: links.
        text = script.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1=$2#$2")
        // Our own read statuses' pictures, whatever the setting: your mail
        // read here never counts as opened (MailReads).
        text = MailReads.strip(text)
        if blocksPixels { text = pixels(text) }
        if !account.isEmpty, !message.isEmpty { text = pictures(text, account: account, message: message) }
        let head = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: \(cidScheme):; style-src 'unsafe-inline'; font-src https: data:">
        <base target="_blank">
        <style>html,body{margin:0;padding:0;background:transparent;font:13.5px/21px -apple-system,sans-serif;color:#171717;word-wrap:break-word}
        img{max-width:100%;height:auto}table{max-width:100%}body>:first-child{margin-top:0}body>:last-child{margin-bottom:0}
        a{color:inherit;text-decoration:underline;text-decoration-color:rgba(127,127,127,.35);text-underline-offset:2px}
        @media (prefers-color-scheme: dark){html,body{color:#ededed}}</style>
        """
        return head + text
    }

    /// Your promises still open in a mail of yours (MailPromise), lit where
    /// they stand in its HTML: the sentence as written, or as HTML writes its
    /// apostrophes and quotes. One that can't be found as it is stays unlit.
    public static func lit(_ html: String, promised quotes: [String]) -> String {
        var out = html
        for quote in quotes where !quote.isEmpty {
            let curly = quote.replacingOccurrences(of: "'", with: "\u{2019}")
            let straight = quote.replacingOccurrences(of: "\u{2019}", with: "'")
            let forms = [quote, curly, straight].flatMap { [$0, escaped($0), escaped($0).replacingOccurrences(of: "\u{2019}", with: "&rsquo;"),
                                                           escaped($0).replacingOccurrences(of: "'", with: "&#39;")] }
            guard let form = forms.first(where: { out.contains($0) }), let range = out.range(of: form) else { continue }
            out.replaceSubrange(range, with: "<mark style=\"" + markStyle + "\">" + form + "</mark>")
        }
        return out
    }

    /// The light under a promise: the accent, faint, the words their own color.
    static let markStyle = "background: color-mix(in srgb, AccentColor 18%, transparent); color: inherit; border-radius: 3px; padding: 0 1px"

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Put before a mail's HTML in a letter made ahead, unseen: its own
    /// pictures (data:, cid:) and nothing from the network (MailBody.unseen).
    public static let offline = "<meta http-equiv=\"Content-Security-Policy\" content=\"img-src data: \(cidScheme):; font-src data:\">"

    /// A mail's HTML as a letter shows it (`clean`), kept for the mails
    /// opened lately: J back and forth, and a letter drawn again, clean
    /// each mail once. Keyed by whose mail it is, its length and whether
    /// pixels are blocked, which is all that changes what comes out.
    @MainActor public static func cleaned(_ html: String, account: String, message: String) -> String {
        let key = account + "|" + message + "|\(html.utf8.count)|\(blocksPixels)"
        if let kept = cleanedKept[key] { return kept }
        let made = clean(html, account: account, message: message)
        if cleanedKept.count > 300 { cleanedKept.removeAll(keepingCapacity: true) }
        cleanedKept[key] = made
        return made
    }

    @MainActor private static var cleanedKept: [String: String] = [:]

    /// Where a mail's pictures by Content-ID come from in its web view:
    /// Yab's own scheme, served from the files kept here (MailCid).
    public static let cidScheme = "yab-mail-cid"

    /// cid:x in a src, a background or CSS's url(), quoted or not.
    private static let cid = try! NSRegularExpression(pattern: #"((?:\b(?:src|background)\s*=\s*|\burl\(\s*)["']?)cid:([^"'\s)>]+)"#,
                                                      options: [.caseInsensitive])

    /// The Content-IDs a mail's HTML draws, lowercased, as MailMime keeps
    /// them: what of its files are pictures in its words, not chips.
    static func cids(_ html: String) -> Set<String> {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil else { return [] }
        let whole = html as NSString
        return Set(cid.matches(in: html, range: NSRange(location: 0, length: whole.length)).map { match in
            let raw = whole.substring(with: match.range(at: 2))
            return MailMime.contentID(raw.removingPercentEncoding ?? raw).lowercased()
        })
    }

    /// Pictures drawn by Content-ID (cid:x in a src, a background or CSS's
    /// url()) as yab-mail-cid:<account>/<message>/<x>, which MailBody
    /// serves from the files kept on this Mac; every other address, and
    /// cid: anywhere else, as it was.
    public static func pictures(_ html: String, account: String, message: String) -> String {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil else { return html }
        let whole = html as NSString
        var out = ""
        var at = 0
        for match in cid.matches(in: html, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: at, length: match.range.location - at))
            let raw = whole.substring(with: match.range(at: 2))
            out += whole.substring(with: match.range(at: 1)) + picture(account: account, message: message, cid: raw.removingPercentEncoding ?? raw)
            at = NSMaxRange(match.range)
        }
        return out + whole.substring(from: at)
    }

    /// A picture's address in the scheme: each part kept to letters, digits
    /// and -._~@, the rest %-encoded, so no quote or slash of its own can
    /// end the attribute or the path.
    public static func picture(account: String, message: String, cid: String) -> String {
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@"))
        let part = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: keep) ?? text }
        return cidScheme + ":" + [account, message, MailMime.contentID(cid)].map(part).joined(separator: "/")
    }

    /// A picture's address read back: whose it is, and its Content-ID.
    public static func picture(_ url: URL) -> (account: String, message: String, cid: String)? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix(cidScheme + ":") else { return nil }
        let parts = text.dropFirst(cidScheme.count + 1).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count == 3, !parts.contains(where: \.isEmpty) else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// Settings › Mail's Block tracking pixels, on until turned off.
    public static var blocksPixels: Bool {
        get { Store.settings.object(forKey: "mail.pixels") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "mail.pixels") }
    }

    private static let image = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])

    /// Images a sender uses to learn you opened the mail: a pixel square,
    /// or hidden.
    public static func pixels(_ html: String) -> String {
        let pattern = image
        let whole = html as NSString
        var out = ""
        var last = 0
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: last, length: match.range.location - last))
            let tag = whole.substring(with: match.range).lowercased().replacingOccurrences(of: " ", with: "")
            let tiny = ["width=\"1\"", "width='1'", "width=1", "width=\"0\"", "width:1px", "width:0"].contains { tag.contains($0) }
                && ["height=\"1\"", "height='1'", "height=1", "height=\"0\"", "height:1px", "height:0"].contains { tag.contains($0) }
            let hidden = tag.contains("display:none") || tag.contains("visibility:hidden")
            if !(tiny || hidden) { out += whole.substring(with: match.range) }
            last = match.range.location + match.range.length
        }
        return out + whole.substring(from: last)
    }
}
