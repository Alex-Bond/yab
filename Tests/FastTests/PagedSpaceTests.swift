import Foundation
import Testing
@testable import Fast

// A space's row drawn beside the column's while its spaces slide
// (SpacePager): its folders as the column lays them, not their tabs spilled
// out of a folder that is shut.
@MainActor
struct PagedSpaceTests {
    static func ids(_ items: [PagedSpace.Coming]) -> [String] { items.map(\.id) }

    @Test func aTasksTabsComeFolded() {
        // Yours, then a task's two that go with you from space to space.
        let mine = Tab()
        let first = Tab(bench: true), second = Tab(bench: true)
        first.agent = "paged-task"
        second.agent = "paged-task"
        let row = [mine, first, second]
        let shut = PagedSpace.Coming.items(row, active: mine.id)
        #expect(Self.ids(shut) == ["line", mine.id.uuidString, "paged-task"])
        let open = PagedSpace.Coming.items(row, active: mine.id, open: ["paged-task"])
        #expect(Self.ids(open) == ["line", mine.id.uuidString, "paged-task", first.id.uuidString, second.id.uuidString])
    }

    @Test func anOpenTaskShowsFourAndMore() {
        let tabs = (0..<6).map { _ in Tab(bench: true) }
        for tab in tabs { tab.agent = "many" }
        let items = PagedSpace.Coming.items(tabs, active: nil, open: ["many"])
        #expect(Self.ids(items) == ["line", "many"] + tabs.prefix(4).map(\.id.uuidString) + ["more many"])
        let whole = PagedSpace.Coming.items(tabs, active: nil, open: ["many"], whole: ["many"])
        #expect(Self.ids(whole) == ["line", "many"] + tabs.map(\.id.uuidString))
    }

    @Test func aSearchsFolderAmongTodaysComesFolded() {
        let nest = Nest(name: "Flights", open: false, search: "flights")
        let first = Tab(), second = Tab(), loose = Tab()
        first.nest = nest
        second.nest = nest
        let items = PagedSpace.Coming.items([first, second, loose], active: loose.id)
        #expect(Self.ids(items) == ["line", Nest.key(nest.id), loose.id.uuidString])
        // The one to be on screen is shown under it, shut or not.
        let onIt = PagedSpace.Coming.items([first, second, loose], active: second.id)
        #expect(Self.ids(onIt) == ["line", Nest.key(nest.id), second.id.uuidString, loose.id.uuidString])
    }

    @Test func keptFoldersAndTheLineStayAsTheyWere() {
        let nest = Nest(name: "Work", open: true)
        let kept = Tab(), today = Tab()
        kept.kept = true
        kept.nest = nest
        let items = PagedSpace.Coming.items([kept, today], active: today.id)
        #expect(Self.ids(items) == [Nest.key(nest.id), kept.id.uuidString, "line", today.id.uuidString])
    }
}

// The same on top: the next space's row coming up in the strip while two
// fingers take it there (StripComing), its run as long as the strip's
// will be once the space is here.
@MainActor
struct StripComingTests {
    static func ids(_ items: [StripItem]) -> [String] { items.map(\.id) }

    @Test func aTasksTabsComeFolded() {
        let mine = Tab()
        let first = Tab(bench: true), second = Tab(bench: true)
        first.agent = "strip-task"
        second.agent = "strip-task"
        let row = [mine, first, second]
        let shut = StripItem.items(row, active: mine.id)
        #expect(Self.ids(shut) == [mine.id.uuidString, "strip-task"])
        let open = StripItem.items(row, active: mine.id, open: ["strip-task"])
        #expect(Self.ids(open) == [mine.id.uuidString, "strip-task", first.id.uuidString, second.id.uuidString])
    }

    @Test func aShutTasksFolderIsOnePill() {
        // Shut, the folder takes one tab's share and its tabs none: the run
        // is two shares, not three.
        let mine = Tab()
        let first = Tab(bench: true), second = Tab(bench: true)
        first.agent = "strip-run"
        second.agent = "strip-run"
        let items = StripItem.items([mine, first, second], active: mine.id)
        let widths = StripItem.widths(items, active: mine.id, open: [], room: 2000)
        #expect(abs(widths.content - (widths.activeOuter + widths.outer + Metrics.tabGap)) < 0.5)
    }

    @Test func anOpenTasksFolderShowsFourAndMore() {
        let tabs = (0..<6).map { _ in Tab(bench: true) }
        for tab in tabs { tab.agent = "strip-many" }
        let items = StripItem.items(tabs, active: nil, open: ["strip-many"])
        #expect(Self.ids(items) == ["strip-many"] + tabs.prefix(4).map(\.id.uuidString) + ["more strip-many"])
        let widths = StripItem.widths(items, active: nil, open: ["strip-many"], room: 4000)
        let expected = StripWidths.pillWidth(Folders.title("strip-many")) + 4 * widths.inner + StripWidths.moreWidth + 5 * Metrics.tabGap
        #expect(abs(widths.content - expected) < 0.5)
    }
}
