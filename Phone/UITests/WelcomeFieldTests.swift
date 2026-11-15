import XCTest

/// An isolated normal profile follows the real first launch, with the
/// Welcome and field animations enabled and no fixture world or Mac.
final class WelcomeFieldTests: XCTestCase {
    private var profile: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        profile = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("yab-welcome-field-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        if let profile { try? FileManager.default.removeItem(at: profile) }
    }

    /// New Tab is the space's one card (efa361a2): a cold profile's shows the
    /// space with the field at its foot, and rows only for typed words.
    func testColdNotNowShowsTheSpaceAndRowsOnlyForTypedWords() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", profile.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.skip"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 15))
        XCTAssertTrue(TransitionCatalog.wait { notNow.isHittable })
        save(app, "Cold profile before Not Now")
        app.passWelcome()
        XCTAssertTrue(TransitionCatalog.wait { !app.descendants(matching: .any)["welcome"].exists })
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(TransitionCatalog.wait { input.isHittable && app.keyboards.firstMatch.exists })
        // The native screenshot waits for animations to settle. Save it before
        // the assertion so any unexpected card remains visible in a failure.
        save(app, "Cold Not Now settled empty New Tab")
        assertNoRows(app)

        input.typeText("settings")
        let best = app.buttons["field.best"]
        XCTAssertTrue(best.waitForExistence(timeout: 5))
        XCTAssertTrue(best.label.lowercased().contains("settings"))
        XCTAssertTrue(app.descendants(matching: .any)["newtab.card"].exists,
                      "typed words draw their rows")
        save(app, "Cold New Tab typed suggestions")
        // New Tab's field has the eyes where ⓧ was (65619b17): the words
        // are erased from the keyboard.
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "settings".count))
        XCTAssertTrue(TransitionCatalog.wait { !best.exists })
        XCTAssertTrue(input.exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "erasing keeps the search field focused")
        save(app, "Cold New Tab cleared without rows")
        assertNoRows(app)
    }

    /// 1813: Use Without a Mac, then Yab quit on a later page (here Open
    /// Links in Yab?): the next launch opens the browser, not the welcome
    /// again from its first page. The pages after the answer still run on
    /// the launch that answered it.
    func testQuitAfterUsingWithoutAMacNeverBringsTheWelcomeBack() {
        let app = XCUIApplication()
        let suite = UUID().uuidString
        app.launchArguments = ["-YabProfileDirectory", profile.path, "-YabSettingsSuite", suite]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let welcome = app.descendants(matching: .any)["welcome"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "a cold profile is welcomed")
        tap(app.buttons["welcome.start"])
        tap(app.buttons["welcome.withoutMac"])
        // The field's page, then Private's: the answer written down hides neither.
        tap(app.buttons["welcome.next"])
        tap(app.buttons["welcome.next"])
        let last = app.buttons["welcome.makeDefault"]
        XCTAssertTrue(last.waitForExistence(timeout: 8) || app.textFields["field.input"].exists,
                      "the welcome ran to its last page")
        if last.exists { XCTAssertTrue(welcome.exists, "Open Links in Yab? is still the welcome's") }
        save(app, "Without a Mac, at the last page")

        app.terminate()
        app.launch()
        // The browser of a profile with no tabs: its empty home, or New
        // Tab's field where a launch opens it.
        let home = app.descendants(matching: .any)["empty.home"]
        let input = app.textFields["field.input"]
        XCTAssertTrue(TransitionCatalog.wait(15) { home.exists || input.exists || welcome.exists },
                      "neither the browser nor the welcome came up")
        save(app, "Relaunched after the quit")
        XCTAssertFalse(welcome.exists, "the welcome came back after Use Without a Mac")
        XCTAssertFalse(app.buttons["welcome.start"].exists)
    }

    private func tap(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 8), "no \(button)", file: file, line: line)
        button.waitUntilStill()
        button.tap()
    }

    /// The space stands in New Tab, and the typed rows' list, in the tree
    /// while it waits for words, holds no row.
    private func assertNoRows(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.descendants(matching: .any)["newtab.spaces"].exists, "New Tab shows the space", file: file, line: line)
        XCTAssertFalse(app.buttons["field.best"].exists, "no rows without words", file: file, line: line)
        let rows = app.descendants(matching: .any)["newtab.card"].firstMatch
        if rows.exists { XCTAssertEqual(rows.buttons.count, 0, "no rows without words", file: file, line: line) }
        XCTAssertFalse(app.descendants(matching: .any)["newtab.card.frame"].exists,
                       "no card of its own covers the search field", file: file, line: line)
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let photo = XCTAttachment(screenshot: app.screenshot())
            photo.name = name
            photo.lifetime = .keepAlways
            activity.add(photo)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + " AX"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
    }
}
