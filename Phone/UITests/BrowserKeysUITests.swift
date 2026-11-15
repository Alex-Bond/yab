import XCTest

/// Row 1029: the browser's keys as a hardware keyboard sends them on iPad.
/// Each step leaves a picture and the accessibility tree in browser-keys/.
final class BrowserKeysUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ready: URL!

    override func setUp() {
        continueAfterFailure = false
        ready = Atlas.readyFolder()
        app = XCUIApplication()
    }

    override func tearDown() {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        try? FileManager.default.removeItem(at: ready)
    }

    private func picture(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("browser-keys")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        let tree = app.state == .runningForeground ? app.debugDescription : "Application state: \(app.state.rawValue)"
        try tree.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    /// The state, then the keyboard made ready. In a fresh launch (and after a
    /// turn) the simulator attaches its keyboard on a first key and UIKit builds
    /// the main menu only on a key after that, up to 8 s on (logged 2026-10-25 on
    /// m4, adhd and aws-1); keys before it go nowhere. So ⌘L until the field
    /// shows, then ⌘W puts it away. Before the fix nothing shows, and the eight
    /// presses still attach the keyboard. A real keyboard is there from the start.
    private func open(_ state: String, landscape: Bool = false) throws {
        XCTAssertTrue(Atlas.launch(app, state: state, ready: ready))
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1.5)
        }
        let input = app.textFields["field.input"]
        for _ in 0..<8 {
            app.typeKey("l", modifierFlags: .command)
            if input.waitForExistence(timeout: 1.5) { break }
        }
        if input.exists {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(gone(input), "⌘W puts the warm-up field away")
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func gone(_ element: XCUIElement, within timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.exists }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testCommandTOpensTheNewTabFieldAndTakesTyping() throws {
        try open("page.1")
        try picture("new-tab-before")
        app.typeKey("t", modifierFlags: .command)
        let input = app.textFields["field.input"]
        let opened = input.waitForExistence(timeout: 5)
        try picture("new-tab-after")
        XCTAssertTrue(opened, "⌘T opens New Tab's field")
        app.typeText("shortcut query")
        XCTAssertEqual(input.value as? String, "shortcut query")
        try picture("new-tab-typed")
        // ⌘W with the field up puts it away; the page stays.
        app.typeKey("w", modifierFlags: .command)
        let away = gone(input)
        try picture("new-tab-closed")
        XCTAssertTrue(away, "⌘W puts the field away")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCommandLOpensTheAddress() throws {
        try open("page.1")
        app.typeKey("l", modifierFlags: .command)
        let input = app.textFields["field.input"]
        let opened = input.waitForExistence(timeout: 5)
        try picture("address")
        XCTAssertTrue(opened, "⌘L opens the field on the address")
    }

    func testCommandWClosesTheFocusedPaneAndShiftCommandTBringsItBack() throws {
        // iPad shows the split side by side only in landscape.
        try open("workspace.form", landscape: true)
        let companion = app.descendants(matching: .any).matching(identifier: Atlas.model == "ipad" ? "tablet.addressBar.workspace-primary" : "workspace.companion").firstMatch
        XCTAssertTrue(companion.waitForExistence(timeout: 20), "the split's other pane")
        try picture("close-tab-before")
        app.typeKey("w", modifierFlags: .command)
        let closed = gone(companion)
        try picture("close-tab-after")
        XCTAssertEqual(app.state, .runningForeground, "⌘W keeps Yab open")
        XCTAssertTrue(closed, "⌘W closes the focused tab and its split")
        // The page left in front draws a moment after the split goes.
        XCTAssertTrue(app.textFields["Draft"].waitForExistence(timeout: 10), "the other document stays")
        try picture("close-tab-settled")
        // Once more with no page ahead of it: still the browser, never the window.
        app.typeKey("t", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        try picture("reopen-after")
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCommandWOnTheLastPageKeepsYabOpen() throws {
        try open("page.1")
        for step in 1...6 {
            app.typeKey("w", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(app.state, .runningForeground, "⌘W number \(step) keeps Yab open")
        }
        try picture("closed-all")
    }

    func testTabletOmniboxArrowsSelectAndReturnOpensTheChosenRecentTab() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        try open("page.1")
        app.typeKey("t", modifierFlags: .command)
        let first = app.buttons["tablet.search.recent.0"]
        let second = app.buttons["tablet.search.recent.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        try picture("omnibox-arrows-before")
        app.typeKey(.downArrow, modifierFlags: [])
        try picture("omnibox-arrow-down")
        XCTAssertTrue(second.isSelected, "Down highlights the second result")
        XCTAssertFalse(first.isSelected)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(first.isSelected, "Up returns to the first result")
        app.typeKey(.downArrow, modifierFlags: [])
        app.textFields["field.input"].typeText("\n")
        XCTAssertTrue(gone(app.textFields["field.input"]))
        XCTAssertTrue(app.buttons["tablet.address"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.buttons["tablet.address"].value as? String)?.contains("ledger") == true,
                      "Return opens Ledger, the second recent tab, rather than Hacker News")
        try picture("omnibox-chosen-recent")
    }

    func testCommandSTogglesTabletSidebarWithoutChangingThePage() throws {
        guard Atlas.model == "ipad" else { throw XCTSkip("Tablet UI") }
        try open("page.1")
        let sidebar = app.buttons["tablet.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        let address = app.buttons["tablet.address"].value as? String
        XCTAssertEqual(sidebar.value as? String, "shown")
        try picture("sidebar-key-before")
        app.typeKey("s", modifierFlags: .command)
        try picture("sidebar-key-hidden")
        XCTAssertEqual(sidebar.value as? String, "hidden")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertEqual(sidebar.value as? String, "shown")
        XCTAssertEqual(app.buttons["tablet.address"].value as? String, address)
        try picture("sidebar-key-restored")
    }
}
