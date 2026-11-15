import XCTest

/// The search sheet with real touches: a tap on the plate opens it, a pull up
/// gives the spaces, a tap on their field brings it back, and it goes by a
/// pull down or a tap beside it.
final class SearchSheetTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { XCUIApplication().terminate() }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabSearchSheet"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func drag(_ app: XCUIApplication, from point: CGPoint, by dy: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .default, thenHoldForDuration: 0.05)
    }

    private func gone(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    private func openSheet(_ app: XCUIApplication) -> XCUIElement {
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        plate.tap()
        let sheet = element(app, "search.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sheet.value as? String, "low")
        return sheet
    }

    /// A point on the sheet: its first row, else its grabber's strip over the field.
    private func sheetPoint(_ app: XCUIApplication) -> CGPoint {
        let row = element(app, "search.recent.0")
        if row.waitForExistence(timeout: 2) { return CGPoint(x: row.frame.midX, y: row.frame.midY) }
        let field = element(app, "field.pill")
        return CGPoint(x: field.frame.midX, y: app.keyboards.firstMatch.frame.minY - 20)
    }

    func testPullUpGivesSpacesAndTheirFieldBringsTheSheetBack() {
        let app = launch()
        _ = openSheet(app)
        drag(app, from: sheetPoint(app), by: -400)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard stays over the spaces")
        XCTAssertEqual(element(app, "search.sheet").value as? String, "spaces")
        add(attachment(app, "spaces"))

        element(app, "spaces.new").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "search.sheet").exists)
    }

    func testShortPullKeepsTheKeyboardAndTheSheet() {
        let app = launch()
        _ = openSheet(app)
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        drag(app, from: sheetPoint(app), by: -40)
        sleep(1)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "a short pull lets the keyboard go")
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY, keyboardTop, accuracy: 1)
        XCTAssertEqual(element(app, "search.sheet").value as? String, "low", "a short pull opens the spaces")
    }

    func testPullDownAndTapBesideClose() {
        let app = launch()
        _ = openSheet(app)
        drag(app, from: sheetPoint(app), by: 240)
        XCTAssertTrue(gone(element(app, "search.sheet")), "pull down leaves the sheet")
        XCTAssertTrue(gone(app.keyboards.firstMatch))

        _ = openSheet(app)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(gone(element(app, "search.sheet")), "a tap beside leaves the sheet")
        XCTAssertTrue(element(app, "chrome.plate").waitForExistence(timeout: 5))
    }

    func testPlateSwipeOpensSpacesAndARowOpensItsPage() {
        let app = launch()
        SpacesGesture.open(in: app)
        XCTAssertTrue(element(app, "newtab.spaces").waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        element(app, "spaces.new").tap()
        XCTAssertTrue(element(app, "search.sheet").waitForExistence(timeout: 5))

        let row = element(app, "search.recent.0")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(gone(element(app, "search.sheet")), "a row leaves the sheet")
    }

    private func attachment(_ app: XCUIApplication, _ name: String) -> XCTAttachment {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        return a
    }
}
