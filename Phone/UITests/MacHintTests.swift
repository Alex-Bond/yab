import XCTest

/// The Mac hint: a small chip over the plate that its cross or a swipe takes
/// away, and that a tap on its words answers by opening the Mac's tab here.
final class MacHintTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-mac-hint-\(UUID().uuidString)")
    }

    override func tearDown() {
        XCUIApplication().terminate()
        try? FileManager.default.removeItem(at: folder)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func launch() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "now.1", "-YabNoAnim", "YES", "-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let chip = element(app, "chrome.now")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the Mac hint did not appear")
        return (app, chip)
    }

    func testTheCrossTakesTheHintAway() {
        let (app, chip) = launch()
        // The cross is the chip's last 40 points; the chip is one element for VoiceOver.
        chip.coordinate(withNormalizedOffset: CGVector(dx: 1 - 22 / chip.frame.width, dy: 0.5)).tap()
        XCTAssertTrue(wait { !element(app, "chrome.now").exists }, "the cross left the hint on screen")
    }

    func testASwipeSweepsTheHintAway() {
        let (app, chip) = launch()
        chip.swipeRight()
        XCTAssertTrue(wait { !element(app, "chrome.now").exists }, "a swipe left the hint on screen")
    }

    func testATapOnItsWordsOpensTheMacTab() {
        let (app, chip) = launch()
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(wait { !element(app, "chrome.now").exists }, "a tap on the words left the hint on screen")
    }
}
