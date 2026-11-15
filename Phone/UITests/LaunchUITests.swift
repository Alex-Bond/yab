import XCTest

/// Yab launches into mira and its chrome is there to touch.
final class LaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testMiraShowsThePlate() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"]
        app.launch()
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 15), "no plate")
        XCTAssertTrue(plate.isHittable)
        XCTAssertTrue(plate.label.contains("Figma"), "the plate says \(plate.label)")
        XCTAssertTrue(app.buttons["chrome.back"].exists)
        XCTAssertTrue(app.buttons["chrome.plus"].exists)
        // Nothing running in the atlas's start: no Now line.
        XCTAssertFalse(app.descendants(matching: .any)["chrome.now"].exists)
        // Safari's bar (65619b17): the plate 28 over the screen's bottom,
        // 48 high, 81 from each side (26 + a 48 button + 7).
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(plate.frame.height, 48, accuracy: 1)
        XCTAssertEqual(plate.frame.minX, 81, accuracy: 1)
        XCTAssertEqual(screen.maxY - plate.frame.maxY, 28, accuracy: 1)
    }

    func testScrollingDownFoldsTheChromeAndUpBringsItBack() {
        let app = XCUIApplication()
        // A long page: Launch notes in Paper.
        app.launchArguments = ["-YabWorld", "mira", "-YabTab", "work-launch-notes", "-YabNoAnim", "YES"]
        app.launch()
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        XCTAssertTrue(plate.label.contains("Paper"), "the plate says \(plate.label)")
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        // The page drawn before the finger goes down on it. A cold web
        // process on a busy Mac takes a while (Phone/scripts/phone gives
        // a state a second take for the same reason).
        XCTAssertTrue(page.staticTexts["Tern 2.0 launch notes"].waitForExistence(timeout: 30), "the page never drew")
        page.swipeUp(velocity: .slow)
        XCTAssertTrue(waitFor(plate, height: 44), "folded, the plate is \(plate.frame)")
        XCTAssertEqual(plate.value as? String, "folded")
        XCTAssertLessThanOrEqual(plate.frame.width, 158.5, "folded, the capsule hugs its words, 158 at most")
        XCTAssertFalse(app.buttons["chrome.back"].isHittable, "the round buttons go when the chrome folds")
        page.swipeDown(velocity: .slow)
        XCTAssertTrue(waitFor(plate, height: 48), "unfolded, the plate is \(plate.frame)")
    }

    func testTappingTheFoldedPlateOpensItsAddressInOneTap() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "page.2", "-YabNoAnim", "YES"]
        app.launch()
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(plate, height: 44), "page.2 is folded: \(plate.frame)")
        plate.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "one tap opens the folded plate's address")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The address itself, selected; the page's actions are its menu's now
        // (448423cb), not a card over the field.
        let input = app.textFields["field.input"]
        XCTAssertTrue((input.value as? String)?.contains(".") == true, "the field holds the page's address: \(String(describing: input.value))")
    }

    /// Waits for an element to reach a height, the chrome's movement done.
    private func waitFor(_ element: XCUIElement, height: CGFloat, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if abs(element.frame.height - height) < 1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testANamedStateShowsTheNowLine() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "page.2", "-YabNoAnim", "YES"]
        app.launch()
        let now = app.descendants(matching: .any)["chrome.now"]
        XCTAssertTrue(now.waitForExistence(timeout: 15), "no Now line")
        XCTAssertTrue(now.label.contains("Lisbon flights"), "the Now line says \(now.label)")
    }
}
