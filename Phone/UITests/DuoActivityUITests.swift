import XCTest

/// Uses another app's activity because Yab's activity is hidden in front of Yab.
final class DuoActivityUITests: XCTestCase {
    func testClockTimerAboveYab() throws {
        guard Atlas.model == "duo" else { throw XCTSkip("Duo simulator only") }
        continueAfterFailure = false
        let clock = XCUIApplication(bundleIdentifier: "com.apple.mobiletimer")
        clock.launch()
        defer { clock.terminate() }
        func save(_ name: String) {
            Atlas.write(Data(clock.debugDescription.utf8), to: "duo-activity/\(name).txt")
            Atlas.write(XCUIScreen.main.screenshot().pngRepresentation, to: "duo-activity/\(name).png")
        }
        save("clock-launch")
        let timers = clock.tabBars.buttons["Timers"]
        let timer = clock.tabBars.buttons["Timer"]
        if timers.waitForExistence(timeout: 5) { timers.tap() }
        else if timer.exists { timer.tap() }
        save("clock-timers")
        let wheels = clock.pickerWheels
        if wheels.count >= 3 {
            wheels.element(boundBy: 0).adjust(toPickerWheelValue: "0 hours")
            wheels.element(boundBy: 1).adjust(toPickerWheelValue: "5 min")
            wheels.element(boundBy: 2).adjust(toPickerWheelValue: "0 sec")
        }
        let start = clock.buttons["Start"].firstMatch
        guard start.waitForExistence(timeout: 5) else {
            save("clock-no-start")
            XCTFail("Clock has no Start timer control; inspect saved tree")
            return
        }
        start.tap()
        save("clock-running")
        let app = XCUIApplication()
        let ready = Atlas.readyFolder()
        XCTAssertTrue(Atlas.launch(app, state: "duo.wide", ready: ready))
        Atlas.write(Atlas.picture().pngRepresentation, to: "duo-activity/yab-timer.png")
        if let notes = try? Data(contentsOf: ready.appendingPathComponent("duo.wide")) {
            Atlas.write(notes, to: "duo-activity/yab-timer.txt")
        }
        Atlas.write(Data(app.debugDescription.utf8), to: "duo-activity/yab-tree.txt")
        app.terminate()
        clock.activate()
        let cancel = clock.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
    }
}
