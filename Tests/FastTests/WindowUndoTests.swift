import Foundation
import Testing
@testable import Fast

// ⌘Z in the window: the last thing done by hand comes back, newest first,
// closed tabs among the rest (WindowUndo.swift).
@Suite(.serialized)
@MainActor
struct WindowUndoTests {
    private func withTabs(_ count: Int, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<count).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://undo.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        Browser.pretendHand = true
        defer {
            Browser.pretendHand = false
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        try body(browser, tabs)
    }

    @Test func aPinComesUndoneInItsPlace() {
        withTabs(4) { browser, tabs in
            browser.pin(tabs[2])
            #expect(browser.tabs.first === tabs[2])
            #expect(browser.undoWindow())
            #expect(tabs[2].pin == nil)
            #expect(browser.tabs.map(\.id) == tabs.map(\.id))
        }
    }

    @Test func theLastThingDoneComesBackBeforeAnEarlierClose() {
        withTabs(4) { browser, tabs in
            browser.activeID = tabs[0].id
            browser.close(tabs[3])
            browser.pin(tabs[1])
            #expect(browser.undoWindow())
            #expect(tabs[1].pin == nil)
            #expect(browser.tabs.count == 3)
            #expect(browser.undoWindow())
            #expect(browser.tabs.count == 4)
            #expect(browser.tabs.last.flatMap { $0.pending ?? $0.address } == URL(string: "https://undo.test/3"))
        }
    }

    @Test func aNameComesBack() {
        withTabs(2) { browser, tabs in
            browser.beginTabEdit(tabs[1])
            browser.tabDraft = "Mine"
            browser.commitTabEdit()
            #expect(tabs[1].name == "Mine")
            #expect(browser.undoWindow())
            #expect(tabs[1].name == nil)
        }
    }

    /// Brought back by ⌘⇧T already, the close is passed over.
    @Test func aCloseReopenedAnotherWayIsPassedOver() {
        withTabs(3) { browser, tabs in
            browser.activeID = tabs[0].id
            browser.pin(tabs[1])
            browser.close(tabs[2])
            browser.reopen()
            #expect(browser.tabs.count == 3)
            #expect(browser.undoWindow())
            #expect(tabs[1].pin == nil)
            #expect(browser.tabs.count == 3)
        }
    }

    @Test func keptInAFolderGoesBackLoose() {
        withTabs(3) { browser, tabs in
            browser.newFolder(with: [tabs[0], tabs[1]])
            defer { Folders.shared.naming = nil }
            #expect(tabs[0].kept && tabs[0].nest != nil)
            #expect(browser.undoWindow())
            #expect(!tabs[0].kept && tabs[0].nest == nil && !tabs[1].kept)
            #expect(browser.tabs.map(\.id) == tabs.map(\.id))
        }
    }

    // Register #463: what is removed from the column comes back by ⌘Z
    // where it stood, as Arc's does, not at the end of its list.

    private func address(_ tab: Tab) -> URL? { tab.pending ?? tab.address }
    private func addresses(_ list: some Sequence<Tab>) -> [URL?] { list.map { $0.pending ?? $0.address } }

    @Test func anUnpinnedPinComesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            browser.pin(Array(tabs[0..<4]))
            browser.steps = []
            #expect(browser.tabs.prefix(4).map(\.id) == tabs[0..<4].map(\.id))
            browser.unpin(tabs[1])
            #expect(tabs[1].pin == nil && browser.pinnedCount == 3)
            #expect(browser.undoWindow())
            #expect(tabs[1].pin != nil)
            #expect(browser.tabs.map(\.id) == tabs.map(\.id))
        }
    }

    @Test func aPinUnpinnedByItsKeyComesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            browser.pin(Array(tabs[0..<4]))
            browser.steps = []
            browser.activeID = tabs[1].id
            browser.togglePin()
            #expect(tabs[1].pin == nil)
            #expect(browser.undoWindow())
            #expect(browser.tabs.map(\.id) == tabs.map(\.id) && tabs[1].pin != nil)
        }
    }

    /// Dragged out of the pins into today's: the drag's one step.
    @Test func aPinDraggedOutComesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            browser.pin(Array(tabs[0..<4]))
            browser.steps = []
            browser.holdArranging()
            browser.unpin(tabs[1])
            browser.move(tabs[1], to: browser.pinnedCount + 1)
            browser.letGoArranging()
            #expect(tabs[1].pin == nil)
            #expect(browser.undoWindow())
            #expect(browser.tabs.map(\.id) == tabs.map(\.id) && tabs[1].pin != nil)
        }
    }

    /// Close and Don't Keep, a kept row's cross or its middle button: back
    /// kept, second of four, not last.
    @Test func aKeptTabRemovedComesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            let urls = addresses(tabs)
            browser.keepTabs(Array(tabs[0..<4]))
            browser.steps = []
            browser.activeID = tabs[5].id
            browser.discard([tabs[1]], rekept: true)
            #expect(browser.tabs.count == 5 && browser.keptCount == 3)
            #expect(browser.ghosts.last?.kept == true)
            #expect(browser.ghosts.last?.keptAt == 1)
            #expect(browser.undoWindow())
            #expect(browser.keptCount == 4)
            #expect(addresses(browser.tabs) == urls)
            #expect(browser.tabs[1].kept)
        }
    }

    @Test func aKeptTabRemovedComesBackInItsPlaceByReopenToo() {
        withTabs(6) { browser, tabs in
            let urls = addresses(tabs)
            browser.keepTabs(Array(tabs[0..<4]))
            browser.steps = []
            browser.activeID = tabs[5].id
            browser.discard([tabs[1]], rekept: true)
            browser.reopen()
            #expect(addresses(browser.tabs) == urls && browser.tabs[1].kept)
        }
    }

    /// Don't Keep: under the line, and ⌘Z puts it back above it in place.
    @Test func aTabNoLongerKeptGoesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            browser.keepTabs(Array(tabs[0..<4]))
            browser.steps = []
            browser.releaseTabs([tabs[1]])
            #expect(!tabs[1].kept)
            #expect(browser.undoWindow())
            #expect(browser.tabs.map(\.id) == tabs.map(\.id) && tabs[1].kept)
        }
    }

    /// Remove from Folder: back in the folder, second of its four.
    @Test func aTabRemovedFromAFolderComesBackInItsPlace() {
        withTabs(6) { browser, tabs in
            let urls = addresses(tabs)
            browser.newFolder(with: Array(tabs[0..<4]))
            defer { Folders.shared.naming = nil }
            let nest = tabs[0].nest
            browser.steps = []
            browser.activeID = tabs[5].id
            browser.discard([tabs[1]], rekept: true)
            #expect(browser.tabs.count == 5)
            #expect(browser.undoWindow())
            #expect(addresses(browser.tabs) == urls)
            #expect(browser.tabs[1].kept && browser.tabs[1].nest === nest)
        }
    }

    /// Remove Folder and its tabs, the second of four folders, one of two
    /// tabs: the folder back second, its tabs in their order.
    @Test func aRemovedFolderComesBackInItsPlace() {
        withTabs(7) { browser, tabs in
            let urls = addresses(tabs)
            defer { Folders.shared.naming = nil }
            browser.newFolder(with: [tabs[0]])
            browser.newFolder(with: [tabs[1], tabs[2]])
            browser.newFolder(with: [tabs[3]])
            browser.newFolder(with: [tabs[4]])
            #expect(addresses(browser.tabs) == urls)
            let folders = browser.nests
            #expect(folders.count == 4)
            browser.steps = []
            browser.activeID = tabs[6].id
            browser.removeFolder(folders[1], with: [tabs[1], tabs[2]])
            #expect(browser.nests.count == 3 && browser.tabs.count == 5)
            #expect(browser.undoWindow())
            #expect(addresses(browser.tabs) == urls)
            #expect(browser.nests.map(ObjectIdentifier.init) == folders.map(ObjectIdentifier.init))
            #expect(browser.tabs[1].nest === folders[1] && browser.tabs[2].nest === folders[1])
        }
    }

    /// The row changed since: never past the end, and inside its folder.
    @Test func aKeptTabComesBackInsideItsFolderWhenTheRowChanged() {
        withTabs(7) { browser, tabs in
            defer { Folders.shared.naming = nil }
            browser.keepTabs([tabs[0]])
            browser.newFolder(with: [tabs[1], tabs[2], tabs[3]])
            let nest = tabs[1].nest
            browser.steps = []
            browser.activeID = tabs[6].id
            browser.discard([tabs[3]], rekept: true)
            // Meanwhile the one before the folder no longer kept: its old
            // place is past the end of the kept, ⌘⇧T brings it back last
            // in its folder.
            browser.releaseTabs([tabs[0]])
            browser.reopen()
            let kept = browser.tabs.filter(\.kept)
            #expect(kept.count == 3 && kept.allSatisfy { $0.nest === nest })
            #expect(address(kept[2]) == address(tabs[3]))
        }
    }

    /// Unpin Pair on the second square of four: the square back second.
    @Test func anUnpinnedPairComesBackInItsPlace() throws {
        try withTabs(5) { browser, tabs in
            browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
            browser.pin([tabs[0], tabs[3], tabs[4]])
            browser.select(tabs[1])
            browser.split(tabs[2], with: tabs[1])
            let pair = try #require(browser.pair(of: tabs[1].id))
            browser.pinPair(pair, cell: 1)
            let grid = browser.gridPins.map(\.id)
            #expect(grid == [tabs[0].id, tabs[1].id, tabs[3].id, tabs[4].id])
            let row = browser.tabs.map(\.id)
            browser.steps = []
            browser.unpinPair(pair)
            #expect(browser.pinPair(of: tabs[1].id) == nil)
            #expect(browser.undoWindow())
            #expect(browser.gridPins.map(\.id) == grid)
            #expect(browser.tabs.map(\.id) == row)
            #expect(browser.pinPair(of: tabs[1].id) == pair)
        }
    }

    @Test func notByHandLeavesNoStep() {
        withTabs(2) { browser, tabs in
            Browser.pretendHand = false
            // A suite run just before may leave its sent mouse events as
            // NSApp.currentEvent for 1.5 s, which reads as a hand. An agent's
            // change is never by hand, whatever event came last.
            let acting = PageView.agentActing
            PageView.agentActing = true
            defer { PageView.agentActing = acting }
            browser.pin(tabs[1])
            #expect(!browser.canUndoWindow)
        }
    }
}
