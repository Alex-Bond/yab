import AppKit
import Testing
import WebKit
@testable import Fast

/// Crash #1124 (0.45.2): WebKit holds a right-click menu back for
/// Browser's getContextMenuFromProposedMenu, and its completion must be
/// called once. A second right-click before the first menu's read ended
/// made the first read stale, and it returned without calling WebKit, which
/// threw from CompletionHandlerCallChecker as the block went: abort.
@MainActor @Suite(.serialized)
struct PageMenuReadTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private func searchMenu() -> NSMenu {
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search", action: nil, keyEquivalent: "")
        search.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        menu.addItem(search)
        return menu
    }

    private func settle(until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aMenuOvertakenByAnotherIsStillAnswered() async throws {
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        var first: [Bool] = [], second: [Bool] = []
        web.readBeforeMenu(searchMenu()) { first.append($0) }
        web.readBeforeMenu(searchMenu()) { second.append($0) }
        // The older one is answered at once, as no longer current.
        #expect(first == [false])
        try await settle { !second.isEmpty }
        // Its page script reply and its deadline come later: still once.
        try await Task.sleep(for: .milliseconds(400))
        #expect(first == [false])
        #expect(second == [true])
    }

    @Test func aMenuWhosePageWentIsStillAnswered() async throws {
        var answers: [Bool] = []
        do {
            let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
            web.readBeforeMenu(searchMenu()) { answers.append($0) }
        }
        try await settle { !answers.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(answers.count == 1)
    }

    @Test func aMenuWithNothingToReadIsAnsweredAtOnce() {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        var answers: [Bool] = []
        web.readBeforeMenu(NSMenu()) { answers.append($0) }
        #expect(answers == [true])
    }
}
