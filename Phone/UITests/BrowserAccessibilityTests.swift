import XCTest

/// Font sizes, visible controls and typing across the page's overlay sheets.
final class BrowserAccessibilityTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func open(_ state: String, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let arguments = large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] : []
        XCTAssertTrue(Atlas.launch(app, state: state, ready: Atlas.readyFolder(), extra: arguments), "\(state) did not settle")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func testChromeReturnsAsAnAccessibleControlAfterSettingsCloses() {
        let app = open("settings.1")
        XCTAssertFalse(element(app, "chrome.plate").exists, "the covered page's control is outside the active screen")
        app.buttons["settings.close"].tap()
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        XCTAssertTrue(TransitionCatalog.wait { plate.isHittable })
        plate.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "the returned control opens the real field")
        XCTAssertFalse(plate.exists, "the field takes the plate's place for VoiceOver too")
    }

    func testFieldRowsAndInputGrowAndTheBestRowStillOpensSettings() {
        var app = open("settings.2")
        let regularInput = app.textFields["field.input"].frame.height
        let regularRow = app.buttons["field.best"].frame.height
        app.terminate()
        app = open("settings.2", large: true)
        let input = app.textFields["field.input"]
        let best = app.buttons["field.best"]
        XCTAssertGreaterThan(input.frame.height, regularInput, "the typing area grows with the body font")
        XCTAssertGreaterThan(best.frame.height, regularRow, "the title and subtitle get their full line heights")
        XCTAssertLessThanOrEqual(best.frame.maxY, input.frame.minY, "the last choice stays above the larger field")
        XCTAssertTrue(best.isHittable)
        XCTAssertTrue(best.label.contains("Settings"))
        best.tap()
        XCTAssertTrue(element(app, "settings.sheet").waitForExistence(timeout: 5), "large text leaves the choice usable")
    }

    func testTheRecoverySectionGrowsAndAcceptsTypedGroupsAtLargeText() {
        var app = open("join.4")
        let regularTitle = element(app, "join.section").frame.height
        app.terminate()
        app = open("join.4", large: true)
        let title = element(app, "join.section")
        XCTAssertEqual(title.label, "USE THE RECOVERY KEY")
        XCTAssertGreaterThan(title.frame.height, regularTitle)
        app.terminate()
        app = open("join.2", large: true)
        app.buttons["join.recovery"].tap()
        let field = element(app, "join.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("ABCD-EFGH-JKMN")
        XCTAssertEqual(field.value as? String, "ABCD-EFGH-JKMN")
        XCTAssertTrue(app.buttons["join.go"].isHittable)
        app.buttons["join.go"].tap()
        XCTAssertTrue(app.staticTexts["That isn't a Recovery Key. Check each group of four."].waitForExistence(timeout: 5))
    }
}
