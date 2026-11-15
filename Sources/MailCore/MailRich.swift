import AppKit
import Foundation

// A mail's words with their marks (docs/mail.md, Writing): bold, italic,
// underline and links on words; lines in a bulleted or a numbered list,
// nested, or quoted; nothing else, no fonts, sizes or colors. The words are
// lines (`Doc`), each with where it stands (its `Block`s: the quotes and the
// lists it is in) and its runs of words marked alike. From here they go
// three ways: to the text view that writes them (`attributed`, the marks as
// fonts and attributes, where a line stands in an attribute of our own), to
// the HTML a mail carries (`html`, our own small writer of b, i, u, a, ul,
// ol, li, blockquote and br, never the system's exporter with its styles),
// and to the plain text beside it (`text`, no marks at all). HTML comes back
// the other way (`doc(html:)`): a draft kept, a signature from Gmail, words
// pasted from a page or another app, every tag outside the set dropped and
// its words kept.

public enum MailRich {
    /// Where a line stands, outermost first: in a quote, in a bulleted or a
    /// numbered list. Quotes come before lists: a list can be quoted, a
    /// quote is never inside a list's item.
    public enum Block: String, Sendable {
        case quote = "q", bullet = "ul", number = "ol"

        public var list: Bool { self != .quote }
    }

    /// Words marked alike. A link is its address.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var underline = false
        public var link: String? = nil

        /// The same marks, whatever the words.
        public func marked(like other: Run) -> Bool {
            bold == other.bold && italic == other.italic && underline == other.underline && link == other.link
        }

        public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.link = link
        }
    }

    /// One line of the words, a paragraph to the text view: where it stands
    /// and its runs, neighbors marked alike joined, none empty.
    public struct Line: Equatable, Sendable {
        public var blocks: [Block]
        public var runs: [Run]

        public init(_ blocks: [Block] = [], _ runs: [Run] = []) {
            self.blocks = MailRich.order(blocks)
            self.runs = MailRich.joined(runs)
        }

        public init(_ text: String, _ blocks: [Block] = []) {
            self.init(blocks, [Run(text: text)])
        }

        public var text: String { runs.map(\.text).joined() }
        /// How many quotes it is in, and the lists inside them, outermost first.
        public var quotes: Int { blocks.prefix { $0 == .quote }.count }
        public var lists: [Block] { blocks.filter(\.list) }
    }

    public typealias Doc = [Line]

    /// The deepest a line stands: quotes and lists together.
    public static let deepest = 8

    /// Quotes first, then the lists, at most `deepest` in all.
    public static func order(_ blocks: [Block]) -> [Block] {
        Array((blocks.filter { $0 == .quote } + blocks.filter(\.list)).prefix(deepest))
    }

    /// Runs with nothing in them gone, neighbors marked alike made one.
    public static func joined(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.marked(like: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Plain words as lines, each with no mark.
    public static func plain(_ text: String) -> Doc {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { Line($0) }
    }

    /// The words without the empty lines at their end.
    public static func trimmed(_ doc: Doc) -> Doc {
        var out = doc[...]
        while let last = out.last, last.text.allSatisfy(\.isWhitespace) { out.removeLast() }
        return Array(out)
    }

    /// Whether the words carry a mark plain text can't: bold, italic,
    /// underline, a link whose words aren't its address, a list or a quote.
    /// Words without one go as plain text alone.
    public static func formatted(_ doc: Doc) -> Bool {
        doc.contains { line in
            !line.blocks.isEmpty || line.runs.contains { run in
                run.bold || run.italic || run.underline || run.link.map { !bare($0, words: run.text) } == true
            }
        }
    }

    /// A link that only says its own address ("fold.studio" to
    /// http://fold.studio/): plain text says as much.
    public static func bare(_ link: String, words: String) -> Bool {
        func stripped(_ text: String) -> String {
            var out = text.lowercased().trimmingCharacters(in: .whitespaces)
            for scheme in ["mailto:", "https://", "http://"] where out.hasPrefix(scheme) { out.removeFirst(scheme.count) }
            if out.hasPrefix("www.") { out.removeFirst(4) }
            while out.hasSuffix("/") { out.removeLast() }
            return out
        }
        return stripped(link) == stripped(words)
    }

    /// A link's address as a mail may carry it: http, https or mailto, else
    /// none (a script's, a file's, one relative to a page left behind).
    public static func safe(_ href: String) -> String? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = href.lowercased()
        guard ["http://", "https://", "mailto:"].contains(where: { lower.hasPrefix($0) }), href.count > 7,
              !href.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        return href
    }

    /// Words pasted over chosen words, when they are one address: the link
    /// it makes, a site's or a mail's ("www.fold.studio" as https).
    public static func address(_ words: String) -> String? {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !words.contains(where: \.isWhitespace) else { return nil }
        let lower = words.lowercased()
        if lower.hasPrefix("www."), words.count > 6 { return "https://" + words }
        guard let link = safe(words) else { return nil }
        if lower.hasPrefix("mailto:") { return link }
        guard let url = URL(string: link), let host = url.host, host.contains(".") else { return nil }
        return link
    }

    // MARK: - plain text

    /// The words as plain text: lists as "- " and "1. ", nested two spaces
    /// in, quoted lines "> " (">> " a level deeper, an empty one ">"), a
    /// link's address after its words in angle brackets unless they are its
    /// address (or `links` is off, for words shown, not sent). No other
    /// mark: plain text has none.
    public static func text(_ doc: Doc, links: Bool = true) -> String {
        let numbers = numbers(doc)
        return doc.indices.map { at in
            let line = doc[at]
            let words = line.runs.map { run -> String in
                guard links, let link = run.link, !bare(link, words: run.text) else { return run.text }
                return run.text + " <" + (link.lowercased().hasPrefix("mailto:") ? String(link.dropFirst(7)) : link) + ">"
            }.joined()
            var out = ""
            if line.quotes > 0 {
                out = String(repeating: ">", count: line.quotes)
                if words.isEmpty && line.lists.isEmpty { return out }
                out += " "
            }
            if let kind = line.lists.last {
                out += String(repeating: "  ", count: line.lists.count - 1) + (kind == .bullet ? "- " : "\(numbers[at] ?? 1). ")
            }
            return out + words
        }.joined(separator: "\n")
    }

    /// Each numbered line's number, as a mail's reader counts an `<ol>`:
    /// from 1 in each list, a nested list counting on its own, an item
    /// counted on after the lines nested under the one before; nil for the
    /// rest.
    public static func numbers(_ doc: Doc) -> [Int?] {
        var counts: [Int] = []
        var previous: [Block] = []
        return doc.map { line in
            defer { previous = line.blocks }
            let lists = line.lists
            guard let kind = lists.last else {
                counts = []
                return nil
            }
            counts = Array(counts.prefix(lists.count))
            while counts.count < lists.count { counts.append(0) }
            // In the same list as the line before: that one stands in it, or deeper.
            let same = previous.count >= line.blocks.count && Array(previous.prefix(line.blocks.count)) == line.blocks
            if !same { counts[lists.count - 1] = 0 }
            counts[lists.count - 1] += 1
            return kind == .number ? counts[lists.count - 1] : nil
        }
    }

    // MARK: - HTML out

    /// The words as a mail's HTML carries them: each line its words, `<br>`
    /// between lines and for an empty one, a list's lines `<li>`s with a
    /// nested list inside the item before it, quoted lines in a
    /// `<blockquote>`; marks as `<a href>`, `<b>`, `<i>` and `<u>`, in that
    /// order, opened and closed only where they change. A space a browser
    /// would fold (at a line's ends, or after another) is `&nbsp;`, a no-break
    /// space `&#160;` and a tab `&#9;`, so the words stand as written and
    /// `doc(html:)` reads them back line for line.
    /// `said`: each line's own HTML (`inline`), written already: the words
    /// being typed keep them, so a key writes its line, not the mail.
    public static func html(_ doc: Doc, said: [String]? = nil) -> String {
        var out = ""
        write(doc[...], depth: 0, said: said, into: &out)
        return out
    }

    /// A line's words as HTML, alone: what `html` writes of it inside its blocks.
    public static func inline(_ runs: [Run]) -> String {
        var out = ""
        inline(runs, into: &out)
        return out
    }

    /// Lines that stand at least `depth` deep, all in the same blocks to
    /// there.
    private static func write(_ lines: ArraySlice<Line>, depth: Int, said: [String]?, into out: inout String) {
        var at = lines.startIndex
        while at < lines.endIndex {
            let line = lines[at]
            guard line.blocks.count <= depth else {
                let kind = line.blocks[depth]
                var end = at + 1
                while end < lines.endIndex, lines[end].blocks.count > depth, lines[end].blocks[depth] == kind { end += 1 }
                block(kind, lines[at..<end], depth: depth, said: said, into: &out)
                at = end
                continue
            }
            if let said { out += said[at] } else { inline(line.runs, into: &out) }
            let next = at + 1
            // A line ends at the next line's start, and an empty one says
            // itself; a block after it starts on a line of its own anyway.
            if line.runs.isEmpty || (next < lines.endIndex && lines[next].blocks.count == depth) { out += "<br>" }
            at = next
        }
    }

    private static func block(_ kind: Block, _ lines: ArraySlice<Line>, depth: Int, said: [String]?, into out: inout String) {
        guard kind.list else {
            out += "<blockquote>"
            write(lines, depth: depth + 1, said: said, into: &out)
            out += "</blockquote>"
            return
        }
        let tag = kind == .bullet ? "ul" : "ol"
        out += "<" + tag + ">"
        var at = lines.startIndex
        while at < lines.endIndex {
            out += "<li>"
            // The item's own line, if it has one before what is nested in it.
            if lines[at].blocks.count == depth + 1 {
                if let said { out += said[at] } else { inline(lines[at].runs, into: &out) }
                if lines[at].runs.isEmpty { out += "<br>" }
                at += 1
            }
            var end = at
            while end < lines.endIndex, lines[end].blocks.count > depth + 1 { end += 1 }
            if end > at { write(lines[at..<end], depth: depth + 1, said: said, into: &out) }
            out += "</li>"
            at = end
        }
        out += "</" + tag + ">"
    }

    /// A line's runs, each mark's tag open only while it holds.
    private static func inline(_ runs: [Run], into out: inout String) {
        var open: [String] = []
        var previous: Character?
        for (n, run) in runs.enumerated() {
            var wanted: [String] = []
            if let link = run.link { wanted.append("a href=\"" + attribute(link) + "\"") }
            if run.bold { wanted.append("b") }
            if run.italic { wanted.append("i") }
            if run.underline { wanted.append("u") }
            var kept = 0
            while kept < open.count, kept < wanted.count, open[kept] == wanted[kept] { kept += 1 }
            for tag in open[kept...].reversed() { out += "</" + name(of: tag) + ">" }
            for tag in wanted[kept...] { out += "<" + tag + ">" }
            open = wanted
            // The words as they are, but for what HTML says another way:
            // whole stretches at once, at every key of a long mail.
            let text = run.text, last = n == runs.count - 1
            var stretch = text.startIndex, at = text.startIndex
            while at < text.endIndex {
                let char = text[at]
                let next = text.index(after: at)
                if let said = escaped(char, previous: previous, last: last && next == text.endIndex) {
                    out += text[stretch..<at]
                    out += said
                    stretch = next
                }
                previous = char
                at = next
            }
            out += text[stretch...]
        }
        for tag in open.reversed() { out += "</" + name(of: tag) + ">" }
    }

    private static func name(of tag: String) -> String { String(tag.prefix { $0 != " " }) }

    /// What HTML says for a character, when it isn't the character itself.
    private static func escaped(_ char: Character, previous: Character?, last: Bool) -> String? {
        switch char {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        case " ": return previous == nil || previous == " " || last ? "&nbsp;" : nil
        case "\t": return "&#9;"
        case "\u{A0}": return "&#160;"
        case "\n", "\r", "\u{2028}", "\u{2029}": return " "
        default: return nil
        }
    }

    /// A value in quotes in a tag.
    public static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Words as HTML's text, the HTML set apart.
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - HTML in

    /// HTML as lines of words with their marks: ours back as `html` wrote
    /// it, and any other's (a signature from Gmail, words pasted from a page
    /// or an app) as near as the set goes. b and strong bold, i and em
    /// italic, u underlined, and the same said by a style (font-weight,
    /// font-style, text-decoration, as Google Docs says them); a link by its
    /// http, https or mailto address; lists, their items and quotes. Every
    /// other block (p, div, a heading, a table's row) a line of its own,
    /// paragraphs a blank line apart, `<br>` the end of a line; table cells
    /// side by side; scripts, styles, the head and pictures left out; spaces
    /// folded as a browser folds them.
    public static func doc(html: String) -> Doc {
        var reader = Reader()
        reader.read(html)
        return reader.lines
    }

    /// HTML as plain text, no marks: a signature's words, say.
    public static func text(html: String) -> String { text(trimmed(doc(html: html))) }

    private struct Reader {
        /// What an element says of the words in it; nil, nothing.
        public struct Marks {
            public var bold: Bool?
            public var italic: Bool?
            public var underline: Bool?
            public var link: String?
        }

        public struct Open {
            public let name: String
            public var marks = Marks()
            /// The block it stands its lines in.
            public var block: Block?
            /// Its words aren't the mail's: a script, a style, the head.
            public var skip = false
        }

        public var lines: Doc = []
        public var stack: [Open] = []
        /// The line being written, and where its first words stood.
        public var runs: [Run] = []
        var lineBlocks: [Block] = []
        /// A space folded, waiting for the next words, as it was marked.
        public var space: Run?
        /// A paragraph ended last: the next one stands a blank line below.
        var paragraphEnded = false

        public static let void: Set<String> = ["br", "img", "hr", "meta", "link", "input", "wbr", "col", "area", "base", "source", "embed",
                                        "param", "track", "keygen"]
        /// Elements whose words are never a mail's.
        public static let skipped: Set<String> = ["head", "script", "style", "title", "template", "noscript", "object", "iframe", "svg",
                                           "select", "button", "textarea"]
        /// Kept as they are up to their end tag, nothing inside read.
        public static let raw: Set<String> = ["script", "style", "title", "textarea", "template"]
        static let blockNames: Set<String> = [
            "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "tr", "table", "tbody", "thead",
            "tfoot", "section", "article", "header", "footer", "nav", "aside", "main", "pre", "address", "dl", "dt", "dd",
            "figure", "figcaption", "form", "fieldset", "center", "details", "summary", "hr", "body", "html",
        ]

        public var blocks: [Block] { stack.compactMap(\.block) }
        public var skipping: Bool { stack.contains { $0.skip } }

        /// The marks the elements open now give.
        public var marks: Run {
            var run = Run(text: "")
            for open in stack {
                if let bold = open.marks.bold { run.bold = bold }
                if let italic = open.marks.italic { run.italic = italic }
                if let underline = open.marks.underline { run.underline = underline }
                if let link = open.marks.link { run.link = link }
            }
            return run
        }

        // MARK: words

        /// Text between tags: its runs of spaces folded, its entities read.
        public mutating func words(_ raw: String) {
            guard !skipping, !raw.isEmpty else { return }
            var chunk = ""
            for char in raw {
                if char == " " || char == "\t" || char == "\n" || char == "\r" || char == "\u{0C}" {
                    if !chunk.isEmpty { put(MailRich.decode(chunk)) }
                    chunk = ""
                    fold()
                } else {
                    chunk.append(char)
                }
            }
            if !chunk.isEmpty { put(MailRich.decode(chunk)) }
        }

        /// Spaces in the HTML: one before the next words, none at a line's start.
        public mutating func fold() {
            guard space == nil, let last = runs.last?.text.last, last != " " else { return }
            space = marks
        }

        public mutating func put(_ words: String) {
            guard !words.isEmpty else { return }
            if runs.isEmpty { lineBlocks = blocks }
            if var pending = space {
                pending.text = " "
                runs.append(pending)
                space = nil
            }
            var run = marks
            run.text = words
            runs.append(run)
            paragraphEnded = false
        }

        /// The line ends here: kept when it has words, or always (`<br>`,
        /// which says a line even when empty).
        public mutating func end(always: Bool = false) {
            space = nil
            if !runs.isEmpty {
                lines.append(Line(lineBlocks, runs))
            } else if always {
                lines.append(Line(blocks, []))
            }
            runs = []
        }

        // MARK: elements

        public mutating func open(_ name: String, _ attributes: [String: String]) {
            if Reader.void.contains(name) {
                if name == "br" {
                    end(always: true)
                    paragraphEnded = false
                } else if name == "hr" {
                    end()
                }
                return
            }
            var open = Open(name: name)
            open.skip = Reader.skipped.contains(name)
            switch name {
            case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6": open.marks.bold = true
            case "i", "em": open.marks.italic = true
            case "u", "ins": open.marks.underline = true
            case "a": open.marks.link = attributes["href"].flatMap(MailRich.safe)
            default: break
            }
            Reader.style(attributes["style"], into: &open.marks)
            if Reader.blockNames.contains(name) {
                end()
                // Paragraphs one after another stand a blank line apart, as they are drawn.
                if name == "p", paragraphEnded, !lines.isEmpty { lines.append(Line(blocks, [])) }
                paragraphEnded = false
            }
            let deep = blocks.count >= MailRich.deepest
            switch name {
            case "ul", "ol": if !deep { open.block = name == "ul" ? .bullet : .number }
            // A quote inside a list's item is no quote here: its words stay the item's.
            case "blockquote": if !deep, !blocks.contains(where: \.list) { open.block = .quote }
            // An item with no list around it: a bulleted one.
            case "li": if !deep, !blocks.contains(where: \.list) { open.block = .bullet }
            // Cells side by side: a space between their words.
            case "td", "th": if !runs.isEmpty, space == nil, runs.last?.text.last != " " { space = marks }
            default: break
            }
            stack.append(open)
        }

        public mutating func close(_ name: String) {
            guard let at = stack.lastIndex(where: { $0.name == name }) else { return }
            // What was left open inside it closes with it.
            while stack.count > at {
                let gone = stack.removeLast()
                if Reader.blockNames.contains(gone.name) {
                    end()
                    paragraphEnded = gone.name == "p"
                }
            }
        }

        /// A style's say on the marks: font-weight, font-style and
        /// text-decoration.
        public static func style(_ css: String?, into marks: inout Marks) {
            guard let css, !css.isEmpty else { return }
            for declaration in css.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                switch property {
                case "font-weight":
                    if let weight = Int(value) { marks.bold = weight >= 600 }
                    else if value == "bold" || value == "bolder" { marks.bold = true }
                    else if value == "normal" || value == "lighter" { marks.bold = false }
                case "font-style":
                    marks.italic = value.hasPrefix("italic") || value.hasPrefix("oblique")
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { marks.underline = true } else if value.contains("none") { marks.underline = false }
                default: break
                }
            }
        }

        // MARK: the HTML

        /// The HTML read from start to end: text, tags with their
        /// attributes, comments and the doctype passed over, a script's or a
        /// style's insides never read.
        public mutating func read(_ html: String) {
            let s = Array(html.unicodeScalars)
            var i = 0
            var text = String.UnicodeScalarView()
            func isLetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
            // ASCII's case folded: tag names and the ends looked for are ASCII.
            func folded(_ c: Unicode.Scalar) -> UInt32 { c.value >= 65 && c.value <= 90 ? c.value + 32 : c.value }
            func find(_ needle: String, from start: Int) -> Int? {
                let n = needle.unicodeScalars.map(folded)
                guard !n.isEmpty, start <= s.count - n.count else { return nil }
                var at = start
                while at <= s.count - n.count {
                    var hit = true
                    for k in 0..<n.count where folded(s[at + k]) != n[k] {
                        hit = false
                        break
                    }
                    if hit { return at }
                    at += 1
                }
                return nil
            }
            while i < s.count {
                guard s[i] == "<", i + 1 < s.count else {
                    text.append(s[i])
                    i += 1
                    continue
                }
                let next = s[i + 1]
                if next == "!" || next == "?" {
                    words(String(text))
                    text = String.UnicodeScalarView()
                    if i + 3 < s.count, s[i + 2] == "-", s[i + 3] == "-" {
                        i = (find("-->", from: i + 4).map { $0 + 3 }) ?? s.count
                    } else {
                        i = (find(">", from: i + 2).map { $0 + 1 }) ?? s.count
                    }
                    continue
                }
                let closing = next == "/"
                let start = closing ? i + 2 : i + 1
                guard start < s.count, isLetter(s[start]) else {
                    text.append(s[i])
                    i += 1
                    continue
                }
                words(String(text))
                text = String.UnicodeScalarView()
                // The tag's name, then its attributes up to its end.
                var at = start
                var name = ""
                while at < s.count, isLetter(s[at]) || (s[at] >= "0" && s[at] <= "9") || s[at] == "-" || s[at] == ":" {
                    name.unicodeScalars.append(s[at])
                    at += 1
                }
                name = name.lowercased()
                var attributes: [String: String] = [:]
                var selfClosing = false
                while at < s.count, s[at] != ">" {
                    let c = s[at], before = at
                    if c == "/" { selfClosing = true; at += 1; continue }
                    if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" { at += 1; continue }
                    selfClosing = false
                    var key = ""
                    while at < s.count, !" \t\n\r\u{0C}=>/".unicodeScalars.contains(s[at]) {
                        key.unicodeScalars.append(s[at])
                        at += 1
                    }
                    while at < s.count, " \t\n\r\u{0C}".unicodeScalars.contains(s[at]) { at += 1 }
                    var value = ""
                    if at < s.count, s[at] == "=" {
                        at += 1
                        while at < s.count, " \t\n\r\u{0C}".unicodeScalars.contains(s[at]) { at += 1 }
                        if at < s.count, s[at] == "\"" || s[at] == "'" {
                            let quote = s[at]
                            at += 1
                            while at < s.count, s[at] != quote {
                                value.unicodeScalars.append(s[at])
                                at += 1
                            }
                            at += 1
                        } else {
                            while at < s.count, !" \t\n\r\u{0C}>".unicodeScalars.contains(s[at]) {
                                value.unicodeScalars.append(s[at])
                                at += 1
                            }
                        }
                    }
                    if !key.isEmpty, attributes[key.lowercased()] == nil { attributes[key.lowercased()] = MailRich.decode(value) }
                    // Something no attribute starts with: passed over, never the tag's end.
                    if at == before { at += 1 }
                }
                i = min(s.count, at + 1)
                if closing {
                    close(name)
                    continue
                }
                if Reader.raw.contains(name), !selfClosing {
                    // Its insides are no HTML of the mail's: past its end tag.
                    i = (find("</" + name, from: i).flatMap { end in find(">", from: end).map { $0 + 1 } }) ?? s.count
                    continue
                }
                open(name, attributes)
                if selfClosing, !Reader.void.contains(name) { close(name) }
            }
            words(String(text))
            end()
        }
    }

    // MARK: - entities

    /// HTML's entities read: named ones a mail uses, and numbers. `&nbsp;`
    /// is a space, kept as written (`html` writes a space a browser would
    /// fold so); a no-break space by its number stays one.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var at = text.startIndex
        while at < text.endIndex {
            if text[at] == "&", let semi = text[at...].prefix(12).firstIndex(of: ";"), let decoded = entity(text[text.index(after: at)..<semi]) {
                out += decoded
                at = text.index(after: semi)
                continue
            }
            out.append(text[at])
            at = text.index(after: at)
        }
        return out
    }

    private static func entity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, value > 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[String(name)]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "yen": "\u{00A5}", "cent": "\u{00A2}", "deg": "\u{00B0}", "times": "\u{00D7}", "divide": "\u{00F7}", "plusmn": "\u{00B1}",
        "para": "\u{00B6}", "sect": "\u{00A7}", "iexcl": "\u{00A1}", "iquest": "\u{00BF}", "shy": "", "zwnj": "", "zwj": "",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}", "hearts": "\u{2665}", "check": "\u{2713}",
    ]
}

// MARK: - the text view's words

extension MailRich {
    /// Where a line stands, on each of its characters: its blocks' raw
    /// values joined, "q.ul". A line's is its first character's (MailWordsView
    /// keeps the rest alike).
    public static let blocksKey = NSAttributedString.Key("yab.mail.blocks")

    public static func blocks(_ value: Any?) -> [Block] {
        guard let text = value as? String, !text.isEmpty else { return [] }
        return order(text.split(separator: ".").compactMap { Block(rawValue: String($0)) })
    }

    public static func value(_ blocks: [Block]) -> String? {
        blocks.isEmpty ? nil : blocks.map(\.rawValue).joined(separator: ".")
    }

    /// How words are drawn where they are written: the font, the color, the
    /// height of a line.
    public struct Look {
        public var font: NSFont
        public var color: NSColor
        public var line: CGFloat
    }

    /// A reply's and a new mail's words: 13.5 pt on 21 pt lines, as a mail's.
    public static let words = Look(font: .systemFont(ofSize: 13.5), color: .labelColor, line: 21)

    /// The room on a line's left for each block: a quote's bar, a list's marker.
    public static let quoteIndent: CGFloat = 14
    public static let listIndent: CGFloat = 22

    public static func indent(_ blocks: [Block]) -> CGFloat {
        blocks.reduce(0) { $0 + ($1 == .quote ? quoteIndent : listIndent) }
    }

    public static func paragraph(_ blocks: [Block], look: Look = words) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = look.line
        style.maximumLineHeight = look.line
        style.firstLineHeadIndent = indent(blocks)
        style.headIndent = indent(blocks)
        return style
    }

    /// A run's attributes where it stands.
    public static func attributes(_ run: Run, blocks: [Block], look: Look = words) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [
            .font: font(look.font, bold: run.bold, italic: run.italic),
            .foregroundColor: look.color,
            .paragraphStyle: paragraph(blocks, look: look),
        ]
        if run.underline { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { out[.link] = URL(string: link) ?? link }
        if let value = value(blocks) { out[blocksKey] = value }
        return out
    }

    public static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let fonts = NSFontManager.shared
        var font = fonts.convert(base, toNotHaveTrait: [.boldFontMask, .italicFontMask])
        if bold { font = fonts.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = fonts.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Whether a font is bold (semibold and heavier) and italic.
    public static func traits(_ font: NSFont) -> (bold: Bool, italic: Bool) {
        let symbolic = font.fontDescriptor.symbolicTraits
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        return (symbolic.contains(.bold) || weight >= 0.3, symbolic.contains(.italic))
    }

    /// The words as the text view holds them: each line's runs, a newline
    /// between lines carrying the line's blocks.
    public static func attributed(_ doc: Doc, look: Look = words) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (n, line) in doc.enumerated() {
            for run in line.runs {
                out.append(NSAttributedString(string: run.text, attributes: attributes(run, blocks: line.blocks, look: look)))
            }
            if n < doc.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: attributes(Run(text: ""), blocks: line.blocks, look: look)))
            }
        }
        return out
    }

    /// The text view's words as lines: each paragraph where its first
    /// character stands, its runs by their fonts, underlines and links.
    /// Words from another app (RTF) come the same way, their fonts read for
    /// bold and italic, a list of theirs (NSTextList) a list, its markers
    /// left out; sizes and colors left behind.
    public static func doc(_ text: NSAttributedString) -> Doc {
        var fonts = Fonts()
        return lines(of: text, from: 0, until: text.length + 1, fonts: &fonts).map(\.line)
    }

    /// Each font's bold and italic, read once: a text has a few fonts and
    /// many runs. The fonts are kept with them, so none goes while it is
    /// here and another takes its place.
    public struct Fonts {
        private var known: [ObjectIdentifier: (font: NSFont, bold: Bool, italic: Bool)] = [:]

        public mutating func traits(_ font: NSFont) -> (bold: Bool, italic: Bool) {
            if let one = known[ObjectIdentifier(font)] { return (one.bold, one.italic) }
            let read = MailRich.traits(font)
            known[ObjectIdentifier(font)] = (font, read.bold, read.italic)
            return read
        }

        public init() {}
    }

    /// The lines of a text from `start`, where one starts, each with where
    /// it starts; up to the line starting at `until` or after it, which is
    /// left out (past the end: to the last line).
    public static func lines(of text: NSAttributedString, from start: Int, until: Int, fonts: inout Fonts) -> [(start: Int, line: Line)] {
        let string = text.string as NSString
        let length = string.length
        var out: [(start: Int, line: Line)] = []
        var start = start
        while true {
            var end = length
            if start < length {
                let found = string.rangeOfCharacter(from: lineBreaks, options: [], range: NSRange(location: start, length: length - start))
                if found.location != NSNotFound { end = found.location }
            }
            var blocks = start < length ? self.blocks(text.attribute(blocksKey, at: start, effectiveRange: nil)) : []
            var runs: [Run] = []
            if end > start {
                text.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attributes, range, _ in
                    runs.append(run(string.substring(with: range), attributes, fonts: &fonts))
                }
            }
            // Another app's list: its own markers ("\t•\t") are in the words.
            if blocks.isEmpty, start < length,
               let style = text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle, !style.textLists.isEmpty {
                blocks = style.textLists.prefix(deepest).map { list in
                    [NSTextList.MarkerFormat.decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseRoman, .uppercaseRoman, .octal, .lowercaseHexadecimal,
                     .uppercaseHexadecimal].contains(list.markerFormat) ? .number : .bullet
                }
                runs = unmarked(runs)
            }
            out.append((start, Line(blocks, runs)))
            guard end < length else { break }
            // A CR and an LF together end one line.
            start = end + (string.character(at: end) == 13 && end + 1 < length && string.character(at: end + 1) == 10 ? 2 : 1)
            if start >= until { break }
        }
        return out
    }

    /// What ends a line: LF, CR (with an LF after it, one end), and the
    /// line and paragraph separators.
    private static let lineBreaks = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")

    private static func run(_ text: String, _ attributes: [NSAttributedString.Key: Any], fonts: inout Fonts) -> Run {
        var run = Run(text: text)
        if let font = attributes[.font] as? NSFont { (run.bold, run.italic) = fonts.traits(font) }
        if let underline = attributes[.underlineStyle] as? Int, underline != 0 { run.underline = true }
        if let link = attributes[.link] { run.link = ((link as? URL)?.absoluteString ?? link as? String).flatMap(safe) }
        return run
    }

    /// A list item's runs without the marker another app wrote into them.
    private static func unmarked(_ runs: [Run]) -> [Run] {
        let text = runs.map(\.text).joined()
        guard let marker = text.range(of: "^\t?[^\t]{1,8}\t", options: .regularExpression) else { return runs }
        var drop = text.distance(from: marker.lowerBound, to: marker.upperBound)
        var out = runs
        while drop > 0, !out.isEmpty {
            let count = out[0].text.count
            if count <= drop {
                drop -= count
                out.removeFirst()
            } else {
                out[0].text = String(out[0].text.dropFirst(drop))
                drop = 0
            }
        }
        return out
    }

    /// What a pasteboard holds as words with their marks: HTML first (ours,
    /// written on a copy, so words copied here come back as they were), then
    /// RTF, then plain text; empty lines at either end left out. Nil when it
    /// holds no words.
    public static func doc(from board: NSPasteboard) -> Doc? {
        var doc: Doc?
        if let html = board.string(forType: .html) {
            doc = self.doc(html: html)
        } else if let data = board.data(forType: .rtfd),
                  let text = NSAttributedString(rtfd: data, documentAttributes: nil) {
            doc = self.doc(text)
        } else if let data = board.data(forType: .rtf), let text = NSAttributedString(rtf: data, documentAttributes: nil) {
            doc = self.doc(text)
        } else if let text = board.string(forType: .string) {
            doc = plain(text)
        }
        guard var doc else { return nil }
        doc = trimmed(doc)
        while let first = doc.first, first.runs.isEmpty, doc.count > 1 { doc.removeFirst() }
        return doc.isEmpty ? nil : doc
    }
}

// MARK: - marks by key

extension MailRich {
    /// A mark the keys (or ⌘K) put on the words written.
    public enum Mark: String, CaseIterable {
        case bold, italic, underline, bullets, numbers, quote

        /// As ⌘K and Undo say it.
        public var title: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .underline: return "Underline"
            case .bullets: return "Bulleted List"
            case .numbers: return "Numbered List"
            case .quote: return "Quote"
            }
        }

        public var symbol: String {
            switch self {
            case .bold: return "yab.bold"
            case .italic: return "yab.italic"
            case .underline: return "yab.underline"
            case .bullets: return "yab.list"
            case .numbers: return "yab.numlist"
            case .quote: return "text.quote"
            }
        }
    }
}
