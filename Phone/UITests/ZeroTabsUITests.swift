import XCTest

/// Request 1260, touched as a person would: the last today's tab closes from
/// All Tabs under the + held, the page stands empty with Undo; a new profile
/// passes the welcome into New Tab's field, and its cancel is the empty page.
final class ZeroTabsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let out = ProcessInfo.processInfo.environment["YAB_OUT"] else { return }
        let folder = URL(fileURLWithPath: out).appendingPathComponent("zero")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func settle(_ seconds: TimeInterval = 0.8) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func wait(_ seconds: TimeInterval = 8, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { settle(0.1) }
        return done()
    }

    func testTheLastCardSwipedAwayRaisesTheSearchSheetBesideIt() {
        for round in 1...3 {
            let ready = Atlas.readyFolder()
            defer { try? FileManager.default.removeItem(at: ready) }
            let app = XCUIApplication()
            app.launchArguments = ["-YabWorld", "mira", "-YabState", "zero.lone", "-YabSearchSheet"]
            app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
            app.launchEnvironment["YAB_READY_DIR"] = ready.path
            app.launch()
            XCTAssertTrue(Atlas.waitForFile(ready.appendingPathComponent("zero.lone"), timeout: 60))
            let plus = app.buttons["chrome.plus"]
            XCTAssertTrue(plus.waitForExistence(timeout: 30))
            plus.press(forDuration: 0.8)
            let all = app.buttons["chrome.menu.alltabs"]
            XCTAssertTrue(all.waitForExistence(timeout: 5), "the hold has no All Tabs")
            all.tap()
            let card = element(app, "tabs.card.work-hn")
            XCTAssertTrue(card.waitForExistence(timeout: 5), "no card")
            settle()
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)), withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertTrue(element(app, "search.sheet").waitForExistence(timeout: 3), "round \(round): no sheet")
            settle(1.5)
            save(app, "last-card-sheet-\(round)")
            XCTAssertTrue(element(app, "search.sheet").exists, "round \(round): the sheet went away by itself")
            XCTAssertFalse(element(app, "empty.new").isHittable, "round \(round): the empty screen took over")
            app.terminate()
        }
    }

    func testTheLastCardSwipedAwayLeavesTheEmptyPageQuietly() {
        let ready = Atlas.readyFolder()
        defer { try? FileManager.default.removeItem(at: ready) }
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "zero.lone", "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launchEnvironment["YAB_READY_DIR"] = ready.path
        app.launch()
        XCTAssertTrue(Atlas.waitForFile(ready.appendingPathComponent("zero.lone"), timeout: 60))
        let plus = app.buttons["chrome.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 30))
        XCTAssertEqual(plus.label, "All Tabs", "one open tab stands in the stack")
        plus.press(forDuration: 0.8)
        let all = app.buttons["chrome.menu.alltabs"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "the hold has no All Tabs")
        XCTAssertEqual(all.label, "All Tabs · 1")
        save(app, "1-held")
        all.tap()
        let card = element(app, "tabs.card.work-hn")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card")
        settle()
        save(app, "2-one-card")
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)), withVelocity: .fast, thenHoldForDuration: 0)
        let new = element(app, "empty.new")
        XCTAssertTrue(new.waitForExistence(timeout: 8), "no empty screen")
        XCTAssertFalse(element(app, "chrome.toast.undo").waitForExistence(timeout: 1), "a close says nothing")
        save(app, "3-empty")
        app.terminate()
    }

    func testTheLastCardSwipedAwayOpensTheSearchSheet() { closeLastCard(state: "zero.lone") }

    func testTheLastKeptCardSwipedAwayOpensTheSearchSheet() { closeLastCard(state: "zero.keptLone") }

    private func closeLastCard(state: String) {
        let ready = Atlas.readyFolder()
        defer { try? FileManager.default.removeItem(at: ready) }
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabSearchSheet"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launchEnvironment["YAB_READY_DIR"] = ready.path
        app.launch()
        XCTAssertTrue(Atlas.waitForFile(ready.appendingPathComponent(state), timeout: 60))
        let stack = app.buttons["chrome.plus"]
        XCTAssertTrue(stack.waitForExistence(timeout: 30))
        stack.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'tabs.card.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card")
        settle()
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -380)), withVelocity: .fast, thenHoldForDuration: 0)
        settle(2)
        save(app, "8-last-card-closed-" + state)
        XCTAssertTrue(element(app, "search.sheet").waitForExistence(timeout: 3), "no sheet after the last card")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard after the last card")
        let sheet = element(app, "field.pill").frame
        XCTAssertLessThan(sheet.minY + sheet.height, app.windows.firstMatch.frame.height, "the sheet stayed under the screen")
        app.terminate()
    }

    func testAFreshProfilePassesTheWelcomeIntoTheFieldAndItsCancelIsTheEmptyPage() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-zero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 20), "no welcome")
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 8), "no field after the welcome")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "no keyboard after the welcome")
        settle()
        save(app, "5-first-run")
        XCTAssertTrue(app.closeField(), "the field did not close")
        let new = element(app, "empty.new")
        XCTAssertTrue(new.waitForExistence(timeout: 8), "no empty screen")
        settle()
        save(app, "6-first-run-cancelled")
        new.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 8), "+ didn't open search")
        // Relaunch: nothing was opened, so nothing is there.
        app.closeField()
        settle(1.5)
        app.terminate()
        app.launch()
        settle(2)
        save(app, "7-relaunched")
        XCTAssertTrue(wait { app.textFields["field.input"].exists || new.exists }, "a tab appeared after relaunch")
        app.terminate()
    }
}
