import XCTest

/// Ways into Yab from outside it, end to end in the app: a link the share
/// sheet queued (with the extension's own queue code, Sources/Entrances/
/// Shared/SharedLinks.swift, in a folder of the test's that the app is told
/// of), and the widgets' yab:// routes. The share sheet itself is another
/// app's; its card is pictured by share.1-3.
final class EntrancesTests: XCTestCase {
    private var folder: URL!
    private var queue: SharedLinkQueue { SharedLinkQueue(folder: folder) }
    private let lumen = "https://lumen.events/e/design-systems-night"

    override func setUp() {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shared-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_SHARED_LINKS"] = folder.path
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let done = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [expectation(for: done, evaluatedWith: nil)], timeout: timeout) == .completed
    }

    /// The tab in front is the shared link's.
    private func lumenInFront(_ app: XCUIApplication) -> Bool {
        let plate = element(app, "chrome.plate")
        return waitFor({ plate.exists && plate.label.contains("Lumen") }, timeout: 20)
    }

    // MARK: - the share sheet's links

    func testALinkSharedWhileYabWasClosedOpensAsATabAtLaunch() {
        XCTAssertTrue(queue.add(SharedLink(action: .open, address: lumen, title: "Design Systems Night")))
        let app = launch()
        XCTAssertTrue(lumenInFront(app), element(app, "chrome.plate").label)
        XCTAssertTrue(waitFor { self.queue.count == 0 }, "taken from the queue once")
    }

    func testOpenInYabOpensYabAtSharedAndShowsTheTab() {
        let app = launch()
        XCTAssertTrue(element(app, "chrome.plate").waitForExistence(timeout: 20))
        // What the extension does: the link into the queue, then yab://shared
        // (XCUIApplication.open may launch Yab anew for it, as iOS may).
        XCTAssertTrue(queue.add(SharedLink(action: .open, address: lumen)))
        app.open(URL(string: "yab://shared")!)
        XCTAssertTrue(lumenInFront(app), element(app, "chrome.plate").label)
        XCTAssertEqual(queue.count, 0)
    }

    func testKeepForLaterKeepsTheLinkWithoutOpeningIt() {
        XCTAssertTrue(queue.add(SharedLink(action: .keep, address: "https://theverge.com", title: "The Verge")))
        let app = launch()
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 20))
        XCTAssertTrue(waitFor { self.queue.count == 0 }, "taken from the queue")
        XCTAssertTrue(plate.label.contains("Figma"), "the tab in front stays: \(plate.label)")
        // New Tab lists the space's kept tabs: The Verge is one of Work's now,
        // a new row (Personal's own Verge tab is personal-verge). Opened from
        // the chrome: XCUIApplication.open launches a test world afresh.
        app.openNewTabFromChrome()
        let kept = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.tab.new-' AND label CONTAINS 'The Verge'"))
        XCTAssertTrue(kept.firstMatch.waitForExistence(timeout: 10), "no kept row for The Verge")
    }

    // MARK: - the widgets

    func testTheSearchWidgetOpensNewTabsFieldWithTheKeyboard() {
        let app = launch()
        XCTAssertTrue(element(app, "chrome.plate").waitForExistence(timeout: 20))
        app.open(URL(string: "yab://new")!)
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10), "no field")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "ready to type")
        XCTAssertTrue(element(app, "newtab.card").exists || element(app, "newtab.spaces").exists, "New Tab's, not the page's")
    }

    func testTheAskWidgetOpensANewChat() {
        let app = launch()
        XCTAssertTrue(element(app, "chrome.plate").waitForExistence(timeout: 20))
        app.open(URL(string: "yab://ask")!)
        XCTAssertTrue(app.textFields["chat.field"].waitForExistence(timeout: 10), "no chat field")
    }
}
