import Foundation
import Testing
@testable import Fast

@MainActor
struct KeptBoundaryTests {
    private func world() -> (Browser, Folders, [Tab], () -> Void) {
        let window = UUID(), browser = Browser(windowID: window)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-\(window).json")
        let folders = Folders(emptiesFile: file)
        let tabs = (0..<3).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://boundary.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        tabs[0].kept = true
        browser.lay(tabs)
        browser.activeID = tabs[2].id
        folders.browser = browser
        return (browser, folders, tabs, {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window).json"))
        })
    }

    @Test func newFolderWithPickedTabsStaysOnItsSideOfTheLine() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.newFolder(picked: [tabs[1], tabs[2]])
        #expect(tabs[1].nest?.today == true && tabs[1].nest === tabs[2].nest)
        #expect(!tabs[1].kept && !tabs[2].kept)
    }

    @Test func newFolderWithAKeptTabAmongThePickedIsKept() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.newFolder(picked: [tabs[0], tabs[1]])
        #expect(tabs[0].nest?.today == false && tabs[0].nest === tabs[1].nest)
        #expect(tabs[0].kept && tabs[1].kept)
    }

    @Test func newFolderWithOneOfTodaysTabsIsKept() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.newFolder(picked: [tabs[1]])
        #expect(tabs[1].kept && tabs[1].nest?.today == false)
    }

    @Test func onlyKeptHasNewTabButNoLine() {
        let (browser, folders, tabs, done) = world(); defer { done() }
        browser.lay([tabs[0]])
        folders.refresh()
        let slots = folders.slots([tabs[0]])
        #expect(!folders.lined)
        #expect(slots.folders[Folders.line] == nil)
        #expect(slots.folders[Folders.newTab] == 1)
        #expect(PagedSpace.Coming.items([tabs[0]], active: nil).map(\.id) == [tabs[0].id.uuidString, "new-tab"])
    }

    @Test func todaysTabsGiveTheBoundaryTwoRows() {
        let (_, folders, tabs, done) = world(); defer { done() }
        let slots = folders.slots(tabs)
        #expect(folders.lined)
        #expect(slots.folders[Folders.line] == 1)
        #expect(slots.folders[Folders.newTab] == 2)
        #expect(slots.tabs[tabs[1].id] == 3)
    }

    /// As in Arc: today's tabs have the line over them, kept tabs or not.
    @Test func noKeptStillHasTheLine() {
        let (browser, folders, tabs, done) = world(); defer { done() }
        tabs[0].kept = false
        browser.lay(tabs)
        folders.refresh()
        let slots = folders.slots(tabs)
        #expect(folders.lined)
        #expect(slots.folders[Folders.line] == 0)
        #expect(slots.folders[Folders.newTab] == 1)
        #expect(slots.tabs[tabs[0].id] == 2)
        #expect(PagedSpace.Coming.items(tabs, active: nil).first?.id == "line")
    }

    @Test func closingLastTodayDoesNotSelectOrWakeKept() {
        let (browser, folders, tabs, done) = world(); defer { done() }
        browser.lay([tabs[0], tabs[2]])
        tabs[0].rest()
        browser.close(tabs[2])
        folders.refresh()
        #expect(browser.activeID == nil && browser.fieldShowing)
        #expect(tabs[0].asleep)
        #expect(!folders.lined)
        #expect(browser.canUndoClose(nativeEditor: false))
        browser.reopen()
        folders.refresh()
        #expect(browser.tabs.count == 2 && folders.lined)
        #expect(browser.active?.address?.path == "/2")
    }

    @Test func closingLastTodayOpenedFromKeptGoesBackToIt() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.lay([tabs[0], tabs[2]])
        _ = tabs[0].wake()
        tabs[2].from = tabs[0].id
        browser.close(tabs[2])
        #expect(browser.activeID == tabs[0].id)
        #expect(!browser.tabs.contains { $0 === tabs[2] })
    }

    /// Register #388: a kept source put down since is not woken for it.
    @Test func closingLastTodayOpenedFromKeptPutDownLeavesTheField() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.lay([tabs[0], tabs[2]])
        tabs[0].rest()
        tabs[2].from = tabs[0].id
        browser.close(tabs[2])
        #expect(browser.activeID == nil && browser.fieldShowing)
        #expect(tabs[0].asleep)
    }

    @Test func closingBatchLeavesKeptAsleep() {
        let (browser, _, tabs, done) = world(); defer { done() }
        tabs[0].rest()
        browser.close(Array(tabs.dropFirst()))
        #expect(browser.activeID == nil && browser.fieldShowing)
        #expect(tabs[0].asleep)
        browser.reopen()
        #expect(browser.tabs.count == 3)
    }

    @Test func undoCloseKeepsTextEditingInControl() {
        let (browser, _, tabs, done) = world(); defer { done() }
        browser.close(tabs[2])
        #expect(browser.canUndoClose(nativeEditor: false))
        #expect(!browser.canUndoClose(nativeEditor: true))
        browser.typed = "search"
        #expect(!browser.canUndoClose(nativeEditor: false))
        browser.typed = ""
        browser.active?.typing = true
        #expect(!browser.canUndoClose(nativeEditor: false))
    }

    @Test func dragPreviewCanCreateAndRemoveTheLine() {
        let (browser, folders, tabs, done) = world(); defer { done() }
        browser.lay([tabs[0], tabs[1]])
        folders.refresh()
        let allKept = folders.slots([tabs[0], tabs[1]], held: tabs[1].id, as: .init(kept: true))
        #expect(allKept.folders[Folders.line] == nil)
        #expect(allKept.folders[Folders.newTab] == 2)
        let allToday = folders.slots([tabs[0], tabs[1]], held: tabs[0].id, as: .init(kept: false))
        #expect(allToday.folders[Folders.line] == 0)
        #expect(allToday.folders[Folders.newTab] == 1)
    }

    @Test func clearFoldsTheLineWithItsLastRow() {
        let (_, _, tabs, done) = world(); defer { done() }
        #expect(Folders.showsLine(tabs, folded: [tabs[1].id]))
        #expect(!Folders.showsLine(tabs, folded: [tabs[1].id, tabs[2].id]))
    }

    @Test func agentFolderAloneKeepsTheLine() {
        let (_, folders, tabs, done) = world(); defer { done() }
        let session = Agents.shared.attach(name: "Boundary test")
        defer { Agents.shared.detach(session.id) }
        for tab in tabs.dropFirst() { tab.began = session.id }
        folders.refresh()
        #expect(folders.lined)
        #expect(folders.folders.contains { $0.id == session.id && $0.members.count == 2 })
    }

    @Test func emptyKeptFolderNeedsTodaysBeforeDrawingTheLine() {
        let (browser, folders, tabs, done) = world(); defer { done() }
        browser.lay([])
        let nest = folders.makeEmpty(named: "Empty")!
        #expect(!folders.lined)
        let empty = folders.slots([])
        #expect(empty.folders[nest.key] == 0)
        #expect(empty.folders[Folders.line] == nil)
        // An empty folder is one row, as in Arc (552875c0): no "Drag tabs
        // here" row under it any more.
        #expect(empty.folders[Folders.newTab] == 1)
        #expect(PagedSpace.Coming.items([], active: nil, empty: [nest]).map(\.id) == [nest.key, "new-tab"])
        browser.lay([tabs[1]])
        folders.refresh()
        #expect(folders.lined)
        #expect(folders.slots([tabs[1]]).folders[Folders.line] == 1)
    }
}
