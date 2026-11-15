import AppKit

/// ⌥⇧⌘C: the page as a link with its name, `[Title](address)`, for a note,
/// an issue, a README or a chat with an agent, where a bare address says
/// nothing about where it goes.
///
/// The clipboard gets it three ways and each app takes the one it reads:
/// the Markdown as plain text, for editors, terminals and anything written
/// in Markdown; an anchor as HTML, so Mail, Notes, Slack or a Google Doc
/// paste the title as a live link and no brackets; and the address alone as
/// a URL, for a field that only wants where it goes.
enum MarkdownLink {
    struct Page {
        let title: String
        let url: URL
    }

    /// The address as ⇧⌘C hands it on, and the name the tab shows: yours if
    /// you gave it one, else the page's, without an unread count or the
    /// site's own name tacked on after it.
    @MainActor static func page(_ tab: Tab) -> Page? {
        guard let address = tab.address else { return nil }
        let url = Diary.shareable(address)
        let title = tab.name ?? Self.title(tab.title, host: url.host() ?? "")
        return Page(title: title.isEmpty ? Address.pretty(url) : title, url: url)
    }

    /// "Rust (programming language) - Wikipedia" is the article; the site is
    /// in the address already. Only a last part that is the site's name goes,
    /// so a title that merely has a dash in it keeps all of it.
    static func title(_ raw: String, host: String) -> String {
        let text = Diary.clean(raw)
        let site = Self.squash(Self.name(host))
        guard !site.isEmpty else { return text }
        for mark in [" - ", " | ", " \u{2013} ", " \u{2014} ", " · ", " • ", " :: "] {
            guard let cut = text.range(of: mark, options: .backwards) else { continue }
            let tail = Self.squash(String(text[cut.upperBound...]))
            let head = text[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
            // "X" is x.com's whole name, but not the start of every word
            // beginning with x: a loose match only from three letters on.
            let loose = min(tail.count, site.count) >= 3 && (tail.hasPrefix(site) || site.hasPrefix(tail))
            if !head.isEmpty, tail.count <= 40, tail == site || loose {
                return head
            }
        }
        return text
    }

    /// The part of a host a site calls itself by: "en.wikipedia.org" is
    /// wikipedia, "news.ycombinator.com" ycombinator, "bbc.co.uk" bbc.
    private static func name(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.count > 1 { labels.removeLast() }
        if labels.count > 1, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(labels.last!) { labels.removeLast() }
        return labels.last ?? ""
    }

    /// Only letters and digits, lowercased: "Hacker News" and "YouTube" meet
    /// their hosts halfway.
    private static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func markdown(_ page: Page) -> String {
        var title = ""
        for character in page.title {
            if "\\[]".contains(character) { title.append("\\") }
            title.append(character)
        }
        // Parentheses that pair up are fine in a Markdown address, Wikipedia
        // has them all the time; one left open would end the link early.
        var address = page.url.absoluteString
        if address.filter({ $0 == "(" }).count != address.filter({ $0 == ")" }).count {
            address = address.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        }
        address = address.replacingOccurrences(of: " ", with: "%20")
        return "[\(title)](\(address))"
    }

    static func html(_ page: Page) -> String {
        "<a href=\"\(escape(page.url.absoluteString))\">\(escape(page.title))</a>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// One page as a link; several as a list, one to a line.
    static func copy(_ pages: [Page], to board: NSPasteboard = .general) {
        guard !pages.isEmpty else { return }
        let text: String
        let html: String
        if pages.count == 1 {
            text = markdown(pages[0])
            html = Self.html(pages[0])
        } else {
            text = pages.map { "- " + markdown($0) }.joined(separator: "\n")
            html = "<ul>" + pages.map { "<li>" + Self.html($0) + "</li>" }.joined() + "</ul>"
        }
        board.clearContents()
        board.setString(text, forType: .string)
        // Charset said: HTML on the clipboard with no charset is
        // read as Latin-1: Notes, Mail and TextEdit made "Café" into "CafÃ©".
        board.setString("<meta charset='utf-8'>" + html, forType: .html)
        if pages.count == 1 { board.setString(pages[0].url.absoluteString, forType: .URL) }
    }
}

extension Browser {
    /// ⌥⇧⌘C: the page in front, or every tab picked, as Markdown links.
    /// Always said in the corner, even with the address bar up: the bar's
    /// tick is for the bare address, and this is a different thing to have.
    func copyMarkdownLink(_ group: [Tab]? = nil) {
        // A peek up: its page, not the one under it.
        let pages = (group ?? (peeking ?? active).map { [$0] } ?? []).compactMap(MarkdownLink.page)
        guard !pages.isEmpty else { return }
        MarkdownLink.copy(pages)
        toaster.pop(pages.count == 1 ? "Markdown link copied" : "\(pages.count) Markdown links copied", mark: "link",
                    keys: Teach.shared.keys(after: .markdownLink, action: .copyMarkdownLink), feedback: .success)
    }
}
