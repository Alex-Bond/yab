import XCTest

/// Translate page, voice search and the QR code scanner, touched as a person
/// would. The simulator has no translation models, microphone or camera:
/// the app's stand-ins answer in their place (the fixture's own English,
/// -YabVoice's words, -YabScan's code), everything around them is the app's.
final class TranslateVoiceScanTests: XCTestCase {
    private var app: XCUIApplication!
    private var journal: URL!

    override func setUp() {
        continueAfterFailure = false
        // In the simulator both the app and the test runner see the Mac's /tmp.
        journal = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
    }

    override func tearDown() {
        app?.terminate()
        try? FileManager.default.removeItem(at: journal)
    }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "YES"] + extra
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// The page in front shows these words somewhere.
    private func pageSays(_ words: String, timeout: TimeInterval = 15) -> Bool {
        app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    private var plate: String {
        let plate = element("chrome.plate")
        return plate.exists ? plate.label : ""
    }

    private var haptics: [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in line.split(separator: " ", maxSplits: 1).dropFirst().joined() }
    }

    private func picture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Translate

    func testTranslateShowOriginalAndAlwaysTranslate() {
        launch(["-YabState", "translate.1"])
        let translate = element("plate.menu.translate")
        XCTAssertTrue(translate.waitForExistence(timeout: 60), "no Translate row on a page in Portuguese")
        XCTAssertTrue(translate.label.hasPrefix("Translate to English"), translate.label)
        XCTAssertTrue(pageSays("Às sete da manhã"))
        picture("menu offers Translate")

        translate.tap()
        XCTAssertTrue(pageSays("At seven in the morning, Alfama still belongs"), "the page didn't turn English")
        XCTAssertTrue(pageSays("Lisboa a Pé", timeout: 2), "the site's own name stays")
        XCTAssertTrue(haptics.contains("soft page toggle"), "\(haptics)")
        picture("translated")

        element("chrome.pageMenu").tap()
        XCTAssertTrue(translate.waitForExistence(timeout: 5))
        XCTAssertTrue(wait { translate.label.hasPrefix("Show Original") }, translate.label)
        XCTAssertTrue(translate.label.contains("Translated from Portuguese"), translate.label)
        let always = element("plate.menu.alwaysTranslate")
        XCTAssertTrue(always.exists, "Always Translate comes once a page is translated")
        XCTAssertTrue(always.label.hasPrefix("Always Translate Portuguese"), always.label)
        XCTAssertFalse(always.isSelected)
        always.tap()
        XCTAssertTrue(wait(3) { always.isSelected }, "Always Translate didn't answer in place")
        picture("always translate")

        translate.tap()
        XCTAssertTrue(pageSays("Às sete da manhã"), "Show Original didn't put the words back")
    }

    /// The right button held (the tab stack, or + with no other tab), and a row of its menu.
    private func chooseFromRightButton(_ id: String, absent: String? = nil) {
        let right = element("chrome.plus")
        XCTAssertTrue(right.waitForExistence(timeout: 30), "no right button")
        XCTAssertTrue(wait { right.isHittable }, "the right button can't be touched")
        right.press(forDuration: 0.8)
        let row = app.buttons[id]
        // On a loaded Mac UIKit can miss the first hold.
        if !row.waitForExistence(timeout: 3) { right.press(forDuration: 1.2) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the right button's menu has no \(id)")
        picture("menu with \(id)")
        if let absent { XCTAssertFalse(app.buttons[absent].exists, "the menu offers \(absent)") }
        row.tap()
    }

    // MARK: - voice search

    func testVoiceSearchHearsTheWordsAndSearchesThem() {
        launch(["-YabVoice", "lisbon weather october"])
        XCTAssertTrue(element("chrome.plate").waitForExistence(timeout: 30))
        // The simulator can't scan: no Scan QR Code beside Voice Search.
        chooseFromRightButton("chrome.menu.voice", absent: "chrome.menu.scan")
        let mic = element("field.voice")
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "New Tab's field isn't listening")
        XCTAssertEqual(mic.label, "Stop Listening")
        XCTAssertTrue(element("field.eyes").exists, "the eyes stay where they are")
        XCTAssertTrue(wait(5) { (self.app.textFields["field.input"].value as? String) == "lisbon weather october" },
                      "the words didn't come into the field")
        picture("heard")
        XCTAssertTrue(wait(15) { self.plate.contains("lisbon weather october") }, "the pause after the words wasn't Return: \(plate)")
        XCTAssertTrue(haptics.contains("soft voice"), "\(haptics)")
    }

    func testNewTabsFieldKeepsItsLook() {
        launch(["-YabVoice", "lisbon weather october", "-YabScan", "https://example.com"])
        XCTAssertTrue(element("chrome.plate").waitForExistence(timeout: 30))
        app.openNewTabFromChrome()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.placeholderValue, "Search, ask or give a task", "the field's words, whole")
        XCTAssertFalse(element("field.voice").exists, "no microphone in the field at rest")
        XCTAssertFalse(element("field.scan").exists, "no code glyph in the field")
        XCTAssertTrue(element("field.eyes").exists)
        XCTAssertTrue(element("field.close").exists)
    }

    // MARK: - the code scanner

    func testAScannedAddressOpensInANewTab() {
        launch(["-YabScan", "https://lumen.events/e/design-systems-night"])
        XCTAssertTrue(element("chrome.plate").waitForExistence(timeout: 30))
        chooseFromRightButton("chrome.menu.scan")
        // The stand-in camera finds its code 0.7 s after it opens (scan.1 and
        // testTheCameraClosesWithItsCross picture the camera itself).
        XCTAssertTrue(wait(15) { self.plate.contains("Lumen") }, "the code's address didn't open: \(plate)")
        XCTAssertFalse(element("scan.camera").exists)
        XCTAssertTrue(haptics.contains("soft scan") && haptics.contains("success scanned"), "\(haptics)")
    }

    func testScannedTextGoesIntoTheField() {
        launch(["-YabScan", "gift ideas for jonas"])
        XCTAssertTrue(element("chrome.plate").waitForExistence(timeout: 30))
        chooseFromRightButton("chrome.menu.scan")
        XCTAssertTrue(wait(15) { (self.app.textFields["field.input"].value as? String) == "gift ideas for jonas" },
                      "the code's words didn't come into the field")
        XCTAssertFalse(element("scan.camera").exists)
    }

    func testTheCameraClosesWithItsCross() {
        launch(["-YabState", "scan.1"])
        let close = element("scan.close")
        XCTAssertTrue(close.waitForExistence(timeout: 60))
        picture("scanner")
        close.tap()
        XCTAssertTrue(wait(5) { !self.element("scan.camera").exists })
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "back to the field")
    }
}
