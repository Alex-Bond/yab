import Foundation

// Where a new tab goes in the row, as Arc puts it (docs/tab-placement.md).
//
// A tab you ask for, ⌘T, the plus, a link from another app, a bookmark,
// goes to the top of today's tabs, under the line; with the tabs across
// the top, to the end of the strip, beside the plus. A tab a page opens, a ⌘-click, a middle click, a link that opens
// in a new tab, window.open, goes right after that page, after the tabs it
// already opened there, so a page's links stack below it in the order they
// were opened. From a pin or a kept tab, which stay above the line, they
// stack at the top of today's.

extension Browser {
    /// The index for a tab you asked for in a row of `count`: the top of
    /// today's in the column, under New Tab; the end of the strip, where
    /// its plus is, when the tabs are across the top.
    nonisolated static func askedLanding(count: Int, keptEnd: Int, strip: Bool) -> Int {
        strip ? count : min(max(keptEnd, 0), count)
    }

    /// The index for a tab the page at `source` opened, given each tab's
    /// `linkedFrom` in row order. `source` nil, or not in the row: the top
    /// of today's, as a tab you asked for.
    /// `paired`: the page is the left half of a Split View pair, its other
    /// half right after it; what it opens goes after the pair, as Arc puts
    /// it after the pair's one row.
    nonisolated static func linkLanding(source: Int?, linkedFrom: [UUID?], ids: [UUID], keptEnd: Int, paired: Bool = false) -> Int {
        let count = ids.count
        let top = min(max(keptEnd, 0), count)
        guard let source, ids.indices.contains(source) else { return top }
        let from = ids[source]
        // Below the page, or under the line when the page is above it.
        var at = source < keptEnd ? top : min(source + (paired ? 2 : 1), count)
        // Past what the page already opened there, and what those opened in
        // turn: a page's links keep together, in the order they came.
        var family: Set<UUID> = [from]
        while at < count, let parent = linkedFrom[at], family.contains(parent) {
            family.insert(ids[at])
            at += 1
        }
        return at
    }

    /// Where a tab `source`'s page opens goes now.
    func linkLanding(from source: Tab?) -> Int {
        let at = source.flatMap { source in tabs.firstIndex { $0 === source } }
        // The pair's other half right after the page: past both.
        let paired = at.map { at in
            tabs.indices.contains(at + 1) && source.flatMap { partner(of: $0) } === tabs[at + 1]
        } ?? false
        return Browser.linkLanding(source: at, linkedFrom: tabs.map(\.linkedFrom), ids: tabs.map(\.id), keptEnd: keptEnd, paired: paired)
    }
}
