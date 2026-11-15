import XCTest

/// Up on the plate (PlateSwipe): a slow drag takes All Tabs, a quick flick
/// the spaces sidebar (SharedBottomToolbarTests); and All Tabs' computer turns into the sidebar in place.
/// Real motion (no -YabNoAnim): `remote ui PlateSwipeRuleTests --record` films it.
final class PlateSwipeRuleTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    private func node(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch(_ state: String) {
        app.launchArguments = ["-YabWorld", "mira", "-YabSearchSheet", "-YabState", state]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
    }

    private func save(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func plateStart() -> XCUICoordinate {
        let plate = node("chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 60))
        return plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    func testSlowDragUpOnThePlateOpensAllTabs() {
        launch("stack.many")
        let start = plateStart()
        sleep(1)
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(node("tabs.gallery").waitForExistence(timeout: 5), "a slow drag up is All Tabs")
        save("slow-drag-all-tabs")
        XCTAssertFalse(app.buttons["spaces.done"].exists, "not the sidebar")
    }

    // The flick itself is proven in SharedBottomToolbarTests: XCUITest's
    // synthesized drags never let go at a finger's speed.

    func testComputerTurnsAllTabsIntoTheSidebarInPlace() {
        launch("stack.many")
        XCTAssertTrue(app.buttons["chrome.plus"].waitForExistence(timeout: 60))
        sleep(1)
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(app.buttons["tabs.sidebar"].waitForExistence(timeout: 10))
        sleep(1)
        save("gallery")
        app.buttons["tabs.sidebar"].tap()
        XCTAssertTrue(app.buttons["spaces.done"].waitForExistence(timeout: 5))
        sleep(1)
        save("sidebar")
    }
}
