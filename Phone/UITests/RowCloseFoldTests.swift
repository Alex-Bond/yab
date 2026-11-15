import XCTest

/// A full swipe to Close folds the row away and its neighbors slide up,
/// on the spaces page as people use it. The film of this test is the proof
/// of the motion (scripts/row-close-fold-check.sh measures its frames).
final class RowCloseFoldTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { app?.terminate() }

    private func node(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testFullSwipeClosesAndTheNextRowTakesItsPlace() throws {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabSearchSheet", "-YabState", "search.spaces"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        let row = node("newtab.tab.work-launch-notes")
        let next = node("newtab.tab.work-ledger")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let rowTop = row.frame.minY
        let nextTop = next.frame.minY
        // Hold still a moment so the film has a clean before.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: row.frame.maxX - 40, dy: row.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -(row.frame.width + 40), dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        let end = Date().addingTimeInterval(5)
        while row.exists && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(row.exists, "a full swipe must close the row")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(next.frame.minY, rowTop, accuracy: 1, "the next row must take the closed row's place (was \(nextTop))")
    }
}
