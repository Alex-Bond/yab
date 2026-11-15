import AppKit
import CoreText
import SwiftUI

/// TeX in an answer, $…$ and \(…\) in a line, $$…$$ and \[…\] on their
/// own, set here with the math font the Mac has (STIX Two Math) into a
/// picture the words carry: no web view, no KaTeX. As much of TeX as
/// answers use: scripts, fractions, roots, big operators with their
/// limits, delimiters that grow, accents, fonts, matrices, cases and
/// aligned lines. What it doesn't know it shows as written.
///
/// A dollar in prose stays a dollar: one opens math only right before a
/// non-space, closes it only right after one and before no digit, and
/// never across a line, so "$5 and $10" and "US$5" read as money.
enum MathTeX {
    struct Span: Equatable {
        var range: Range<String.Index>
        var tex: String
        var display: Bool
    }

    /// The math in a stretch of words, code spans left alone.
    static func spans(_ text: String) -> [Span] {
        var out: [Span] = []
        var at = text.startIndex
        while at < text.endIndex {
            let char = text[at]
            if char == "`" {
                // A code span: as many ticks close it.
                let ticks = String(text[at...].prefix { $0 == "`" })
                let after = text.index(at, offsetBy: ticks.count)
                at = text.range(of: ticks, range: after..<text.endIndex)?.upperBound ?? after
                continue
            }
            if char == "\\" {
                let next = text.index(after: at)
                guard next < text.endIndex else { break }
                if text[next] == "(" || text[next] == "[" {
                    let display = text[next] == "["
                    let start = text.index(after: next)
                    if let close = text.range(of: display ? "\\]" : "\\)", range: start..<text.endIndex) {
                        let tex = text[start..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tex.isEmpty {
                            out.append(Span(range: at..<close.upperBound, tex: tex, display: display))
                            at = close.upperBound
                            continue
                        }
                    }
                }
                // An escaped mark (\$, \*) stays what it is.
                at = text.index(next, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == "$" {
                let next = text.index(after: at)
                if next < text.endIndex, text[next] == "$" {
                    let start = text.index(after: next)
                    if let close = text.range(of: "$$", range: start..<text.endIndex) {
                        let tex = text[start..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tex.isEmpty {
                            out.append(Span(range: at..<close.upperBound, tex: tex, display: true))
                            at = close.upperBound
                            continue
                        }
                    }
                    at = start
                    continue
                }
                if let span = dollar(text, at) {
                    out.append(span)
                    at = span.range.upperBound
                    continue
                }
            }
            at = text.index(after: at)
        }
        return out
    }

    /// One $…$ opening at `open`, if it is math and not money.
    private static func dollar(_ text: String, _ open: String.Index) -> Span? {
        if open > text.startIndex {
            let before = text[text.index(before: open)]
            if before.isLetter || before.isNumber { return nil }
        }
        let start = text.index(after: open)
        guard start < text.endIndex, !text[start].isWhitespace else { return nil }
        var at = start
        while at < text.endIndex {
            let char = text[at]
            if char == "\n" { return nil }
            if char == "\\" {
                at = text.index(at, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == "$" {
                let before = text[text.index(before: at)]
                let after = text.index(after: at)
                guard at > start, !before.isWhitespace, after == text.endIndex || !text[after].isNumber else { return nil }
                return Span(range: open..<after, tex: String(text[start..<at]), display: false)
            }
            at = text.index(after: at)
        }
        return nil
    }

    /// The words with each piece of math as a mark that Markdown passes
    /// over untouched (`placeholder`), and the math back by it.
    @MainActor static func marked(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return text }
        let found = spans(text)
        guard !found.isEmpty else { return text }
        var out = ""
        var at = text.startIndex
        for span in found {
            out += text[at..<span.range.lowerBound]
            out += placeholder(span.tex, display: span.display)
            at = span.range.upperBound
        }
        out += text[at...]
        return out
    }

    // MARK: marks in words

    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    @MainActor private static var known: [String] = []
    @MainActor private static var numbers: [String: Int] = [:]

    @MainActor static func placeholder(_ tex: String, display: Bool) -> String {
        let key = (display ? "D" : "T") + tex
        let number = numbers[key] ?? {
            known.append(key)
            numbers[key] = known.count - 1
            return known.count - 1
        }()
        return "\(open)\(number)\(close)"
    }

    /// The math a mark stands for: its TeX, and whether it was set apart.
    @MainActor static func source(_ number: Int) -> (tex: String, display: Bool)? {
        guard known.indices.contains(number) else { return nil }
        let key = known[number]
        return (String(key.dropFirst()), key.hasPrefix("D"))
    }

    /// Words and math marks in turn, as they stand in `text`.
    @MainActor static func pieces(_ text: String) -> [(words: String, math: (tex: String, display: Bool)?)] {
        guard text.contains(open) else { return [(text, nil)] }
        var out: [(words: String, math: (tex: String, display: Bool)?)] = []
        var rest = Substring(text)
        while let start = rest.firstIndex(of: open), let end = rest[start...].firstIndex(of: close) {
            if start > rest.startIndex { out.append((String(rest[..<start]), nil)) }
            let number = Int(rest[rest.index(after: start)..<end]) ?? -1
            if let math = source(number) { out.append(("", math)) } else { out.append((String(rest[start...end]), nil)) }
            rest = rest[rest.index(after: end)...]
        }
        if !rest.isEmpty { out.append((String(rest), nil)) }
        return out
    }

    // MARK: pictures

    /// Math a little larger than the words round it: STIX's letters stand
    /// smaller than the system font's at one size.
    static let scale: CGFloat = 1.1

    struct Picture {
        let image: NSImage
        /// How far under the words' baseline it goes.
        let descent: CGFloat
        var width: CGFloat { image.size.width }
    }

    @MainActor private static var pictures: [String: Picture] = [:]

    /// The math drawn black on clear, a template the words' color fills.
    @MainActor static func picture(_ tex: String, size: CGFloat, display: Bool) -> Picture {
        let key = "\(size)|\(display)|\(tex)"
        if let known = pictures[key] { return known }
        var parser = Parser(tex)
        let node = parser.parse()
        let box = Layout.box(node, Style(size: size * scale, display: display))
        let pad: CGFloat = 1
        let width = ceil(box.width + 2 * pad)
        let height = ceil(box.ascent + box.descent + 2 * pad)
        let descent = box.descent + pad
        let image = NSImage(size: NSSize(width: max(1, width), height: max(1, height)), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            box.draw(context, CGPoint(x: pad, y: descent))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tex
        let made = Picture(image: image, descent: descent)
        if pictures.count > 300 { pictures.removeAll() }
        pictures[key] = made
        return made
    }

    /// Math set in a line of words: its picture on the words' baseline.
    @MainActor static func text(_ tex: String, size: CGFloat, display: Bool) -> Text {
        let made = picture(tex, size: size, display: display)
        return Text(Image(nsImage: made.image).renderingMode(.template)).baselineOffset(-made.descent)
    }

    // MARK: the tree

    enum Kind { case ord, op, bin, rel, open, close, punct, inner }

    indirect enum Node {
        case glyph(String, Kind, Face)
        case row([Node])
        case fraction(Node, Node, rule: Bool)
        case scripts(Node, sup: Node?, sub: Node?)
        case root(Node, index: Node?)
        case words(String, Face)
        case fenced(String, Node, String)
        case grown(String, CGFloat, Kind)
        case accent(Node, Accent)
        case space(CGFloat)
        case table([[Node]], Table)
        case big(String, limits: Bool?)
        case function(String, limits: Bool)
        case over(Node, Node, above: Bool)
        case boxed(Node)
        case lines([Node])
        case style(Node, display: Bool)
    }

    enum Face { case math, upright, bold, italic, text, textBold, textItalic }
    enum Accent { case hat, tilde, bar, vec, dot, ddot, underline, check, breve, acute, grave }
    enum Table { case matrix, cases, aligned, centered }

    struct Style {
        var size: CGFloat
        var display: Bool
        var level = 0
        var script: Style {
            var next = self
            next.display = false
            next.level = min(level + 1, 2)
            next.size = size * (level == 0 ? 0.7 : level == 1 ? 0.72 : 1)
            return next
        }
        var text: Style { var next = self; next.display = false; return next }
    }

    // MARK: reading TeX

    struct Parser {
        private let chars: [Character]
        private var at = 0

        init(_ tex: String) { chars = Array(tex) }

        mutating func parse() -> Node { lines(until: nil) }

        /// Lines split by \\ (in display math, or between &s of a table read
        /// elsewhere): one row when there's one.
        private mutating func lines(until end: String?) -> Node {
            var rows: [Node] = []
            var row = self.row(until: end, cells: false)
            rows.append(row)
            while peekCommand("\\\\") {
                at += 2
                row = self.row(until: end, cells: false)
                rows.append(row)
            }
            return rows.count == 1 ? rows[0] : .lines(rows)
        }

        private func peekCommand(_ text: String) -> Bool {
            let wanted = Array(text)
            guard at + wanted.count <= chars.count else { return false }
            return Array(chars[at..<at + wanted.count]) == wanted
        }

        private var done: Bool { at >= chars.count }

        /// Atoms up to `end` (a closing brace, \right, \end), \\ or, in a
        /// table's cell, &.
        private mutating func row(until end: String?, cells: Bool) -> Node {
            var items: [Node] = []
            while !done {
                let char = chars[at]
                if char == "}" , end == "}" { break }
                if char == "&", cells { break }
                if peekCommand("\\\\") { break }
                if let end, end.hasPrefix("\\"), peekWord() == end { break }
                if char == "^" || char == "_" {
                    at += 1
                    let script = argument()
                    let base = items.popLast() ?? .row([])
                    items.append(attach(base, script: script, up: char == "^"))
                    continue
                }
                if char == "'" {
                    at += 1
                    var primes = "\u{2032}"
                    while !done, chars[at] == "'" { primes += "\u{2032}"; at += 1 }
                    let base = items.popLast() ?? .row([])
                    items.append(attach(base, script: .glyph(primes, .ord, .upright), up: true))
                    continue
                }
                if let atom = self.atom() {
                    if case .style(.row(let empty), let display) = atom, empty.isEmpty {
                        // \displaystyle: all the rest of the group.
                        let rest = row(until: end, cells: cells)
                        items.append(.style(rest, display: display))
                        break
                    }
                    items.append(atom)
                }
            }
            return items.count == 1 ? items[0] : .row(items)
        }

        private func attach(_ base: Node, script: Node, up: Bool) -> Node {
            if case .scripts(let inner, let sup, let sub) = base {
                if up, sup == nil { return .scripts(inner, sup: script, sub: sub) }
                if !up, sub == nil { return .scripts(inner, sup: sup, sub: script) }
            }
            return up ? .scripts(base, sup: script, sub: nil) : .scripts(base, sup: nil, sub: script)
        }

        private func peekWord() -> String {
            guard at < chars.count, chars[at] == "\\" else { return "" }
            var end = at + 1
            if end < chars.count, !chars[end].isLetter { return String(chars[at...end]) }
            while end < chars.count, chars[end].isLetter { end += 1 }
            return String(chars[at..<end])
        }

        private mutating func skipSpace() {
            while !done, chars[at].isWhitespace { at += 1 }
        }

        /// A script's or a command's argument: a group, a command, or one
        /// character.
        private mutating func argument() -> Node {
            skipSpace()
            guard !done else { return .row([]) }
            if chars[at] == "{" {
                at += 1
                let inner = lines(until: "}")
                if !done, chars[at] == "}" { at += 1 }
                return inner
            }
            return atom() ?? .row([])
        }

        /// A group's words as they are: \text's, \operatorname's, an environment's name.
        private mutating func rawGroup() -> String {
            skipSpace()
            guard !done else { return "" }
            guard chars[at] == "{" else { at += 1; return String(chars[at - 1]) }
            at += 1
            var depth = 1
            var out = ""
            while !done {
                let char = chars[at]
                if char == "{" { depth += 1 } else if char == "}" { depth -= 1; if depth == 0 { at += 1; break } }
                out.append(char)
                at += 1
            }
            return out
        }

        private mutating func optional() -> Node? {
            skipSpace()
            guard !done, chars[at] == "[" else { return nil }
            at += 1
            var items: [Node] = []
            while !done, chars[at] != "]" {
                if let atom = atom() { items.append(atom) }
            }
            if !done { at += 1 }
            return .row(items)
        }

        /// A delimiter after \left, \right, \big…: one mark, or none (".").
        private mutating func delimiter() -> String {
            skipSpace()
            guard !done else { return "." }
            if chars[at] == "\\" {
                let word = peekWord()
                at += word.count
                return Parser.delimiters[String(word.dropFirst())] ?? "."
            }
            at += 1
            return String(chars[at - 1])
        }

        static let delimiters: [String: String] = [
            "{": "{", "}": "}", "|": "\u{2016}", "langle": "\u{27E8}", "rangle": "\u{27E9}", "lbrace": "{", "rbrace": "}",
            "lfloor": "\u{230A}", "rfloor": "\u{230B}", "lceil": "\u{2308}", "rceil": "\u{2309}", "vert": "|", "Vert": "\u{2016}",
            "lvert": "|", "rvert": "|", "lVert": "\u{2016}", "rVert": "\u{2016}", "lbrack": "[", "rbrack": "]",
        ]

        private mutating func atom() -> Node? {
            guard !done else { return nil }
            let char = chars[at]
            switch char {
            case "{":
                at += 1
                let inner = lines(until: "}")
                if !done, chars[at] == "}" { at += 1 }
                return inner
            case "}":
                // A stray brace: passed over.
                at += 1
                return nil
            case "\\":
                return command()
            case "~":
                at += 1
                return .space(0.33)
            default:
                at += 1
                if char.isWhitespace { return nil }
                return Parser.character(char)
            }
        }

        static func character(_ char: Character) -> Node {
            if char.isLetter {
                if char.isASCII { return .glyph(String(char), .ord, .math) }
                if let scalar = char.unicodeScalars.first, (0x3B1...0x3C9).contains(scalar.value) || (0x391...0x3A9).contains(scalar.value) {
                    return .glyph(String(char), .ord, .math)
                }
                return .glyph(String(char), .ord, .upright)
            }
            switch char {
            case "+": return .glyph("+", .bin, .upright)
            case "-": return .glyph("\u{2212}", .bin, .upright)
            case "*": return .glyph("\u{2217}", .bin, .upright)
            case "=", "<", ">": return .glyph(String(char), .rel, .upright)
            case ":": return .glyph(":", .rel, .upright)
            case ",", ";": return .glyph(String(char), .punct, .upright)
            case "(", "[": return .glyph(String(char), .open, .upright)
            case ")", "]": return .glyph(String(char), .close, .upright)
            case "!", "?": return .glyph(String(char), .close, .upright)
            case "\u{00B1}", "\u{00D7}", "\u{00F7}", "\u{22C5}", "\u{2212}": return .glyph(String(char), .bin, .upright)
            case "\u{2264}", "\u{2265}", "\u{2260}", "\u{2248}", "\u{2261}", "\u{2192}", "\u{2208}": return .glyph(String(char), .rel, .upright)
            default: return .glyph(String(char), .ord, .upright)
            }
        }

        private mutating func command() -> Node? {
            let word = peekWord()
            at += word.count
            let name = String(word.dropFirst())
            switch name {
            case "", "\\": return nil
            case ",", ">": return .space(3.0 / 18)
            case ":": return .space(4.0 / 18)
            case ";": return .space(5.0 / 18)
            case "!": return .space(-3.0 / 18)
            case " ": return .space(0.33)
            case "quad": return .space(1)
            case "qquad": return .space(2)
            case "{", "}", "$", "%", "&", "#", "_":
                return .glyph(name, name == "{" ? .open : name == "}" ? .close : .ord, .upright)
            case "|": return .glyph("\u{2016}", .ord, .upright)
            case "frac", "dfrac", "tfrac", "cfrac":
                let top = argument(), bottom = argument()
                let fraction = Node.fraction(top, bottom, rule: true)
                return name == "dfrac" ? .style(fraction, display: true) : name == "tfrac" ? .style(fraction, display: false) : fraction
            case "binom", "dbinom", "tbinom":
                let top = argument(), bottom = argument()
                return .fenced("(", .fraction(top, bottom, rule: false), ")")
            case "sqrt":
                let index = optional()
                return .root(argument(), index: index)
            case "text", "textrm", "mbox", "textnormal", "textsf", "texttt":
                return .words(rawGroup(), .text)
            case "textbf": return .words(rawGroup(), .textBold)
            case "textit", "emph": return .words(rawGroup(), .textItalic)
            case "mathrm", "mathsf", "mathtt", "rm":
                return restyle(argument(), .upright)
            case "mathbf", "boldsymbol", "bm", "bf":
                return restyle(argument(), .bold)
            case "mathit": return restyle(argument(), .math)
            case "mathbb", "Bbb": return alphabet(rawGroup(), Parser.doubleStruck)
            case "mathcal": return alphabet(rawGroup(), Parser.script)
            case "mathfrak": return alphabet(rawGroup(), Parser.fraktur)
            case "operatorname", "operatorname*":
                return .function(rawGroup(), limits: name.hasSuffix("*"))
            case "left":
                let left = delimiter()
                let inner = lines(until: "\\right")
                var right = "."
                if peekWord() == "\\right" { at += 6; right = delimiter() }
                return .fenced(left, inner, right)
            case "right":
                _ = delimiter()
                return nil
            case "middle":
                return .grown(delimiter(), 0, .rel)
            case "big", "bigl", "bigr", "bigm", "Big", "Bigl", "Bigr", "Bigm", "bigg", "biggl", "biggr", "Bigg", "Biggl", "Biggr":
                let sizes: [String: CGFloat] = ["big": 1.2, "Big": 1.8, "bigg": 2.4, "Bigg": 3.0]
                let base = name.hasSuffix("l") || name.hasSuffix("r") || name.hasSuffix("m") ? String(name.dropLast()) : name
                let kind: Kind = name.hasSuffix("l") ? .open : name.hasSuffix("r") ? .close : .ord
                return .grown(delimiter(), sizes[base] ?? 1.2, kind)
            case "displaystyle": return .style(.row([]), display: true)
            case "textstyle", "scriptstyle": return .style(.row([]), display: false)
            case "limits", "nolimits", "nonumber", "notag", "label", "tag", "color", "textcolor", "hline", "centering":
                if ["label", "tag", "color"].contains(name) { _ = rawGroup() }
                if name == "textcolor" { _ = rawGroup(); return argument() }
                return nil
            case "hat", "widehat": return .accent(argument(), .hat)
            case "tilde", "widetilde": return .accent(argument(), .tilde)
            case "bar", "overline": return .accent(argument(), .bar)
            case "vec", "overrightarrow": return .accent(argument(), .vec)
            case "dot": return .accent(argument(), .dot)
            case "ddot": return .accent(argument(), .ddot)
            case "check": return .accent(argument(), .check)
            case "breve": return .accent(argument(), .breve)
            case "acute": return .accent(argument(), .acute)
            case "grave": return .accent(argument(), .grave)
            case "underline": return .accent(argument(), .underline)
            case "overbrace", "underbrace", "phantom", "mathstrut", "displaylines":
                return argument()
            case "overset", "stackrel":
                let top = argument()
                return .over(argument(), top, above: true)
            case "underset":
                let bottom = argument()
                return .over(argument(), bottom, above: false)
            case "boxed", "fbox": return .boxed(argument())
            case "not":
                let next = argument()
                if case .glyph(let mark, _, _) = next { return .glyph(mark + "\u{0338}", .rel, .upright) }
                return next
            case "begin":
                return environment(rawGroup())
            case "end":
                _ = rawGroup()
                return nil
            default:
                if let mark = Parser.greek[name] { return .glyph(mark, .ord, name.first!.isUppercase ? .upright : .math) }
                if let mark = Parser.binary[name] { return .glyph(mark, .bin, .upright) }
                if let mark = Parser.relations[name] { return .glyph(mark, .rel, .upright) }
                if let mark = Parser.symbols[name] { return .glyph(mark, .ord, .upright) }
                if let mark = Parser.opens[name] { return .glyph(mark, .open, .upright) }
                if let mark = Parser.closes[name] { return .glyph(mark, .close, .upright) }
                if let mark = Parser.bigs[name] { return .big(mark, limits: name.contains("int") ? false : nil) }
                if Parser.functions.contains(name) { return .function(name, limits: false) }
                if Parser.limitFunctions.contains(name) { return .function(name, limits: true) }
                if name == "bmod" || name == "mod" { return .row([.space(0.3), .function("mod", limits: false), .space(0.2)]) }
                if name == "pmod" {
                    let inner = argument()
                    return .row([.space(0.5), .glyph("(", .open, .upright), .function("mod", limits: false), .space(0.2), inner, .glyph(")", .close, .upright)])
                }
                return .words(word, .text)
            }
        }

        /// The rows of an environment: cells split by &, rows by \\.
        private mutating func environment(_ name: String) -> Node {
            let bare = name.replacingOccurrences(of: "*", with: "")
            if bare == "array" || bare == "alignat" { _ = rawGroup() }
            var rows: [[Node]] = []
            var row: [Node] = []
            while !done {
                if peekWord() == "\\end" {
                    at += 4
                    _ = rawGroup()
                    break
                }
                let cell = self.row(until: "\\end", cells: true)
                row.append(cell)
                if !done, chars[at] == "&" {
                    at += 1
                } else if peekCommand("\\\\") {
                    at += 2
                    _ = optional()
                    rows.append(row)
                    row = []
                }
            }
            if row.contains(where: { if case .row(let items) = $0 { return !items.isEmpty }; return true }) || rows.isEmpty { rows.append(row) }
            switch bare {
            case "pmatrix": return .fenced("(", .table(rows, .matrix), ")")
            case "bmatrix": return .fenced("[", .table(rows, .matrix), "]")
            case "Bmatrix": return .fenced("{", .table(rows, .matrix), "}")
            case "vmatrix": return .fenced("|", .table(rows, .matrix), "|")
            case "Vmatrix": return .fenced("\u{2016}", .table(rows, .matrix), "\u{2016}")
            case "matrix", "smallmatrix", "array": return .table(rows, .matrix)
            case "cases", "dcases": return .fenced("{", .table(rows, .cases), ".")
            case "aligned", "align", "alignat", "split", "eqnarray", "flalign": return .table(rows, .aligned)
            default: return .table(rows, .centered)
            }
        }

        private func restyle(_ node: Node, _ face: Face) -> Node {
            switch node {
            case .glyph(let mark, let kind, let old): return .glyph(mark, kind, old == .math || old == .upright ? face : old)
            case .row(let items): return .row(items.map { restyle($0, face) })
            case .scripts(let base, let sup, let sub): return .scripts(restyle(base, face), sup: sup, sub: sub)
            default: return node
            }
        }

        private func alphabet(_ letters: String, _ table: (Character) -> String?) -> Node {
            .row(letters.filter { !$0.isWhitespace }.map { char in Node.glyph(table(char) ?? String(char), .ord, .upright) })
        }

        static func doubleStruck(_ char: Character) -> String? {
            let special: [Character: String] = ["C": "\u{2102}", "H": "\u{210D}", "N": "\u{2115}", "P": "\u{2119}", "Q": "\u{211A}", "R": "\u{211D}", "Z": "\u{2124}"]
            if let mark = special[char] { return mark }
            return offset(char, upper: 0x1D538, lower: 0x1D552, digits: 0x1D7D8)
        }

        static func script(_ char: Character) -> String? {
            let special: [Character: String] = ["B": "\u{212C}", "E": "\u{2130}", "F": "\u{2131}", "H": "\u{210B}", "I": "\u{2110}", "L": "\u{2112}", "M": "\u{2133}", "R": "\u{211B}",
                                                "e": "\u{212F}", "g": "\u{210A}", "o": "\u{2134}"]
            if let mark = special[char] { return mark }
            return offset(char, upper: 0x1D49C, lower: 0x1D4B6, digits: nil)
        }

        static func fraktur(_ char: Character) -> String? {
            let special: [Character: String] = ["C": "\u{212D}", "H": "\u{210C}", "I": "\u{2111}", "R": "\u{211C}", "Z": "\u{2128}"]
            if let mark = special[char] { return mark }
            return offset(char, upper: 0x1D504, lower: 0x1D51E, digits: nil)
        }

        static func offset(_ char: Character, upper: UInt32, lower: UInt32, digits: UInt32?) -> String? {
            guard char.isASCII, let value = char.asciiValue.map(UInt32.init) else { return nil }
            let code: UInt32?
            switch char {
            case "A"..."Z": code = upper + value - 65
            case "a"..."z": code = lower + value - 97
            case "0"..."9": code = digits.map { $0 + value - 48 }
            default: code = nil
            }
            return code.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }

        static let greek: [String: String] = [
            "alpha": "\u{3B1}", "beta": "\u{3B2}", "gamma": "\u{3B3}", "delta": "\u{3B4}", "epsilon": "\u{3F5}", "varepsilon": "\u{3B5}",
            "zeta": "\u{3B6}", "eta": "\u{3B7}", "theta": "\u{3B8}", "vartheta": "\u{3D1}", "iota": "\u{3B9}", "kappa": "\u{3BA}",
            "lambda": "\u{3BB}", "mu": "\u{3BC}", "nu": "\u{3BD}", "xi": "\u{3BE}", "omicron": "\u{3BF}", "pi": "\u{3C0}", "varpi": "\u{3D6}",
            "rho": "\u{3C1}", "varrho": "\u{3F1}", "sigma": "\u{3C3}", "varsigma": "\u{3C2}", "tau": "\u{3C4}", "upsilon": "\u{3C5}",
            "phi": "\u{3D5}", "varphi": "\u{3C6}", "chi": "\u{3C7}", "psi": "\u{3C8}", "omega": "\u{3C9}",
            "Gamma": "\u{393}", "Delta": "\u{394}", "Theta": "\u{398}", "Lambda": "\u{39B}", "Xi": "\u{39E}", "Pi": "\u{3A0}",
            "Sigma": "\u{3A3}", "Upsilon": "\u{3A5}", "Phi": "\u{3A6}", "Psi": "\u{3A8}", "Omega": "\u{3A9}",
        ]
        static let binary: [String: String] = [
            "pm": "\u{B1}", "mp": "\u{2213}", "times": "\u{D7}", "div": "\u{F7}", "cdot": "\u{22C5}", "ast": "\u{2217}", "star": "\u{22C6}",
            "circ": "\u{2218}", "bullet": "\u{2219}", "cap": "\u{2229}", "cup": "\u{222A}", "wedge": "\u{2227}", "land": "\u{2227}",
            "vee": "\u{2228}", "lor": "\u{2228}", "oplus": "\u{2295}", "ominus": "\u{2296}", "otimes": "\u{2297}", "odot": "\u{2299}",
            "setminus": "\u{2216}", "sqcup": "\u{2294}", "sqcap": "\u{2293}", "triangleleft": "\u{25C3}", "triangleright": "\u{25B9}",
        ]
        static let relations: [String: String] = [
            "leq": "\u{2264}", "le": "\u{2264}", "geq": "\u{2265}", "ge": "\u{2265}", "neq": "\u{2260}", "ne": "\u{2260}",
            "leqslant": "\u{2A7D}", "geqslant": "\u{2A7E}", "approx": "\u{2248}", "equiv": "\u{2261}", "sim": "\u{223C}",
            "simeq": "\u{2243}", "cong": "\u{2245}", "propto": "\u{221D}", "ll": "\u{226A}", "gg": "\u{226B}", "in": "\u{2208}",
            "notin": "\u{2209}", "ni": "\u{220B}", "subset": "\u{2282}", "supset": "\u{2283}", "subseteq": "\u{2286}",
            "supseteq": "\u{2287}", "to": "\u{2192}", "rightarrow": "\u{2192}", "leftarrow": "\u{2190}", "gets": "\u{2190}",
            "Rightarrow": "\u{21D2}", "Leftarrow": "\u{21D0}", "Leftrightarrow": "\u{21D4}", "leftrightarrow": "\u{2194}",
            "implies": "\u{27F9}", "impliedby": "\u{27F8}", "iff": "\u{27FA}", "mapsto": "\u{21A6}", "longrightarrow": "\u{27F6}",
            "longleftarrow": "\u{27F5}", "Longrightarrow": "\u{27F9}", "longmapsto": "\u{27FC}", "uparrow": "\u{2191}",
            "downarrow": "\u{2193}", "perp": "\u{27C2}", "parallel": "\u{2225}", "mid": "\u{2223}", "nmid": "\u{2224}",
            "models": "\u{22A8}", "vdash": "\u{22A2}", "prec": "\u{227A}", "succ": "\u{227B}", "preceq": "\u{2AAF}",
            "succeq": "\u{2AB0}", "asymp": "\u{224D}", "doteq": "\u{2250}", "coloneqq": "\u{2254}", "triangleq": "\u{225C}",
            "nleq": "\u{2270}", "ngeq": "\u{2271}", "nsubseteq": "\u{2288}", "hookrightarrow": "\u{21AA}", "rightleftharpoons": "\u{21CC}",
        ]
        static let symbols: [String: String] = [
            "infty": "\u{221E}", "partial": "\u{2202}", "nabla": "\u{2207}", "forall": "\u{2200}", "exists": "\u{2203}",
            "nexists": "\u{2204}", "emptyset": "\u{2205}", "varnothing": "\u{2205}", "neg": "\u{AC}", "lnot": "\u{AC}",
            "ldots": "\u{2026}", "dots": "\u{2026}", "dotsc": "\u{2026}", "dotsb": "\u{22EF}", "cdots": "\u{22EF}", "vdots": "\u{22EE}", "ddots": "\u{22F1}",
            "prime": "\u{2032}", "angle": "\u{2220}", "triangle": "\u{25B3}", "hbar": "\u{210F}", "ell": "\u{2113}",
            "Re": "\u{211C}", "Im": "\u{2111}", "aleph": "\u{2135}", "degree": "\u{B0}", "top": "\u{22A4}",
            "bot": "\u{22A5}", "checkmark": "\u{2713}", "square": "\u{25A1}", "Box": "\u{25A1}", "blacksquare": "\u{25A0}",
            "therefore": "\u{2234}", "because": "\u{2235}", "vert": "|", "Vert": "\u{2016}", "backslash": "\\", "wp": "\u{2118}",
            "imath": "\u{1D6A4}", "jmath": "\u{1D6A5}", "dagger": "\u{2020}", "ddagger": "\u{2021}", "S": "\u{A7}", "P": "\u{B6}",
            "colon": ":", "surd": "\u{221A}", "flat": "\u{266D}", "sharp": "\u{266F}", "natural": "\u{266E}", "clubsuit": "\u{2663}",
            "heartsuit": "\u{2661}", "diamondsuit": "\u{2662}", "spadesuit": "\u{2660}", "complement": "\u{2201}",
        ]
        static let opens: [String: String] = ["langle": "\u{27E8}", "lfloor": "\u{230A}", "lceil": "\u{2308}", "lbrace": "{", "lvert": "|", "lVert": "\u{2016}"]
        static let closes: [String: String] = ["rangle": "\u{27E9}", "rfloor": "\u{230B}", "rceil": "\u{2309}", "rbrace": "}", "rvert": "|", "rVert": "\u{2016}"]
        static let bigs: [String: String] = [
            "sum": "\u{2211}", "prod": "\u{220F}", "coprod": "\u{2210}", "int": "\u{222B}", "iint": "\u{222C}", "iiint": "\u{222D}",
            "oint": "\u{222E}", "bigcup": "\u{22C3}", "bigcap": "\u{22C2}", "bigoplus": "\u{2A01}", "bigotimes": "\u{2A02}",
            "bigvee": "\u{22C1}", "bigwedge": "\u{22C0}", "bigsqcup": "\u{2A06}", "bigodot": "\u{2A00}",
        ]
        static let functions: Set<String> = [
            "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth", "log", "ln",
            "lg", "exp", "deg", "dim", "ker", "arg", "hom", "sgn", "Tr", "tr", "rank", "span",
        ]
        static let limitFunctions: Set<String> = ["lim", "limsup", "liminf", "max", "min", "sup", "inf", "det", "gcd", "lcm", "Pr", "argmax", "argmin"]
    }

    // MARK: setting it

    struct Box {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var kind: Kind = .ord
        /// Drawn with its baseline's left end at the point.
        var draw: (CGContext, CGPoint) -> Void = { _, _ in }

        static let empty = Box(width: 0, ascent: 0, descent: 0)
    }

    enum Layout {
        static func font(_ size: CGFloat, _ face: Face) -> CTFont {
            let name: String
            switch face {
            case .text: name = "STIXTwoText"
            case .textBold, .bold: name = "STIXTwoText-Bold"
            case .textItalic: name = "STIXTwoText-Italic"
            default: name = "STIXTwoMath-Regular"
            }
            return CTFontCreateWithName(name as CFString, size, nil)
        }

        /// The height of the math axis, where fractions' rules and minus
        /// signs stand.
        static func axis(_ style: Style) -> CGFloat { style.size * 0.25 }
        static func rule(_ style: Style) -> CGFloat { max(0.6, style.size * 0.055) }

        /// A letter as math sets it: x as 𝑥, α as 𝛼; ℎ for h.
        static func italic(_ mark: String) -> String {
            String(mark.unicodeScalars.map { scalar -> Character in
                let value = scalar.value
                var code: UInt32?
                switch value {
                case 0x68: code = 0x210E
                case 0x41...0x5A: code = 0x1D434 + value - 0x41
                case 0x61...0x7A: code = 0x1D44E + value - 0x61
                case 0x3B1...0x3C9: code = 0x1D6FC + value - 0x3B1
                case 0x3F5: code = 0x1D716
                case 0x3D1: code = 0x1D717
                case 0x3D5: code = 0x1D719
                case 0x3F1: code = 0x1D71A
                case 0x3D6: code = 0x1D71B
                default: break
                }
                return Character(code.flatMap { Unicode.Scalar($0) } ?? scalar)
            })
        }

        static func bold(_ mark: String) -> String {
            String(mark.unicodeScalars.map { scalar -> Character in
                let value = scalar.value
                var code: UInt32?
                switch value {
                case 0x41...0x5A: code = 0x1D400 + value - 0x41
                case 0x61...0x7A: code = 0x1D41A + value - 0x61
                case 0x30...0x39: code = 0x1D7CE + value - 0x30
                case 0x3B1...0x3C9: code = 0x1D6C2 + value - 0x3B1
                case 0x391...0x3A9: code = 0x1D6A8 + value - 0x391
                default: break
                }
                return Character(code.flatMap { Unicode.Scalar($0) } ?? scalar)
            })
        }

        /// Words in one font: its ink's height and depth, its advance wide.
        static func line(_ words: String, _ font: CTFont, kind: Kind = .ord) -> Box {
            let attributed = NSAttributedString(string: words, attributes: [.init(kCTFontAttributeName as String): font, .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let size = CTFontGetSize(font)
            // At least an x's height and no less deep than the line under it:
            // "a" and "x" sit on one line with "b" and "y".
            let ascent = max(ink.maxY, size * 0.45)
            let descent = max(-ink.minY, 0)
            return Box(width: width, ascent: ascent, descent: descent, kind: kind) { context, at in
                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = at
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }

        static func glyph(_ mark: String, _ kind: Kind, _ face: Face, _ style: Style) -> Box {
            switch face {
            case .math: return line(italic(mark), font(style.size, .math), kind: kind)
            case .bold: return line(bold(mark), font(style.size, .math), kind: kind)
            case .italic, .textItalic: return line(mark, font(style.size, .textItalic), kind: kind)
            case .text: return line(mark, font(style.size, .text), kind: kind)
            case .textBold: return line(mark, font(style.size, .textBold), kind: kind)
            case .upright: return line(mark, font(style.size, .math), kind: kind)
            }
        }

        /// Boxes side by side, spaced as TeX spaces its atoms.
        static func row(_ boxes: [Box], _ style: Style) -> Box {
            var placed: [(Box, CGFloat)] = []
            var x: CGFloat = 0
            var previous: Kind?
            for var box in boxes {
                // A minus with nothing before it to take from is a sign.
                if box.kind == .bin, previous == nil || [Kind.bin, .op, .rel, .open, .punct].contains(previous!) { box.kind = .ord }
                if let previous { x += space(previous, box.kind, style) }
                placed.append((box, x))
                x += box.width
                previous = box.kind
            }
            // A trailing operator is no operator either: "a +" at a line's end.
            if let last = placed.last, last.0.kind == .bin, placed.count > 1 {
                let gap = space(placed[placed.count - 2].0.kind, .bin, style)
                x -= gap
                placed[placed.count - 1].1 -= gap
            }
            let ascent = placed.map(\.0.ascent).max() ?? 0
            let descent = placed.map(\.0.descent).max() ?? 0
            let kind = boxes.count == 1 ? boxes[0].kind : .ord
            return Box(width: x, ascent: ascent, descent: descent, kind: kind) { context, at in
                for (box, offset) in placed { box.draw(context, CGPoint(x: at.x + offset, y: at.y)) }
            }
        }

        static func space(_ left: Kind, _ right: Kind, _ style: Style) -> CGFloat {
            let em = style.size
            let small = style.level > 0
            if left == .bin || right == .bin { return small ? 0 : em * 4 / 18 }
            if left == .rel || right == .rel { return small ? 0 : em * 5 / 18 }
            if left == .punct { return small ? 0 : em * 3 / 18 }
            if left == .op, right == .ord || right == .op { return em * 3 / 18 }
            if left == .ord, right == .op { return em * 3 / 18 }
            if left == .close, right == .op { return em * 3 / 18 }
            if left == .inner || right == .inner, left != .open, right != .close { return small ? 0 : em * 3 / 18 }
            return 0
        }

        static func box(_ node: Node, _ style: Style) -> Box {
            switch node {
            case .glyph(let mark, let kind, let face):
                return glyph(mark, kind, face, style)
            case .row(let items):
                return row(items.map { box($0, style) }, style)
            case .words(let words, let face):
                return glyph(words, .ord, face, style)
            case .space(let em):
                return Box(width: em * style.size, ascent: 0, descent: 0, kind: .ord)
            case .style(let inner, let display):
                var next = style
                next.display = display
                if display { next.level = 0 }
                return box(inner, next)
            case .fraction(let top, let bottom, let rule):
                return fraction(top, bottom, rule: rule, style)
            case .scripts(let base, let sup, let sub):
                return scripts(base, sup: sup, sub: sub, style)
            case .root(let inner, let index):
                return root(inner, index: index, style)
            case .fenced(let left, let inner, let right):
                let middle = box(inner, style)
                let axis = self.axis(style)
                let reach = max(middle.ascent - axis, middle.descent + axis)
                let height = max(reach * 2 * 1.05, 0)
                var items: [Box] = []
                if left != "." { items.append(delimiter(left, height: height, kind: .open, style)) }
                var inside = middle
                inside.kind = .inner
                items.append(inside)
                if right != "." { items.append(delimiter(right, height: height, kind: .close, style)) }
                var made = row(items, style)
                made.kind = .inner
                return made
            case .grown(let mark, let factor, let kind):
                return delimiter(mark, height: factor == 0 ? 0 : style.size * factor, kind: kind, style)
            case .accent(let inner, let accent):
                return self.accent(box(inner, style), accent, style)
            case .table(let rows, let kind):
                return table(rows, kind, style)
            case .big(let mark, let limits):
                return big(mark, limits: limits, style)
            case .function(let name, _):
                return line(name, font(style.size, .upright), kind: .op)
            case .over(let base, let other, let above):
                let main = box(base, style)
                let small = box(other, style.script)
                let gap = style.size * 0.12
                let width = max(main.width, small.width)
                let ascent = above ? main.ascent + gap + small.descent + small.ascent : main.ascent
                let descent = above ? main.descent : main.descent + gap + small.ascent + small.descent
                return Box(width: width, ascent: ascent, descent: descent, kind: main.kind == .rel ? .rel : .ord) { context, at in
                    main.draw(context, CGPoint(x: at.x + (width - main.width) / 2, y: at.y))
                    let y = above ? at.y + main.ascent + gap + small.descent : at.y - main.descent - gap - small.ascent
                    small.draw(context, CGPoint(x: at.x + (width - small.width) / 2, y: y))
                }
            case .boxed(let inner):
                let main = box(inner, style)
                let pad = style.size * 0.25
                let rule = self.rule(style)
                return Box(width: main.width + 2 * pad, ascent: main.ascent + pad, descent: main.descent + pad) { context, at in
                    main.draw(context, CGPoint(x: at.x + pad, y: at.y))
                    context.setLineWidth(rule)
                    context.stroke(CGRect(x: at.x + rule / 2, y: at.y - main.descent - pad + rule / 2,
                                          width: main.width + 2 * pad - rule, height: main.ascent + main.descent + 2 * pad - rule))
                }
            case .lines(let rows):
                return table(rows.map { [$0] }, .centered, style)
            }
        }

        static func fraction(_ top: Node, _ bottom: Node, rule: Bool, _ style: Style) -> Box {
            let inner = style.display ? style.text : style.script
            let numerator = box(top, inner)
            let denominator = box(bottom, inner)
            let thickness = rule ? self.rule(style) : 0
            let axis = self.axis(style)
            let gap = style.display ? style.size * 0.16 : style.size * 0.1
            let pad = style.size * 0.12
            let width = max(numerator.width, denominator.width) + 2 * pad
            let up = axis + thickness / 2 + gap + numerator.descent
            let down = axis - thickness / 2 - gap - denominator.ascent
            let line = self.rule(style)
            return Box(width: width, ascent: up + numerator.ascent, descent: max(0, denominator.descent - down), kind: .inner) { context, at in
                numerator.draw(context, CGPoint(x: at.x + (width - numerator.width) / 2, y: at.y + up))
                denominator.draw(context, CGPoint(x: at.x + (width - denominator.width) / 2, y: at.y + down))
                if rule { context.fill(CGRect(x: at.x + pad * 0.5, y: at.y + axis - line / 2, width: width - pad, height: line)) }
            }
        }

        static func scripts(_ baseNode: Node, sup: Node?, sub: Node?, _ style: Style) -> Box {
            // Over and under a big operator in display, or a limit's name.
            var limits = false
            switch baseNode {
            case .big(_, let wanted): limits = style.display && (wanted ?? true)
            case .function(_, let wanted): limits = style.display && wanted
            default: break
            }
            let base = box(baseNode, style)
            let small = style.script
            let upper = sup.map { box($0, small) }
            let lower = sub.map { box($0, small) }
            if limits {
                let gap = style.size * 0.15
                let width = max(base.width, upper?.width ?? 0, lower?.width ?? 0)
                let ascent = base.ascent + (upper.map { gap + $0.descent + $0.ascent } ?? 0)
                let descent = base.descent + (lower.map { gap + $0.ascent + $0.descent } ?? 0)
                return Box(width: width, ascent: ascent, descent: descent, kind: .op) { context, at in
                    base.draw(context, CGPoint(x: at.x + (width - base.width) / 2, y: at.y))
                    if let upper { upper.draw(context, CGPoint(x: at.x + (width - upper.width) / 2, y: at.y + base.ascent + gap + upper.descent)) }
                    if let lower { lower.draw(context, CGPoint(x: at.x + (width - lower.width) / 2, y: at.y - base.descent - gap - lower.ascent)) }
                }
            }
            let single: Bool
            if case .glyph = baseNode { single = true } else { single = false }
            let size = style.size
            var up = max(single ? 0 : base.ascent - size * 0.3, size * 0.38)
            if let upper { up = max(up, upper.descent + size * 0.22) }
            var down = max(single ? 0 : base.descent + size * 0.06, size * 0.17)
            if let lower { down = max(down, lower.ascent - size * 0.36) }
            if let upper, let lower {
                let clearance = (up - upper.descent) - (lower.ascent - down)
                let wanted = self.rule(style) * 3
                if clearance < wanted { down += wanted - clearance }
            }
            // An italic letter leans over its superscript a little.
            let lean: CGFloat
            if case .glyph(_, _, .math) = baseNode { lean = size * 0.04 } else { lean = 0 }
            let gap = size * 0.03
            let width = base.width + max((upper?.width ?? 0) + lean, lower?.width ?? 0) + gap
            let ascent = max(base.ascent, upper.map { up + $0.ascent } ?? 0)
            let descent = max(base.descent, lower.map { down + $0.descent } ?? 0)
            return Box(width: width, ascent: ascent, descent: descent, kind: base.kind) { context, at in
                base.draw(context, at)
                if let upper { upper.draw(context, CGPoint(x: at.x + base.width + lean, y: at.y + up)) }
                if let lower { lower.draw(context, CGPoint(x: at.x + base.width, y: at.y - down)) }
            }
        }

        static func root(_ inner: Node, index: Node?, _ style: Style) -> Box {
            let body = box(inner, style)
            let rule = self.rule(style)
            let size = style.size
            let clearance = style.display ? size * 0.16 : size * 0.1
            let top = max(body.ascent, size * 0.5) + clearance
            let bottom = max(body.descent, size * 0.05) + size * 0.04
            let height = top + bottom
            let sign = size * 0.42 + height * 0.06
            let small = index.map { box($0, style.script.script) }
            let shift = small.map { max(0, $0.width - sign * 0.45) } ?? 0
            let width = shift + sign + body.width + size * 0.08
            return Box(width: width, ascent: top + rule, descent: bottom, kind: .ord) { context, at in
                let x = at.x + shift
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: at.y - bottom + height * 0.42))
                path.addLine(to: CGPoint(x: x + sign * 0.18, y: at.y - bottom + height * 0.5))
                context.setLineWidth(rule)
                context.setLineCap(.round)
                context.addPath(path)
                context.strokePath()
                let heavy = CGMutablePath()
                heavy.move(to: CGPoint(x: x + sign * 0.18, y: at.y - bottom + height * 0.5))
                heavy.addLine(to: CGPoint(x: x + sign * 0.48, y: at.y - bottom))
                context.setLineWidth(rule * 1.9)
                context.setLineCap(.butt)
                context.addPath(heavy)
                context.strokePath()
                let rise = CGMutablePath()
                rise.move(to: CGPoint(x: x + sign * 0.48, y: at.y - bottom))
                rise.addLine(to: CGPoint(x: x + sign, y: at.y + top + rule / 2))
                rise.addLine(to: CGPoint(x: x + sign + body.width + size * 0.08, y: at.y + top + rule / 2))
                context.setLineWidth(rule)
                context.setLineJoin(.miter)
                context.addPath(rise)
                context.strokePath()
                body.draw(context, CGPoint(x: x + sign, y: at.y))
                if let small { small.draw(context, CGPoint(x: at.x + max(0, sign * 0.45 - small.width) * 0.5, y: at.y - bottom + height * 0.58 + small.descent)) }
            }
        }

        static func big(_ mark: String, limits: Bool?, _ style: Style) -> Box {
            let integral = limits == false
            let factor: CGFloat = style.display ? (integral ? 1.75 : 1.45) : (integral ? 1.15 : 1.0)
            var made = line(mark, font(style.size * factor, .upright), kind: .op)
            // Centered on the axis, as TeX hangs them.
            let axis = self.axis(style)
            let shift = axis - (made.ascent - made.descent) / 2
            let draw = made.draw
            made.ascent += shift
            made.descent -= shift
            made.draw = { context, at in draw(context, CGPoint(x: at.x, y: at.y + shift)) }
            return made
        }

        /// A delimiter at least `height` tall, centered on the axis: drawn
        /// for straight ones, the font's own stretched for curved ones.
        static func delimiter(_ mark: String, height wanted: CGFloat, kind: Kind, _ style: Style) -> Box {
            let size = style.size
            let axis = self.axis(style)
            let natural = line(mark, font(size, .upright), kind: kind)
            let naturalHeight = natural.ascent + natural.descent
            guard wanted > naturalHeight * 1.08 else { return natural }
            let half = wanted / 2
            let rule = self.rule(style)
            let straight = ["[", "]", "|", "\u{2016}", "\u{230A}", "\u{230B}", "\u{2308}", "\u{2309}", "\u{27E8}", "\u{27E9}"]
            if straight.contains(mark) {
                let width = mark == "\u{2016}" ? size * 0.42 : mark == "|" ? size * 0.28 : size * 0.4
                let stroke = rule * 1.3
                return Box(width: width, ascent: axis + half, descent: half - axis, kind: kind) { context, at in
                    let low = at.y + axis - half + stroke / 2, high = at.y + axis + half - stroke / 2
                    let path = CGMutablePath()
                    let left = at.x + size * 0.1, right = at.x + width - size * 0.1
                    switch mark {
                    case "[": path.addLines(between: [CGPoint(x: right, y: high), CGPoint(x: left, y: high), CGPoint(x: left, y: low), CGPoint(x: right, y: low)])
                    case "]": path.addLines(between: [CGPoint(x: left, y: high), CGPoint(x: right, y: high), CGPoint(x: right, y: low), CGPoint(x: left, y: low)])
                    case "\u{230A}": path.addLines(between: [CGPoint(x: left, y: high), CGPoint(x: left, y: low), CGPoint(x: right, y: low)])
                    case "\u{230B}": path.addLines(between: [CGPoint(x: right, y: high), CGPoint(x: right, y: low), CGPoint(x: left, y: low)])
                    case "\u{2308}": path.addLines(between: [CGPoint(x: left, y: low), CGPoint(x: left, y: high), CGPoint(x: right, y: high)])
                    case "\u{2309}": path.addLines(between: [CGPoint(x: right, y: low), CGPoint(x: right, y: high), CGPoint(x: left, y: high)])
                    case "\u{27E8}": path.addLines(between: [CGPoint(x: right, y: high), CGPoint(x: left, y: at.y + axis), CGPoint(x: right, y: low)])
                    case "\u{27E9}": path.addLines(between: [CGPoint(x: left, y: high), CGPoint(x: right, y: at.y + axis), CGPoint(x: left, y: low)])
                    case "\u{2016}":
                        path.addLines(between: [CGPoint(x: left + width * 0.1, y: high), CGPoint(x: left + width * 0.1, y: low)])
                        path.addLines(between: [CGPoint(x: right - width * 0.1, y: high), CGPoint(x: right - width * 0.1, y: low)])
                    default: path.addLines(between: [CGPoint(x: at.x + width / 2, y: high), CGPoint(x: at.x + width / 2, y: low)])
                    }
                    context.setLineWidth(stroke)
                    context.setLineJoin(.miter)
                    context.setLineCap(.butt)
                    context.addPath(path)
                    context.strokePath()
                }
            }
            // ( ): a crescent, thickest at its middle, as TeX's tall ones are.
            if mark == "(" || mark == ")" {
                let width = size * 0.36 + wanted * 0.05
                let thick = rule * 1.4 + wanted * 0.02
                return Box(width: width, ascent: axis + half, descent: half - axis, kind: kind) { context, at in
                    let top = at.y + axis + half, bottom = at.y + axis - half, middle = at.y + axis
                    let left = mark == "("
                    // The ends near the inner side, the belly out at the outer.
                    let end = left ? at.x + width - size * 0.06 : at.x + size * 0.06
                    let belly = left ? at.x + size * 0.07 : at.x + width - size * 0.07
                    let outer = 2 * belly - end
                    let inner = outer + (left ? 2 * thick : -2 * thick)
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: end, y: top))
                    path.addQuadCurve(to: CGPoint(x: end, y: bottom), control: CGPoint(x: outer, y: middle))
                    path.addQuadCurve(to: CGPoint(x: end, y: top), control: CGPoint(x: inner, y: middle))
                    path.closeSubpath()
                    context.addPath(path)
                    context.fillPath()
                }
            }
            // { }: the glyph drawn taller, a little wider as it grows.
            let stretch = wanted / naturalHeight
            let widen = 1 + (stretch - 1) * 0.22
            let width = natural.width * widen
            let middle = (natural.ascent - natural.descent) / 2
            return Box(width: width, ascent: axis + half, descent: half - axis, kind: kind) { context, at in
                context.saveGState()
                context.translateBy(x: at.x, y: at.y + axis)
                context.scaleBy(x: widen, y: stretch)
                natural.draw(context, CGPoint(x: 0, y: -middle))
                context.restoreGState()
            }
        }

        static func accent(_ body: Box, _ accent: Accent, _ style: Style) -> Box {
            let size = style.size
            let rule = self.rule(style)
            if accent == .bar || accent == .underline {
                let gap = size * 0.1
                let over = accent == .bar
                return Box(width: body.width, ascent: over ? body.ascent + gap + rule : body.ascent,
                           descent: over ? body.descent : body.descent + gap + rule, kind: body.kind) { context, at in
                    body.draw(context, at)
                    let y = over ? at.y + body.ascent + gap : at.y - body.descent - gap - rule
                    context.fill(CGRect(x: at.x + size * 0.03, y: y, width: max(body.width - size * 0.06, size * 0.3), height: rule))
                }
            }
            let marks: [Accent: String] = [.hat: "\u{02C6}", .tilde: "\u{02DC}", .vec: "\u{2192}", .dot: "\u{02D9}", .ddot: "\u{00A8}",
                                           .check: "\u{02C7}", .breve: "\u{02D8}", .acute: "\u{00B4}", .grave: "`"]
            let mark = line(marks[accent] ?? "\u{02C6}", font(accent == .vec ? size * 0.75 : size, .upright))
            let wide = body.width > mark.width * 1.6 && accent != .dot && accent != .ddot
            let stretch = wide ? body.width / (mark.width * 1.1) : 1
            let lift = body.ascent + size * 0.06 - (accent == .vec ? size * 0.18 : size * 0.45)
            let width = max(body.width, mark.width)
            return Box(width: width, ascent: max(body.ascent, lift + mark.ascent) + size * 0.02, descent: body.descent, kind: body.kind) { context, at in
                body.draw(context, CGPoint(x: at.x + (width - body.width) / 2, y: at.y))
                context.saveGState()
                let markWidth = mark.width * stretch
                // An italic letter's accent sits a little to the right.
                context.translateBy(x: at.x + (width - markWidth) / 2 + (wide ? 0 : size * 0.04), y: at.y + lift)
                context.scaleBy(x: stretch, y: 1)
                mark.draw(context, .zero)
                context.restoreGState()
            }
        }

        static func table(_ rows: [[Node]], _ kind: Table, _ style: Style) -> Box {
            let cellStyle = kind == .centered ? style : style.text
            let cells = rows.map { $0.map { box($0, cellStyle) } }
            let columns = cells.map(\.count).max() ?? 0
            guard columns > 0 else { return .empty }
            let size = style.size
            var widths = [CGFloat](repeating: 0, count: columns)
            for row in cells { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.width) } }
            let strutUp = size * 0.7, strutDown = size * 0.3
            let gap = size * (kind == .centered ? 0.25 : 0.2)
            let heights = cells.map { row in (row.map(\.ascent).max().map { max($0, strutUp) } ?? strutUp, row.map(\.descent).max().map { max($0, strutDown) } ?? strutDown) }
            let total = heights.reduce(0) { $0 + $1.0 + $1.1 } + gap * CGFloat(max(0, heights.count - 1))
            func columnGap(_ index: Int) -> CGFloat {
                switch kind {
                case .matrix: return size * 0.9
                case .cases: return size * 1.0
                // "a &= b": the relation spaced from what it relates.
                case .aligned: return index % 2 == 1 ? size * 5 / 18 : size * 1.2
                case .centered: return 0
                }
            }
            var lefts: [CGFloat] = []
            var x: CGFloat = 0
            for index in 0..<columns {
                if index > 0 { x += columnGap(index) }
                lefts.append(x)
                x += widths[index]
            }
            let width = x
            let axis = self.axis(style)
            let ascent = total / 2 + axis
            let descent = total / 2 - axis
            return Box(width: width, ascent: ascent, descent: descent, kind: .inner) { context, at in
                var top = at.y + ascent
                for (rowIndex, row) in cells.enumerated() {
                    let baseline = top - heights[rowIndex].0
                    for (index, cell) in row.enumerated() {
                        let room = widths[index] - cell.width
                        let offset: CGFloat
                        switch kind {
                        case .matrix: offset = room / 2
                        case .cases: offset = 0
                        case .aligned: offset = index % 2 == 0 ? room : 0
                        case .centered: offset = (width - cell.width) / 2 - lefts[index]
                        }
                        cell.draw(context, CGPoint(x: at.x + lefts[index] + offset, y: baseline))
                    }
                    top = baseline - heights[rowIndex].1 - gap
                }
            }
        }
    }
}
