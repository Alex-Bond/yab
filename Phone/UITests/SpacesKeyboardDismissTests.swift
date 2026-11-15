import XCTest

final class SpacesKeyboardDismissTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        app?.terminate()
    }

    private var field: XCUIElement { app.textFields["field.input"] }
    private func node(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func launch(_ state: String = "newtab.1") {
        app = XCUIApplication()
        // This native screen covers the page. Its input and keyboard prove
        // readiness without waiting for the hidden WebKit fixture to paint.
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(wait({ field.exists && app.keyboards.firstMatch.exists }, timeout: 20))
    }

    private func save(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("spaces-keyboard")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertDismissed(_ name: String) throws {
        let hidden = wait { !app.keyboards.firstMatch.exists }
        try save(name)
        XCTAssertTrue(hidden, "touching the spaces left the keyboard up")
        XCTAssertTrue(node("newtab.spaces").exists, "the first gesture must keep the spaces open")
        XCTAssertTrue(wait { field.frame.maxY > app.frame.maxY - 100 }, "search must rest at the screen's foot")
    }

    func testTapOutsideSearchDismissesKeyboardAndSearchCanRefocus() throws {
        launch()
        try save("tap-before")
        // The current space is outside search and cannot open a tab. A tap
        // in a row's side padding still belongs to that row's touch target.
        node("newtab.capsule").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try assertDismissed("tap-after")
        field.tap()
        XCTAssertTrue(wait { app.keyboards.firstMatch.exists }, "search must bring the keyboard back")
        field.typeText("hello")
        XCTAssertEqual(field.value as? String, "hello")
    }

    func testDraggingUpDismissesKeyboard() throws {
        try drag(down: false)
    }

    func testDraggingDownDismissesKeyboardWithoutClosingSpaces() throws {
        try drag(down: true)
    }

    private func drag(down: Bool) throws {
        launch()
        let name = down ? "drag-down" : "drag-up"
        try save(name + "-before")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: down ? 220 : -100)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        try assertDismissed(name + "-after")
    }

    func testTypedWordsStayWhenKeyboardDismisses() throws {
        launch("newtab.2")
        let words = field.value as? String
        try save("words-before")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        try assertDismissed("words-after")
        XCTAssertEqual(field.value as? String, words)
        XCTAssertTrue(node("field.best").exists, "search results must stay")
    }

    func testTheSameScreenFromTheAddressFieldRestsAtTheFoot() throws {
        launch("field.erased")
        try save("address-before")
        node("newtab.capsule").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try assertDismissed("address-after")
        field.tap()
        XCTAssertTrue(wait { app.keyboards.firstMatch.exists })
    }

    func testDraggingTypedResultsKeepsWordsAndSpaces() throws {
        launch("newtab.2")
        let words = field.value as? String
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        try assertDismissed("words-drag-after")
        XCTAssertEqual(field.value as? String, words)
    }

    func testPagingBetweenSpacesDismissesKeyboard() throws {
        launch()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        try assertDismissed("paging-after")
    }

    func testFolderTapStillOpensFolderAndDismissesKeyboard() throws {
        launch()
        let folder = node("newtab.folder.work-onboarding")
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        try assertDismissed("folder-after")
        XCTAssertTrue(node("newtab.tab.work-onb-spec").exists, "the folder's own action must still run")
    }

    func testDraggingTheHeadDismissesKeyboardWithoutClosingSpaces() throws {
        launch()
        let head = node("newtab.capsule")
        XCTAssertTrue(head.waitForExistence(timeout: 8))
        let start = head.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        try assertDismissed("head-after")
    }
}
