import XCTest

/// History as a finger uses it: Settings' History row opens it over a few
/// days of pages (this iPhone's and the Mac's), the search narrows it, a row
/// swiped left deletes, Clear asks for its range and takes it, a tap opens
/// the page; "All History" opens it as its own sheet that × closes.
final class HistoryUITests: XCTestCase {
    private var journal: URL!

    override func setUp() {
        continueAfterFailure = false
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: journal)
    }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.row."))
    }

    private func wait(_ timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private var haptics: [String] {
        let text = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.split(separator: " ").dropFirst().joined(separator: " ") }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let photo = XCTAttachment(screenshot: app.screenshot()); photo.name = name; photo.lifetime = .keepAlways; activity.add(photo)
        }
    }

    func testSettingsOpensHistoryWhichSearchesDeletesAndClears() {
        let app = launch("history.ready")
        let row = app.buttons["settings.row.history"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no History row in Settings")
        for _ in 0..<4 where !row.isHittable { element(app, "settings.index").swipeUp(velocity: .slow) }
        row.tap()
        XCTAssertTrue(element(app, "history.page").waitForExistence(timeout: 5), "History didn't open")
        XCTAssertEqual(element(app, "settings.title").label, "History")
        XCTAssertTrue(app.buttons["settings.back"].exists, "a page of Settings: ‹")
        XCTAssertTrue(wait { self.rows(app).count >= 8 }, "the pages: \(rows(app).count)")
        let mac = rows(app).matching(NSPredicate(format: "label CONTAINS %@", "on MacBook Pro")).firstMatch
        XCTAssertTrue(mac.exists, "the Mac's pages say so")
        attach(app, "History from Settings")

        // The search: the pages whose title or address has the word.
        let search = app.textFields["history.search"]
        search.tap()
        search.typeText("wiki")
        XCTAssertTrue(wait { self.rows(app).count == 2 }, "wiki: \(rows(app).allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(rows(app).allElementsBoundByIndex.allSatisfy { $0.label.contains("Wikipedia") })
        attach(app, "History searched")
        app.buttons["history.search.clear"].tap()
        XCTAssertTrue(wait { self.rows(app).count >= 8 })

        // A row pulled left: a card, Delete behind it; a tap on Delete takes the page.
        let first = rows(app).element(boundBy: 0)
        let name = first.label
        XCTAssertTrue(name.hasPrefix("Lisbon · Wikipedia"), name)
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -130, dy: 0)), withVelocity: 600, thenHoldForDuration: 0.15)
        let delete = app.buttons["history.swipe.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "no Delete behind the row")
        attach(app, "History row swiped")
        delete.tap()
        XCTAssertTrue(wait { !self.rows(app).allElementsBoundByIndex.contains { $0.label == name } }, "deleted")
        XCTAssertTrue(haptics.contains("light row"), "\(haptics)")

        // Clear asks for its range; All Time takes every page.
        let clear = app.buttons["history.clear"]
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        let allTime = app.buttons["All Time"].firstMatch
        XCTAssertTrue(allTime.waitForExistence(timeout: 5), "no ranges")
        for range in ["Last Hour", "Today", "Today and Yesterday"] { XCTAssertTrue(app.buttons[range].firstMatch.exists, range) }
        attach(app, "Clear History's ranges")
        allTime.tap()
        XCTAssertTrue(element(app, "history.empty").waitForExistence(timeout: 5), "History is empty")
        XCTAssertEqual(rows(app).count, 0)
        XCTAssertTrue(haptics.contains("rigid clear"), "\(haptics)")
        attach(app, "History cleared")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(app.buttons["settings.row.history"].waitForExistence(timeout: 5), "back to Settings")
    }

    func testAllHistoryIsItsOwnSheetAndAPageOpensFromIt() {
        let app = launch("history.items")
        XCTAssertTrue(element(app, "history.page").waitForExistence(timeout: 20), "no History")
        XCTAssertTrue(app.buttons["settings.close"].exists, "its own sheet: ×")
        XCTAssertFalse(app.buttons["settings.back"].exists, "nothing under it to go back to")
        let verge = rows(app).matching(NSPredicate(format: "label BEGINSWITH %@", "The Verge")).firstMatch
        XCTAssertTrue(wait { verge.isHittable }, "no row for The Verge")
        verge.tap()
        XCTAssertTrue(wait { !self.element(app, "history.page").exists }, "History goes as the page opens")
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { plate.label.contains("The Verge") || plate.label.contains("theverge") }, "the page in front: \(plate.label)")
        attach(app, "A page opened from History")
    }
}
