import Foundation

// A host is kept and sent in its xn-- form; this is how it is read. Each
// xn-- label is decoded (RFC 3492) unless the name could pass for another
// one, by the rules of Chromium's IDN spoof checker: one label that fails keeps
// the whole host in xn-- form, so "аpple.com" with a Cyrillic а never reads
// as Apple's.
enum IDN {
    /// The host as a person reads it: münchen.de for xn--mnchen-3ya.de, or
    /// the host as it came when any label of it is not safe to show.
    static func shown(_ host: String) -> String {
        guard host.range(of: "xn--", options: .caseInsensitive) != nil else { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let decoded = labels.map { label -> String? in
            guard label.lowercased().hasPrefix("xn--") else { return String(label) }
            return decode(label.dropFirst(4))
        }
        guard decoded.allSatisfy({ $0 != nil }) else { return host }
        let words = decoded.map { $0! }
        let tld = words.last ?? ""
        for (label, word) in zip(labels, words) where label.lowercased().hasPrefix("xn--") {
            guard safe(word, tld: tld) else { return host }
        }
        return words.joined(separator: ".")
    }

    /// An address as the field and the rows say it, host first, the rest
    /// as it was: "xn--mnchen-3ya.de/rathaus" reads "münchen.de/rathaus".
    static func shownAddress(_ text: String) -> String {
        guard text.range(of: "xn--", options: .caseInsensitive) != nil else { return text }
        let end = text.firstIndex { $0 == "/" || $0 == ":" || $0 == "?" || $0 == "#" } ?? text.endIndex
        return shown(String(text[..<end])) + text[end...]
    }

    // MARK: Punycode

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 0x80

    /// One label's punycode, the part after xn--, decoded, or nil when it
    /// is not punycode or decodes to plain ASCII, which never needs it.
    static func decode(_ encoded: Substring) -> String? {
        let input = Array(encoded.lowercased().unicodeScalars)
        guard !input.isEmpty, input.allSatisfy(\.isASCII) else { return nil }
        var output: [Unicode.Scalar] = []
        var rest = input[...]
        if let dash = input.lastIndex(of: "-") {
            output = Array(input[..<dash])
            rest = input[(dash + 1)...]
        }
        var n = initialN, i = 0, bias = initialBias
        var position = rest.startIndex
        while position < rest.endIndex {
            let old = i
            var w = 1, k = base
            while true {
                guard position < rest.endIndex, let digit = digit(rest[position]) else { return nil }
                position += 1
                let (step, over) = digit.multipliedReportingOverflow(by: w)
                guard !over, i <= Int(Int32.max) - step else { return nil }
                i += step
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if digit < t { break }
                let (wider, overW) = w.multipliedReportingOverflow(by: base - t)
                guard !overW, wider <= Int(Int32.max) else { return nil }
                w = wider
                k += base
            }
            let count = output.count + 1
            bias = adapt(i - old, count: count, first: old == 0)
            n += i / count
            i %= count
            guard n <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        guard output.contains(where: { !$0.isASCII }) else { return nil }
        var text = ""
        text.unicodeScalars.append(contentsOf: output)
        return text
    }

    private static func digit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x61...0x7A: Int(scalar.value - 0x61)
        case 0x30...0x39: Int(scalar.value - 0x30) + 26
        default: nil
        }
    }

    private static func adapt(_ delta: Int, count: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    // MARK: Spoof check

    enum Script: Hashable {
        case latin, greek, cyrillic, armenian, hebrew, arabic, georgian, thai, lao, hangul
        case hiragana, katakana, bopomofo, han, ethiopic, khmer, tibetan, myanmar, sinhala
        case indic(UInt32)
        /// Somewhere no rule here names: one 128-letter stretch of Unicode,
        /// so two of them never pass as one script.
        case other(UInt32)
    }

    /// Scripts a Japanese, Chinese or Korean name mixes with Latin, Chrome's
    /// "highly restrictive" sets; any other mix is a spoof.
    private static let together: [Set<Script>] = [
        [.latin, .han, .hiragana, .katakana],
        [.latin, .han, .bopomofo],
        [.latin, .han, .hangul],
    ]

    /// Letters of a script that pass for Latin ones (Chrome's
    /// idn_spoof_checker whole-script lists): a label made of only these
    /// reads as a Latin word.
    private static let latinLike: [Script: Set<Character>] = [
        .cyrillic: Set("аысԁеԍһіюјӏорԗԛѕԝхуъьҽпгѵѡ"),
        .greek: Set("αικνορτυχ"),
    ]

    /// Top-level domains of a script's own countries, where a whole word in
    /// it is the ordinary thing (пример.рф, κάτι.gr).
    private static let home: [Script: Set<String>] = [
        .cyrillic: ["ru", "su", "рф", "by", "бел", "bg", "бг", "kz", "қаз", "kg", "mk", "мкд", "mn", "мон",
                    "rs", "срб", "ua", "укр", "uz", "tj", "рус", "москва", "дети", "сайт", "онлайн", "орг", "ком"],
        .greek: ["gr", "ελ", "cy", "eu", "ευ"],
    ]

    /// Letters that read as another letter or as punctuation wherever they
    /// stand: dotless i and j, the IPA letters, clicks like a pipe, the kra.
    private static func lookalike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0131, 0x0237, 0x0138, 0x01C0...0x01C3, 0x0250...0x02AF, 0x0589, 0x05C0, 0x05C3, 0x05F3, 0x05F4,
             0x0F0B, 0x3007, 0x30FB:
            true
        default: false
        }
    }

    /// Whether a decoded label is safe to show, given the host's last label.
    static func safe(_ label: String, tld: String) -> Bool {
        // A label written in its stored form already: lowercase, composed,
        // nothing that folds into something else (fullwidth, ligatures).
        guard !label.isEmpty, label == label.precomposedStringWithCanonicalMapping else { return false }
        var scripts: Set<Script> = []
        var digits: Set<UInt32> = []   // each run of 0–9 a number's script uses
        var before: Unicode.Scalar?
        for scalar in label.unicodeScalars {
            defer { before = scalar }
            if scalar == "-" { continue }
            let properties = scalar.properties
            if properties.changesWhenNFKCCaseFolded || lookalike(scalar) { return false }
            switch properties.generalCategory {
            case .decimalNumber:
                digits.insert(scalar.value - UInt32(properties.numericValue ?? 0))
                continue
            case .nonspacingMark, .spacingMark:
                // A mark goes on a letter, once: not on a digit or a hyphen,
                // not stacked twice the same, as "i̇̇" hides a dot.
                guard let before, before != scalar, before.properties.isAlphabetic,
                      before.properties.generalCategory != .decimalNumber else { return false }
                continue
            case .lowercaseLetter, .otherLetter:
                break
            case .modifierLetter:
                // Only the kana marks that lengthen and repeat.
                guard [0x30FC, 0x309D, 0x309E, 0x30FD, 0x30FE, 0x3005].contains(scalar.value) else { return false }
                continue
            default:
                return false
            }
            scripts.insert(script(scalar))
        }
        // Digits from two systems, 0 and ٠, read as the same number.
        if digits.count > 1 { return false }
        if scripts.count > 1, !together.contains(where: scripts.isSubset) { return false }
        // A whole word of look-alikes, "аррӏе", outside its script's own
        // countries reads as the Latin word it imitates.
        if scripts.count == 1, let only = scripts.first, let like = latinLike[only],
           label.allSatisfy({ like.contains($0) || $0.isASCII }),
           !(home[only]?.contains(tld.lowercased()) ?? false) {
            return false
        }
        return true
    }

    static func script(_ scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F: .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF: .greek
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: .cyrillic
        case 0x0530...0x058F: .armenian
        case 0x0590...0x05FF: .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF: .arabic
        case 0x0900...0x0D7F: .indic(scalar.value >> 7)
        case 0x0D80...0x0DFF: .sinhala
        case 0x0E00...0x0E7F: .thai
        case 0x0E80...0x0EFF: .lao
        case 0x0F00...0x0FFF: .tibetan
        case 0x1000...0x109F: .myanmar
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F: .georgian
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: .hangul
        case 0x1200...0x139F: .ethiopic
        case 0x1780...0x17FF: .khmer
        case 0x3040...0x309F: .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF: .katakana
        case 0x3100...0x312F, 0x31A0...0x31BF: .bopomofo
        case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: .han
        default: .other(scalar.value >> 7)
        }
    }
}
