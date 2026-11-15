import Foundation
import Testing
@testable import Fast

// A space folded under its name in the column (SpaceName, Folders.fold), as
// Arc folds a space's pinned tabs: its kept tabs, its folders and the empty
// ones out of sight, the one on screen under the name as a row of its own,
// the line and today's as they were.
@MainActor
struct SpaceFoldTests {
    static func ids(_ items: [PagedSpace.Coming]) -> [String] { items.map(\.id) }

    @Test func keptGoTodaysStay() {
        let first = Tab(), second = Tab(), today = Tab()
        first.kept = true
        second.kept = true
        let row = [first, second, today]
        let open = PagedSpace.Coming.items(row, active: today.id)
        #expect(Self.ids(open) == [first.id.uuidString, second.id.uuidString, "line", today.id.uuidString])
        let shut = PagedSpace.Coming.items(row, active: today.id, shut: true)
        #expect(Self.ids(shut) == ["line", today.id.uuidString])
    }

    @Test func foldersAndEmptyOnesGoToo() {
        let nest = Nest(name: "Work", open: true)
        let empty = Nest(name: "Later", open: true)
        let kept = Tab(), today = Tab()
        kept.kept = true
        kept.nest = nest
        let shut = PagedSpace.Coming.items([kept, today], active: today.id, empty: [empty], shut: true)
        #expect(Self.ids(shut) == ["line", today.id.uuidString])
    }

    @Test func theOneOnScreenStaysUnderTheNameInNoFolder() {
        let outer = Nest(name: "Work", open: false)
        let inner = Nest(name: "Docs", open: true)
        inner.parent = outer
        let deep = Tab(), loose = Tab(), today = Tab()
        deep.kept = true
        deep.nest = inner
        loose.kept = true
        let row = [deep, loose, today]
        let onDeep = PagedSpace.Coming.items(row, active: deep.id, shut: true)
        #expect(Self.ids(onDeep) == [deep.id.uuidString, "line", today.id.uuidString])
        if case .tab(_, let depth) = onDeep[0] { #expect(depth == 0) } else { Issue.record("not a tab's row") }
        let onLoose = PagedSpace.Coming.items(row, active: loose.id, shut: true)
        #expect(Self.ids(onLoose) == [loose.id.uuidString, "line", today.id.uuidString])
    }

    @Test func nothingKeptNothingFolds() {
        let today = Tab()
        let shut = PagedSpace.Coming.items([today], active: today.id, shut: true)
        #expect(Self.ids(shut) == ["line", today.id.uuidString])
    }

    @Test func foldSaysWhatGoesAndHowMany() {
        let nest = Nest(name: "Work", open: true)
        let inNest = Tab(), alone = Tab(), onScreen = Tab(), half = Tab(), today = Tab()
        for tab in [inNest, alone, onScreen, half] { tab.kept = true }
        inNest.nest = nest
        let tabs = [inNest, alone, onScreen, half, today]
        let made = Folders.nests(in: tabs)
        var placed = Folders.lay(made, isOpen: { Folders.isOpen($0, among: []) }, whole: [], folding: [], active: onScreen.id).places
        // `half` is the other half of the pair on screen: it stays with it.
        let out = Folders.fold(&placed, tabs: tabs, active: onScreen.id, asking: [],
                               partner: { $0 == half.id ? onScreen.id : $0 == onScreen.id ? half.id : nil }, listed: false)
        #expect(out.away == [alone.id])
        #expect(out.hidden == 2)
        let place = placed[inNest.id]
        #expect(place?.shown == false)
        #expect(place?.bare == true)
        #expect(place?.heads.isEmpty == true)
        #expect(place?.listed == false)
        #expect(placed[today.id] == nil)
    }

    @Test func foldingKeepsThemListedForTheTurn() {
        let nest = Nest(name: "Work", open: true)
        let kept = Tab(), today = Tab()
        kept.kept = true
        kept.nest = nest
        let tabs = [kept, today]
        var placed = Folders.lay(Folders.nests(in: tabs), isOpen: { Folders.isOpen($0, among: []) }, whole: [], folding: [], active: today.id).places
        _ = Folders.fold(&placed, tabs: tabs, active: today.id, asking: [], partner: { _ in nil }, listed: true)
        #expect(placed[kept.id]?.listed == true)
        #expect(placed[kept.id]?.shown == false)
    }
}
