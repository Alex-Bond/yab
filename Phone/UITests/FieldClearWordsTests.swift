import XCTest

final class FieldClearWordsTests: XCTestCase {
    private var app: XCUIApplication!
    private var input: XCUIElement { app.textFields["field.input"] }
    private var clear: XCUIElement { app.buttons["field.clearWords"] }
    private var eyes: XCUIElement { app.descendants(matching: .any)["field.eyes"].firstMatch }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { app?.terminate() }

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
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        XCTAssertTrue(wait({ input.exists && app.keyboards.firstMatch.exists }, timeout: 20))
    }

    private func save(_ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("clear-words")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertClear(_ name: String) throws {
        let shown = wait { clear.exists && clear.isHittable }
        try save(name)
        XCTAssertTrue(shown, "typed search needs a clear button instead of eyes")
        XCTAssertFalse(eyes.exists, "eyes must give way while there are words")
    }

    private func assertEmpty(privateMode: Bool = false) {
        XCTAssertTrue(wait { eyes.exists && !clear.exists })
        XCTAssertTrue((input.value as? String ?? "").isEmpty || input.value as? String == input.placeholderValue)
        XCTAssertEqual(eyes.value as? String, privateMode ? "on" : "off")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "clearing must keep the keyboard")
        XCTAssertTrue(app.descendants(matching: .any)["newtab.spaces"].firstMatch.exists)
    }

    func testTypingReplacesEyesAndClearKeepsSearchOpen() throws {
        launch()
        XCTAssertTrue(eyes.exists)
        input.typeText("toto")
        XCTAssertEqual(input.value as? String, "toto")
        try assertClear("typed-before-clear")
        clear.tap()
        assertEmpty()
        try save("empty-after-clear")
        input.typeText("again")
        try assertClear("typed-again")
        XCTAssertTrue(app.buttons["field.close"].exists, "closing the screen is a separate control")
        app.buttons["field.close"].tap()
        XCTAssertTrue(wait { !input.exists })
    }

    func testDeletingTheLastCharacterRestoresEyes() throws {
        launch()
        input.typeText("a")
        try assertClear("one-character")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        assertEmpty()
        try save("last-character-deleted")
    }

    func testClearingPrivateSearchKeepsPrivateMode() throws {
        launch("privacy.3")
        try assertClear("private-words")
        clear.tap()
        assertEmpty(privateMode: true)
        XCTAssertEqual(input.label, "Private search")
        try save("private-cleared")
        eyes.tap()
        XCTAssertTrue(wait { eyes.value as? String == "off" })
    }

    func testAddressSearchHasTheSameClearBehavior() throws {
        launch("field.erased")
        input.typeText("address words")
        try assertClear("address-words")
        clear.tap()
        assertEmpty()
        try save("address-cleared")
    }

    func testClearingRestedSearchBringsTheKeyboardBack() throws {
        launch("newtab.2")
        try assertClear("before-rest")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        clear.tap()
        XCTAssertTrue(wait { app.keyboards.firstMatch.exists })
        assertEmpty()
        try save("rested-cleared")
    }
}
