import Foundation

// One file for the Mac's chat column (ChatTranscript's ChatTable) and Yab
// for iPhone's chat (ChatMarkdown): a wide table's rows read as the same
// cards on both.

/// Which column of a wide table plays which part on its cards, decided
/// for the whole column so every card reads alike: a column of dates
/// over the title, the title, the long cells as words, the short ones in
/// the foot, and the source at the foot's end.
struct TableCards: Equatable {
    var kicker: Int?
    var title: Int
    var words: [Int]
    var foot: [Int]
    var source: Int?

    init(_ rows: [[String]]) {
        let head = rows.first ?? []
        let body = Array(rows.dropFirst())
        func cells(_ column: Int) -> [String] {
            body.map { Self.bare(column < $0.count ? $0[column] : "") }.filter { !$0.isEmpty }
        }
        let source = head.indices.first { column in
            let all = cells(column)
            return Self.sources.contains(head[column].lowercased()) || (!all.isEmpty && all.allSatisfy(Self.linkOnly))
        }
        let columns = head.indices.filter { $0 != source }
        let dated = columns.filter { column in
            let all = cells(column)
            return !all.isEmpty && all.allSatisfy(Self.dated)
        }
        let kicker: Int?
        let title: Int
        if let first = columns.first, dated.contains(first), columns.count > 1 {
            kicker = first
            title = columns[1]
        } else {
            title = columns.first ?? 0
            kicker = dated.first { $0 != title }
        }
        let rest = columns.filter { $0 != title && $0 != kicker }
        // Long on the whole: words of their own; short: the foot's.
        let words = rest.filter { column in
            let all = cells(column)
            return !all.isEmpty && all.reduce(0) { $0 + $1.count } / all.count > 36
        }
        self.source = source
        self.kicker = kicker
        self.title = title
        self.words = words
        foot = rest.filter { !words.contains($0) }
    }

    /// A row's cell in `column`, a dash read as nothing.
    func cell(_ row: [String], _ column: Int?) -> String {
        guard let column, column < row.count else { return "" }
        return Self.bare(row[column])
    }

    /// The foot's short cells in a line; a number keeps its label, which
    /// alone it wouldn't say.
    func footLine(_ row: [String], head: [String]) -> String {
        foot.compactMap { column in
            let value = cell(row, column)
            guard !value.isEmpty else { return nil }
            return Self.numeric(value) && column < head.count ? "\(head[column]) \(value)" : value
        }
        .joined(separator: " · ")
    }

    /// A cell that is a number, an amount or a share.
    static func numeric(_ cell: String) -> Bool {
        let bare = cell.trimmingCharacters(in: .whitespaces)
        return !bare.isEmpty && bare.range(of: #"^[~≈]?[-+]?[$€£¥]?\d[\d,.\s]*(%|k|m|min|h)?$"#, options: .regularExpression) != nil
    }

    static let sources: Set = ["source", "sources", "link", "links", "url"]

    static func bare(_ cell: String) -> String {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        return ["-", "\u{2013}", "\u{2014}"].contains(trimmed) ? "" : trimmed
    }

    /// A cell that is only a link: [name](address), or a bare address.
    static func linkOnly(_ cell: String) -> Bool {
        cell.range(of: #"^(\[[^\]]+\]\([^)\s]+\)|<?https?://\S+?>?)$"#, options: .regularExpression) != nil
    }

    /// A date or a time: 09:00, 2026-10-06, 6 Oct, October 6, Tue, tomorrow.
    static func dated(_ cell: String) -> Bool {
        guard cell.count <= 40 else { return false }
        let month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"
        let day = #"\b(mon|tue|wed|thu|fri|sat|sun|today|tomorrow|tonight)"#
        let pattern = #"\d{1,2}:\d{2}|\d{4}-\d{2}-\d{2}|\d\s*\.?\s*\b"# + month + #"|\b"# + month + #"\w*\.?\s+\d|"# + day + #"\b"#
        return cell.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The site a source goes to, for its mark.
    static func host(_ cell: String) -> String? {
        // A bare site, as an answer often names it: "x.com", "trtworld.com/live".
        let bare = cell.trimmingCharacters(in: .whitespaces)
        if bare.range(of: #"^(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return String(bare.split(separator: "/")[0]).replacingOccurrences(of: "www.", with: "").lowercased()
        }
        guard let range = cell.range(of: #"https?://[^/)\s>]+"#, options: .regularExpression) else { return nil }
        let host = cell[range].replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
        return host.isEmpty ? nil : host.lowercased()
    }

    /// A bare address said by its site's name, as a link still.
    static func named(_ cell: String) -> String {
        guard !cell.hasPrefix("["), let host = host(cell) else { return cell }
        var address = cell.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        if !address.lowercased().hasPrefix("http") { address = "https://" + address }
        return "[\(host)](\(address))"
    }
}
