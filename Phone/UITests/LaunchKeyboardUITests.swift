import XCTest

/// A cold launch lands in New Tab's field with the keyboard up (#1086), the
/// field standing in the first frame and the keyboard rising with the launch,
/// not the page first and the field growing after it. `ui --record` films it.
final class LaunchKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testColdLaunchOpensTheFieldWithTheKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabLaunchKeyboard", "YES"]
        // The second launch is the one measured: the first warms the
        // simulator's keyboard and the app's caches.
        for _ in 0..<2 {
            app.terminate()
            let start = Date()
            app.launch()
            XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 10), "no field at launch")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard at launch")
            let took = Date().timeIntervalSince(start)
            print("launch keyboard: up \(String(format: "%.2f", took)) s after launch() was called")
            Thread.sleep(forTimeInterval: 1.5)
        }
    }
}
