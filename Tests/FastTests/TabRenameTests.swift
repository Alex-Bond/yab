import AppKit
import Foundation
import Testing
@testable import Fast

// Renaming a tab in the column: a double-click opens the field, and an edit
// whose tab went away is put down rather than left holding the keys.
@Suite(.serialized)
@MainActor
struct TabRenameTests {
    private func withTabs(_ count: Int, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        let (browser, tabs, done) = setUp(count)
        defer { done() }
        try body(browser, tabs)
    }

    /// The same, for a test that waits: `await` lets the main queue's
    /// work run, which a run loop turned inside the test cannot.
    private func withTabs(_ count: Int, _ body: (Browser, [Tab]) async throws -> Void) async rethrows {
        let (browser, tabs, done) = setUp(count)
        defer { done() }
        try await body(browser, tabs)
    }

    private func setUp(_ count: Int) -> (Browser, [Tab], () -> Void) {
        let window = UUID(), browser = Browser(windowID: window)
        let tabs = (0..<count).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://rename.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        return (browser, tabs, {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        })
    }

    @Test func twoTapsOnOneTabOpenTheField() {
        withTabs(2) { browser, tabs in
            browser.tapTab(tabs[1])
            #expect(browser.editingTab == nil)
            browser.tapTab(tabs[1])
            #expect(browser.editingTab == tabs[1].id)
            browser.cancelTabEdit()
        }
    }

    // MARK: the field and the keys (feedback #1899, #1902)

    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// A window never put on screen: the keys move in it all the same.
    private func testWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The field as a row being renamed makes it, not yet in any window.
    private func makeField(_ browser: Browser, for tab: Tab) -> (TabAddressField.TabNameField, TabAddressField.Coordinator) {
        let coordinator = TabAddressField.Coordinator(browser: browser)
        coordinator.editing = tab.id
        let field = TabAddressField.TabNameField(frame: NSRect(x: 10, y: 10, width: 200, height: 20))
        coordinator.hold(field)
        return (field, coordinator)
    }

    /// A long session's column put the row on screen after the field's
    /// 0.2 s claim had given up: the edit stayed open with no keys.
    @Test func aFieldThatReachesItsWindowLateTakesTheKeys() async throws {
        try await withTabs(2) { browser, tabs in
            browser.beginTabEdit(tabs[1])
            let (field, coordinator) = makeField(browser, for: tabs[1])
            coordinator.claim()
            try await spin(0.5)
            let window = testWindow()
            defer { window.close() }
            window.contentView?.addSubview(field)
            try await spin(0.1)
            #expect(coordinator.hasKeys)
            #expect(browser.editingTab == tabs[1].id)
            browser.cancelTabEdit()
        }
    }

    /// Rename asked for again, the same tab's: its field takes the keys
    /// again, though nothing it shows has changed.
    @Test func renameAskedAgainTakesTheKeysAgain() async throws {
        try await withTabs(2) { browser, tabs in
            let window = testWindow()
            defer { window.close() }
            let other = NSTextField(frame: NSRect(x: 10, y: 40, width: 200, height: 20))
            window.contentView?.addSubview(other)
            browser.beginTabEdit(tabs[1])
            let (field, coordinator) = makeField(browser, for: tabs[1])
            window.contentView?.addSubview(field)
            try await spin(0.1)
            #expect(coordinator.hasKeys)
            // The keys gone elsewhere (that edit put down), the field still up.
            window.makeFirstResponder(other)
            try await spin(0.1)
            #expect(browser.editingTab == nil)
            browser.beginTabEdit(tabs[1])
            try await spin(0.1)
            #expect(browser.editingTab == tabs[1].id)
            #expect(coordinator.hasKeys)
            browser.cancelTabEdit()
        }
    }

    /// Refused the keys in its window, the field puts its edit down rather
    /// than leave it open where nobody can type.
    @Test func aFieldRefusedTheKeysPutsItsEditDown() async throws {
        final class Stubborn: NSView {
            override var acceptsFirstResponder: Bool { true }
            override func resignFirstResponder() -> Bool { false }
        }
        try await withTabs(2) { browser, tabs in
            let window = testWindow()
            let stubborn = Stubborn(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            window.contentView?.addSubview(stubborn)
            window.makeFirstResponder(stubborn)
            browser.beginTabEdit(tabs[1])
            let (field, coordinator) = makeField(browser, for: tabs[1])
            window.contentView?.addSubview(field)
            // The claim tries five times on the main queue, 0.05 s apart;
            // with other suites running beside this one the queue can be
            // late, so wait for the edit to go rather than a fixed time.
            let deadline = Date.now.addingTimeInterval(5)
            while browser.editingTab != nil, Date.now < deadline { try await spin(0.05) }
            #expect(!coordinator.hasKeys)
            #expect(browser.editingTab == nil)
            stubborn.removeFromSuperview()
            window.close()
        }
    }

    /// A folder's name the same (feedback #1910): its field late into its
    /// window, the folder named all the same.
    @Test func aFolderNameFieldThatReachesItsWindowLateTakesTheKeys() async throws {
        try await withTabs(2) { browser, tabs in
            browser.newFolder(with: [tabs[0]])
            let nest = try #require(tabs[0].nest)
            let folders = browser.folderBook
            folders.naming = nest.id
            let coordinator = NestNameField.Coordinator(nest: nest, folders: folders)
            let field = NestNameField.NameBox(frame: NSRect(x: 10, y: 10, width: 200, height: 20))
            field.delegate = coordinator
            field.coordinator = coordinator
            coordinator.field = field
            coordinator.claim()
            try await spin(0.5)
            let window = testWindow()
            defer { window.close() }
            window.contentView?.addSubview(field)
            try await spin(0.1)
            #expect(coordinator.claimed)
            #expect(field.currentEditor() != nil)
            #expect(folders.naming == nest.id)
            coordinator.stopWatching()
            folders.naming = nil
        }
    }

    @Test func anEditWhoseTabClosedIsPutDown() {
        withTabs(3) { browser, tabs in
            browser.activeID = tabs[0].id
            browser.beginTabEdit(tabs[2])
            browser.tabDraft = "Mine"
            browser.close(tabs[2])
            browser.commitTabEdit()
            #expect(browser.editingTab == nil)
            #expect(browser.tabDraft.isEmpty)
        }
    }
}
