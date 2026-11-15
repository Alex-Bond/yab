import XCTest

final class FieldSearchQueryUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { app?.terminate() }

    private func save(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("google-query")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTappingGoogleResultsShowsTheQueryAndTypingReplacesIt() throws {
        app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("lisbon weather october")
        let search = app.buttons["field.best"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.label.contains("Search Google"))
        search.tap()
        let results = app.webViews.staticTexts["lisbon weather october: what to expect"]
        XCTAssertTrue(results.waitForExistence(timeout: 10), "the local results page must load")
        plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        try save("query-selected")
        XCTAssertEqual(input.value as? String, "lisbon weather october", "Google results must show the query instead of the URL")
        input.typeText("espresso grinders")
        XCTAssertEqual(input.value as? String, "espresso grinders", "typing must replace the selected query")
        try save("query-replaced")
        XCTAssertTrue(search.label.contains("Search Google"))
        search.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "espresso grinders")
        try save("new-query-selected")
    }
}
