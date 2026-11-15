import Foundation
import Testing
@testable import Fast

/// A collapsed folder keeps the split currently on screen as its existing
/// single row, even when the right half has focus. No page is navigated.
@MainActor
@Suite(.serialized)
struct CollapsedPairProjectionTests {
    @MainActor
    private final class World {
        let window = UUID()
        let browser: Browser
        let folders: Folders
        let outer: Nest
        let inner: Nest?
        let first = Tab(), second = Tab(), sibling = Tab(), today = Tab()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")

        init(secondActive: Bool, nested: Bool = false) {
            browser = Browser(windowID: window)
            outer = Nest(name: "Closed", open: false)
            inner = nested ? Nest(name: "Inner", open: true) : nil
            folders = Folders(emptiesFile: file)
            inner?.parent = outer
            for (index, tab) in [first, second, sibling, today].enumerated() {
                tab.restore(url: URL(string: "about:blank#collapsed-pair-\(index)")!, title: "Local \(index)")
                browser.prepare(tab)
            }
            for tab in [first, second, sibling] {
                tab.kept = true
                tab.nest = inner ?? outer
            }
            browser.lay([first, second, sibling, today])
            browser.pairs = [Pair(first: first.id, second: second.id)]
            browser.activeID = secondActive ? second.id : first.id
            folders.browser = browser
        }

        func done() {
            folders.browser = nil
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            try? FileManager.default.removeItem(at: file)
            Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
        }
    }

    private func checkPair(_ items: [ColumnItem], in world: World) {
        let shown = items.filter { $0.height > 0 }
        let pairs = shown.filter { if case .pair = $0.kind { return true }; return false }
        #expect(pairs.count == 1)
        if let row = pairs.first, case .pair(let first, let second) = row.kind {
            #expect(first === world.first && second === world.second)
            #expect(row.id == world.first.id.uuidString)
            #expect(row.indent == Folders.indent)
        }
        #expect(!shown.contains { item in
            if case .tab(let tab) = item.kind { return tab === world.first || tab === world.second || tab === world.sibling }
            return false
        })
        #expect(Set(shown.map(\.id)).count == shown.count)
    }

    private func checkLive(_ world: World) {
        #expect(!world.folders.isShut(world.browser.spaceID, in: world.browser))
        let order = world.browser.tabs.map(\.id)
        let active = world.browser.activeID
        let pairs = world.browser.pairs
        let items = ColumnLayout.live(world.browser, folders: world.folders)
        checkPair(items, in: world)
        let slots = world.folders.slots(world.browser.tabs, joined: true)
        #expect(slots.tabs[world.first.id] == slots.tabs[world.second.id])
        for item in items where item.height > 0 {
            guard let tab = item.tab, let slot = slots.tabs[tab.id] else { continue }
            #expect(item.y == ColumnLayout.y(Double(slot), line: slots.folders[Folders.line]))
        }
        #expect(world.folders.place(of: world.sibling)?.shown == false)
        #expect(world.browser.tabs.map(\.id) == order)
        #expect(world.browser.activeID == active)
        #expect(world.browser.pairs == pairs)
        #expect(!world.outer.open)
        #expect(world.inner?.open ?? true)
        for tab in [world.first, world.second, world.sibling] {
            #expect(tab.nest === (world.inner ?? world.outer))
            #expect(tab.kept)
            #expect(tab.builtPage == nil)
        }
    }

    @Test func secondHalfFocusedInClosedFolderKeepsItsExistingPairRow() {
        let world = World(secondActive: true)
        defer { world.done() }
        checkLive(world)
    }

    @Test func firstHalfFocusedAlsoKeepsExactlyOnePairRowAndOneSlot() {
        let world = World(secondActive: false)
        defer { world.done() }
        checkLive(world)
    }

    @Test func closedOuterFolderKeepsTheFocusedInnerPairAtOneIndent() {
        let world = World(secondActive: true, nested: true)
        defer { world.done() }
        checkLive(world)
        let items = ColumnLayout.live(world.browser, folders: world.folders)
        #expect(!items.contains { $0.id == world.inner?.key })
    }

    @Test func parkedSpaceKeepsTheSecondFocusedHalfsExistingPairRow() {
        let world = World(secondActive: true)
        defer { world.done() }
        let row = Parked(tabs: world.browser.tabs, active: world.second.id, pairs: world.browser.pairs)
        let laid = ColumnLayout.parked(world.browser, row: row, travelling: [], space: world.browser.space)
        checkPair(laid.items, in: world)
        #expect(world.browser.activeID == world.second.id)
        #expect(!world.outer.open)
        #expect(world.first.builtPage == nil && world.second.builtPage == nil)
    }
}
