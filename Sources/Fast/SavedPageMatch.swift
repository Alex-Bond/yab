import Foundation

/// Names are words, rather than arbitrary substrings of a title or URL path.
enum SavedPageMatch {
    static func matches(_ text: String, title: String, url: URL?) -> Bool {
        let words = Wording.split(text.lowercased())
        guard !words.isEmpty else { return false }
        let names = Wording.split(title.lowercased()) + Wording.split(url?.host()?.lowercased() ?? "")
        return words.allSatisfy { word in names.contains { $0.hasPrefix(word) } }
    }
}

extension Browser {
    /// Saved names get their own pass so a frequent history entry cannot
    /// crowd a bookmark out of the history provider's limited result set.
    func savedPageRows(matching text: String) -> [Suggestion] {
        var rows: [Suggestion] = []
        var seen = Set<String>()
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                if let children = node.children { walk(children) }
                guard let address = node.url, let url = URL(string: address), Bookmark.keepable(url),
                      SavedPageMatch.matches(text, title: node.title, url: url) else { continue }
                let key = History.key(for: url)
                guard seen.insert(key).inserted else { continue }
                rows.append(Suggestion(key: key, title: node.title, url: url, kind: .visited, bookmarked: true))
            }
        }
        walk(bookmarks.roots)
        return rows
    }
}
