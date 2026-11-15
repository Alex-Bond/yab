import XCTest

/// The empty browser's foot: where a page has ‹, the screen with no page in
/// front has Settings, so the way into Settings is always one tap away and
/// the foot never stands a control short (Chrome/SharedBottomToolbar).
final class EmptyBrowserSettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testTheEmptyBrowserHasSettingsWhereAPageHasBack() {
        let app = XCUIApplication()
        XCTAssertTrue(Atlas.launch(app, state: "zero.fromMac", ready: Atlas.readyFolder()))
        let settings = app.buttons["chrome.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "the empty browser's foot has no Settings")
        XCTAssertFalse(app.buttons["chrome.back"].exists, "‹ stands there too: the slot is shared, not doubled")
        settings.tap()
        XCTAssertTrue(element(app, "settings.sheet").waitForExistence(timeout: 5), "Settings did not open from the foot")
        app.terminate()
    }
}
