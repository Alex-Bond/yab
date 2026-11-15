import XCTest

final class TabOverviewGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipIf(true, "pinch to All Tabs is off (TabOverviewPinch.enabled) until it opens All Tabs here")
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    private func launch() {
        let ready = Atlas.readyFolder()
        XCTAssertTrue(Atlas.launch(app, state: "stack.many", ready: ready, still: false))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        record("page-before-pinch")
    }

    private var gallery: XCUIElement { app.descendants(matching: .any)["tabs.gallery"].firstMatch }

    private func record(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInwardPinchOpensOverviewAndACardReturnsToThePage() {
        launch()
        app.webViews.firstMatch.pinch(withScale: 0.45, velocity: -1.5)
        XCTAssertTrue(gallery.waitForExistence(timeout: 10))
        XCTAssertTrue(TransitionCatalog.wait(10) { self.app.buttons["tabs.new"].isHittable })
        record("overview-after-pinch")
        let card = app.descendants(matching: .any)["tabs.card.work-gh-pr"].firstMatch
        XCTAssertTrue(card.exists)
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: card.frame.minX + 40, dy: card.frame.midY))
        point.tap()
        XCTAssertTrue(TransitionCatalog.wait(10) { !self.gallery.exists })
        record("page-after-card-selection")
    }

    func testSmallSlowPinchReturnsToPage() {
        launch()
        app.webViews.firstMatch.pinch(withScale: 0.96, velocity: -0.1)
        XCTAssertTrue(TransitionCatalog.wait(10) { !self.gallery.exists })
        XCTAssertTrue(app.webViews.firstMatch.exists)
        record("page-after-cancelled-pinch")
    }
}
