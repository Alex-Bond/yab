import XCTest

/// Settings and the first launch, as a finger uses them: Settings is the
/// whole screen, its head under the status bar (settings.1), and closes by
/// ✕, by a swipe down on its head and by pulling its list past the top; a
/// row pushes its page and ‹ takes it back; a choice sticks; Sync and the welcome grow joining a Mac out of
/// themselves; Not Now leaves the empty browser with the New Tab field. None
/// of it is felt: the haptics journal stays empty. Which way a sheet came
/// and went is read from the motion journal (YAB_MOTION_JOURNAL). The
/// accessibility audit passes on each of these screens, one test each.
final class SettingsTests: XCTestCase {
    private var journal: URL!
    private var motions: URL!

    override func setUp() {
        continueAfterFailure = false
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        journal = folder.appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
        motions = folder.appendingPathComponent("yab-motions-\(UUID().uuidString).log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: motions)
    }

    // MARK: - the sheet

    func testTheSheetShowsTheActualMacStyleIndexAndNativeControls() {
        let app = launch("settings.1")
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "no Settings sheet")
        let screen = app.windows.firstMatch.frame
        // The whole screen, its head under the status bar (d0ca2190).
        XCTAssertEqual(sheet.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(sheet.frame.minX, 0, accuracy: 1)
        XCTAssertEqual(sheet.frame.width, screen.width, accuracy: 1)
        XCTAssertEqual(sheet.frame.maxY, screen.maxY, accuracy: 1)
        let title = element(app, "settings.title")
        XCTAssertEqual(title.label, "Settings")
        XCTAssertEqual(title.frame.midX, screen.midX, accuracy: 2, "the real native root title is centered")
        let close = app.buttons["settings.close"]
        XCTAssertEqual(close.frame.minX, 12, accuracy: 1, "× on the left")
        XCTAssertLessThan(close.frame.maxX, title.frame.minX)
        XCTAssertEqual(close.frame.midY, title.frame.midY, accuracy: 2, "one head: × and the title on one line")
        XCTAssertEqual(close.frame.width, 44, accuracy: 1)
        XCTAssertEqual(close.frame.height, 44, accuracy: 1)
        XCTAssertTrue(screen.contains(close.frame))
        XCTAssertGreaterThanOrEqual(close.frame.minY, 60)
        XCTAssertTrue(element(app, "settings.search").isHittable)
        let rows: [(String, String)] = [
            ("general", "General"), ("search", "Search"), ("appearance", "Appearance"), ("appIcon", "App Icon"), ("tabs", "Tabs"),
            ("ai", "AI"), ("spaces", "Spaces"), ("history", "History"), ("sync", "Sync"), ("passwords", "Passwords"),
            ("autofill", "Autofill"), ("privacy", "Privacy"), ("about", "About"), ("feedback", "Send Feedback"),
        ]
        for (id, words) in rows {
            let row = app.buttons["settings.row.\(id)"]
            for _ in 0..<4 where !(row.isHittable && screen.contains(row.frame)) { element(app, "settings.index").swipeUp(velocity: .slow) }
            XCTAssertTrue(row.isHittable, "no reachable row \(id)")
            XCTAssertTrue(screen.contains(row.frame), "the complete row must be in the native viewport")
            XCTAssertEqual(row.frame.minX, 16, accuracy: 1)
            XCTAssertEqual(row.frame.width, screen.width - 32, accuracy: 1)
            XCTAssertGreaterThanOrEqual(row.frame.height, 50)
            XCTAssertTrue(row.label.hasPrefix(words), "\(id) says \(row.label)")
            XCTAssertEqual(app.buttons.matching(identifier: "settings.row.\(id)").count, 1)
        }
        XCTAssertEqual(haptics, [], "Settings is quiet")
        attach(app, "Mac-style Settings root, all native rows and controls")
    }

    /// The word in the field opens Settings as a plain sheet from below
    /// (settingsOpen), never grown out of anything; × drops it
    /// (settingsClose) and nothing reopens behind it.
    func testSettingsRisesAsAPlainSheetAndDropsAway() {
        let app = launch("settings.2", still: false)
        let best = app.buttons["field.best"]
        XCTAssertTrue(best.waitForExistence(timeout: 15), "no Settings in the field")
        let before = played.count
        best.tap()
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "the word opens nothing")
        XCTAssertTrue(settle(sheet, minY: 0), "the sheet stands at \(sheet.frame)")
        let opened = Array(played.dropFirst(before))
        XCTAssertTrue(played.contains("settingsOpen"), "Settings didn't rise: \(played)")
        XCTAssertFalse(opened.contains("sheetGrow"), "Settings grew out of something: \(opened)")
        let closing = played.count
        app.buttons["settings.close"].tap()
        XCTAssertTrue(gone(sheet))
        let closed = Array(played.dropFirst(closing))
        XCTAssertTrue(closed.contains("settingsClose"), "Settings didn't drop: \(closed)")
        XCTAssertFalse(element(app, "newtab.spaces").exists, "closing Settings reopens nothing")
    }

    /// A page changes the body in place: the head's × becomes ‹ in the same
    /// spot, the root's rows go out of reach, and ‹ brings them back.
    func testAPageChangesTheBodyInPlaceUnderOneHead() {
        let app = launch("settings.1", still: false)
        let row = app.buttons["settings.row.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let close = app.buttons["settings.close"]
        let spot = close.frame
        row.tap()
        let back = app.buttons["settings.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        XCTAssertTrue(settleFrame(back, spot), "‹ isn't where × was: \(back.frame) vs \(spot)")
        XCTAssertFalse(close.exists, "one button: × became ‹")
        XCTAssertFalse(row.exists, "the root's rows are out of reach under the page")
        XCTAssertEqual(app.buttons.matching(identifier: "settings.back").count, 1)
        let page = element(app, "settings.page.title")
        XCTAssertGreaterThan(page.frame.minY, back.frame.maxY, "the page's title is in its body, under the head")
        back.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(settleFrame(close, spot))
        XCTAssertEqual(element(app, "settings.title").label, "Settings")
    }

    func testTheCrossClosesIt() {
        let app = launch("settings.1", still: false)
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        app.buttons["settings.close"].tap()
        XCTAssertTrue(gone(sheet), "✕ leaves the sheet up")
        XCTAssertEqual(haptics, [])
        // The journal is alive: holding the plate is felt (medium, menu), and
        // that is all there is in it.
        element(app, "chrome.plate").press(forDuration: 0.8)
        let end = Date().addingTimeInterval(3)
        while haptics.isEmpty, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(haptics, ["medium menu"])
    }

    func testASwipeDownOnTheHeadClosesItAndAShortOneDoesnt() {
        let app = launch("settings.1", still: false)
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let title = element(app, "settings.title")
        // A short pull: back in place.
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 50)), withVelocity: 120, thenHoldForDuration: 0.1)
        XCTAssertTrue(sheet.waitForExistence(timeout: 1))
        XCTAssertTrue(settle(sheet, minY: 0), "a short pull snaps back: \(sheet.frame)")
        // A real swipe: gone.
        title.swipeDown(velocity: .fast)
        XCTAssertTrue(gone(sheet), "a swipe down leaves the sheet up")
        XCTAssertEqual(haptics, [])
    }

    func testPullingTheListPastTheTopClosesIt() {
        let app = launch("settings.1", still: false)
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let row = app.buttons["settings.row.general"]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: 900, thenHoldForDuration: 0)
        XCTAssertTrue(gone(sheet), "pulled past the top, the sheet stays")
    }

    func testARowPushesItsPageAndAChoiceSticks() {
        let app = launch("settings.1", still: false)
        XCTAssertTrue(element(app, "settings.sheet").waitForExistence(timeout: 15))
        let row = app.buttons["settings.row.appearance"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("System"))
        let opened = played.count
        row.tap()
        let page = element(app, "settings.page.title")
        XCTAssertTrue(page.waitForExistence(timeout: 3), "no Appearance page")
        XCTAssertEqual(page.label, "Appearance")
        let grew = Array(played.dropFirst(opened))
        XCTAssertTrue(grew.contains("settingsPush"), "the actual page did not push: \(grew)")
        XCTAssertFalse(grew.contains("sheetRise"), "the page rose from nowhere: \(grew)")
        let dark = app.buttons["settings.choice.appearance.dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        XCTAssertFalse(dark.isSelected)
        XCTAssertTrue(app.buttons["settings.choice.appearance.system"].isSelected)
        dark.tap()
        XCTAssertTrue(dark.isSelected, "Dark isn't chosen")
        XCTAssertFalse(app.buttons["settings.choice.appearance.system"].isSelected)
        let back = played.count
        app.buttons["settings.back"].tap()
        XCTAssertTrue(gone(page), "‹ leaves the page up")
        let went = Array(played.dropFirst(back))
        XCTAssertTrue(went.contains("settingsBack"), "Back did not pop the actual page: \(went)")
        XCTAssertFalse(went.contains("sheetDrop"), "‹ dropped the page: \(went)")
        XCTAssertTrue(row.label.contains("Dark"), "the row says \(row.label)")
        XCTAssertEqual(haptics, [])
    }

    /// Settings opened again starts at its top, wherever it was left.
    func testSettingsOpensAgainAtItsTop() {
        // The Mac-style twelve-row root almost fits at ordinary XXXL. Use
        // the actual largest accessibility font so this exercises overflow.
        let app = launch("settings.1", still: false, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let mac = app.buttons["settings.row.general"]
        let top = mac.frame.minY
        attach(app, "Settings maximum accessibility font before actual list scroll")
        element(app, "settings.index").swipeUp(velocity: .slow)
        attach(app, "Settings maximum accessibility font after actual list scroll")
        XCTAssertLessThan(mac.frame.minY, top - 20, "the list didn't scroll")
        app.buttons["settings.close"].tap()
        XCTAssertTrue(gone(sheet))
        // Again, by the word in the field.
        element(app, "chrome.plate").tap()
        let input = element(app, "field.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "no field")
        input.typeText("settings\n")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the word didn't open Settings")
        XCTAssertTrue(settle(sheet, minY: 0))
        XCTAssertEqual(app.buttons["settings.row.general"].frame.minY, top, accuracy: 1, "Settings opened where it was left")
    }

    func testSyncOpensJoiningAMac() {
        let app = launch("settings.1", still: false)
        let root = app.buttons["settings.row.sync"]
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        root.tap()
        let mac = app.buttons["settings.row.mac"]
        XCTAssertTrue(mac.waitForExistence(timeout: 5))
        mac.tap()
        XCTAssertTrue(element(app, "settings.page.title").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "settings.page.title").label, "Your Mac")
        let sync = app.buttons["settings.row.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 3))
        let tapped = played.count
        sync.tap()
        let join = element(app, "join.sheet")
        XCTAssertTrue(join.waitForExistence(timeout: 3), "Sync opens nothing")
        let grew = Array(played.dropFirst(tapped))
        XCTAssertTrue(grew.contains("sheetGrow"), "joining didn't grow out of the Sync row: \(grew)")
        XCTAssertEqual(element(app, "join.title").label, "Join Your Mac")
        app.buttons["join.close"].tap()
        XCTAssertTrue(gone(join))
        XCTAssertEqual(element(app, "settings.page.title").label, "Your Mac", "the Mac's page stays under it")
        XCTAssertEqual(haptics, [])
    }

    // MARK: - the first launch

    func testWithoutAMacLeavesTheEmptyBrowser() {
        let app = launch(nil, world: "empty", still: false)
        let welcome = element(app, "welcome")
        XCTAssertTrue(welcome.waitForExistence(timeout: 15), "the empty world doesn't welcome")
        // The welcome's own button, then the three ways to join.
        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "no Get Started on the welcome")
        start.waitUntilStill()
        start.tap()
        let noMac = app.buttons["welcome.noMac"]
        XCTAssertTrue(noMac.waitForExistence(timeout: 5), "Get Started shows no ways to join")
        XCTAssertTrue(app.buttons["welcome.useCode"].exists, "no Another Apple ID")
        noMac.waitUntilStill()
        noMac.tap()
        // Private by Default, then the default-browser question if it is asked.
        let carryOn = app.buttons["welcome.continue"]
        XCTAssertTrue(carryOn.waitForExistence(timeout: 5), "no Private by Default after the choice")
        XCTAssertTrue(app.switches["welcome.blockAds"].exists, "no Block ads and trackers row")
        carryOn.waitUntilStill()
        carryOn.tap()
        let links = app.buttons["welcome.linksNotNow"]
        if links.waitForExistence(timeout: 5) { links.waitUntilStill(); links.tap() }
        XCTAssertTrue(gone(welcome), "Continue Without a Mac leaves the welcome up")
        XCTAssertTrue(element(app, "page.host").exists)
        // Somewhere to go: the New Tab field the icon stretched into.
        XCTAssertTrue(element(app, "field.input").waitForExistence(timeout: 5), "the first run leaves a blank screen")
        XCTAssertEqual(haptics, ["light confirm", "light confirm", "light confirm"],
                       "one light tap a step, nothing else, no permission asked")
    }

    func testAnotherAppleIDShowsTheCodeAndComesBack() {
        let app = launch(nil, world: "empty", still: false)
        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(TransitionCatalog.wait { start.isHittable })
        start.tap()
        let useCode = app.buttons["welcome.useCode"]
        XCTAssertTrue(useCode.waitForExistence(timeout: 5))
        XCTAssertTrue(TransitionCatalog.wait { useCode.isHittable })
        useCode.tap()
        let code = element(app, "welcome.code")
        XCTAssertTrue(code.waitForExistence(timeout: 3), "Another Apple ID shows no code")
        XCTAssertEqual(code.label.split(separator: " ").count, 8, "eight keycaps: \(code.label)")
        let recovery = app.buttons["welcome.recovery"]
        XCTAssertTrue(TransitionCatalog.wait { recovery.isHittable }, "Use Recovery Key can't be pressed")
        recovery.tap()
        XCTAssertTrue(element(app, "welcome.key").waitForExistence(timeout: 3), "Use Recovery Key shows no groups")
        let back = app.buttons["welcome.back"]
        XCTAssertTrue(TransitionCatalog.wait { back.isHittable }, "no ‹ on the Recovery Key")
        back.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 3), "‹ from the Recovery Key goes back to the code")
        XCTAssertTrue(TransitionCatalog.wait { back.isHittable }, "no ‹ on the code")
        back.tap()
        XCTAssertTrue(useCode.waitForExistence(timeout: 3), "‹ from the code goes back to the three ways")
    }

    func testOfflineCodeWaitsAndSaysWhy() {
        let app = launch("welcome.2", world: "empty")
        let caption = element(app, "welcome.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 15), "offline, nothing says why")
        XCTAssertEqual(caption.label, "No connection. Yab keeps trying.")
    }

    func testAWrongRecoveryKeySaysSoAtOnce() {
        let app = launch("welcome.12", world: "empty")
        let wrong = element(app, "welcome.wrong")
        XCTAssertTrue(wrong.waitForExistence(timeout: 15))
        XCTAssertEqual(wrong.label, "That isn\u{2019}t a Recovery Key. Check each group of four.")
    }

    func testNoMacYetSettingsAsksToJoin() {
        let app = launch("welcome.4", world: "empty")
        let sync = app.buttons["settings.row.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 15))
        sync.tap()
        let join = app.buttons["settings.row.join"]
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        XCTAssertTrue(join.label.hasPrefix("Join Your Mac"))
        XCTAssertFalse(app.buttons["settings.row.mac"].exists)
        join.tap()
        XCTAssertTrue(element(app, "join.sheet").waitForExistence(timeout: 3))
    }

    // MARK: - accessibility

    // One screen each, so one slow launch on a busy Mac costs one test.

    func testTheAuditPassesOnSettings() throws { try audit("settings.1", mark: "settings.sheet") }
    func testTheAuditPassesOnSettingsScrolled() throws { try audit("settings.3", mark: "settings.sheet") }
    func testTheAuditPassesOnTheMacsPage() throws { try audit("settings.page-mac", mark: "settings.page.title") }
    func testTheAuditPassesOnAppearance() throws { try audit("settings.page-appearance", mark: "settings.page.title") }
    func testAppearanceChoicesStayAccessibleAtTheLargestTextSize() throws {
        let app = try audit("settings.page-appearance", mark: "settings.page.title", xxxl: true)
        let page = element(app, "settings.page.title")
        XCTAssertEqual(page.label, "Appearance")
        for (value, words) in [("system", "System"), ("light", "Light"), ("dark", "Dark")] {
            let id = "settings.choice.appearance.\(value)"
            let choice = app.buttons[id]
            XCTAssertEqual(app.buttons.matching(identifier: id).count, 1, "one real button for \(words)")
            XCTAssertEqual(choice.label, words)
            XCTAssertTrue(choice.isHittable, "\(words) isn't reachable at XXXL")
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44)
        }
        let system = app.buttons["settings.choice.appearance.system"]
        let light = app.buttons["settings.choice.appearance.light"]
        let dark = app.buttons["settings.choice.appearance.dark"]
        XCTAssertTrue(system.isSelected)
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        XCTAssertFalse(system.isSelected)
        XCTAssertFalse(light.isSelected)

        app.buttons["settings.back"].tap()
        XCTAssertTrue(gone(page), "Back leaves Appearance up")
        XCTAssertTrue(element(app, "settings.title").waitForExistence(timeout: 3))
        let row = app.buttons["settings.row.appearance"]
        let sheet = element(app, "settings.sheet")
        for _ in 0..<4 where !row.isHittable { sheet.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "Appearance isn't reachable after Back at XXXL")
        XCTAssertTrue(row.label.contains("Dark"), "the saved choice isn't reflected: \(row.label)")
        row.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 3))
        XCTAssertTrue(dark.isSelected, "reopening Appearance lost the choice")
        XCTAssertFalse(system.isSelected)
        XCTAssertFalse(light.isSelected)
        XCTAssertEqual(haptics, [])
    }

    func testTheAuditPassesOnFaceID() throws { try audit("settings.page-faceID", mark: "settings.page.title") }
    func testTheAuditPassesOnNotifications() throws { try audit("settings.page-notifications", mark: "settings.page.title") }
    func testTheAuditPassesOnTheWelcome() throws { try audit("welcome.1", world: "empty", mark: "welcome") }
    func testTheAuditPassesOffline() throws { try audit("welcome.2", world: "empty", mark: "welcome") }
    func testTheAuditPassesOnNoMacYet() throws { try audit("welcome.4", world: "empty", mark: "settings.sheet") }
    func testTheAuditPassesOnTheChoice() throws { try audit("welcome.5", world: "empty", mark: "welcome") }
    func testTheAuditPassesOnTheCode() throws { try audit("welcome.9", world: "empty", mark: "welcome") }

    func testTheAuditPassesOnSettingsAtTheLargestTextSize() throws {
        let app = try audit("settings.1", mark: "settings.sheet", xxxl: true)
        // Every row still whole: nothing cut, all of it reachable.
        let privacy = app.buttons["settings.row.privacy"]
        for _ in 0..<4 where !privacy.isHittable { element(app, "settings.index").swipeUp(velocity: .slow) }
        XCTAssertTrue(privacy.isHittable)
        privacy.tap()
        let row = app.buttons["settings.row.faceID"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        XCTAssertTrue(row.label.contains("On"))
    }

    func testTheAuditPassesOnAPageAtTheLargestTextSize() throws {
        try audit("settings.page-notifications", mark: "settings.page.title", xxxl: true)
    }

    func testTheAuditPassesOnAToggleAtTheLargestTextSize() throws {
        try audit("settings.page-faceID", mark: "settings.page.title", xxxl: true)
    }

    func testTheAuditPassesOnTheWelcomeAtTheLargestTextSize() throws {
        try audit("welcome.1", world: "empty", mark: "welcome", xxxl: true)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let photo = XCTAttachment(screenshot: app.screenshot()); photo.name = name; photo.lifetime = .keepAlways; activity.add(photo)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " AX"; tree.lifetime = .keepAlways; activity.add(tree)
        }
    }

    // MARK: - helpers

    private func launch(_ state: String?, world: String = "mira", still: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-YabWorld", world]
        if let state { arguments += ["-YabState", state] }
        if still { arguments += ["-YabNoAnim", "YES"] }
        app.launchArguments = arguments + extra
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launchEnvironment["YAB_MOTION_JOURNAL"] = motions.path
        app.launch()
        return app
    }

    /// Launched in `state` with `mark` on screen. A launch that never gets
    /// there (a busy Mac's slow automation session) is tried once more
    /// before it counts.
    private func launchReady(_ state: String, world: String, mark: String, extra: [String] = []) -> XCUIApplication {
        var app = launch(state, world: world, extra: extra)
        if !element(app, mark).waitForExistence(timeout: 20) {
            app.terminate()
            app = launch(state, world: world, extra: extra)
        }
        XCTAssertTrue(element(app, mark).waitForExistence(timeout: 20), "\(state): no \(mark)")
        return app
    }

    /// The motions run since launch, by name, in order.
    private var played: [String] {
        guard let text = try? String(contentsOf: motions, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { $0.split(separator: " ").last.map(String.init) }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// The haptics played since launch, "<kind> <reason>" each.
    private var haptics: [String] {
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: " ").dropFirst().joined(separator: " ") }
    }

    private func gone(_ element: XCUIElement, timeout: TimeInterval = 4) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func settleFrame(_ element: XCUIElement, _ frame: CGRect, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists, abs(element.frame.minX - frame.minX) < 1, abs(element.frame.minY - frame.minY) < 1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func settle(_ element: XCUIElement, minY: CGFloat, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if element.exists, abs(element.frame.minY - minY) < 1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// The system's audit over one of these screens. An issue is this
    /// branch's when its element hangs inside Settings, a page, joining or
    /// the welcome in the tree, whatever its identifier; those are listed in
    /// one failure. Elements of the page and chrome behind are attached for
    /// their owners. The one allowance: words passing under the list's soft
    /// edge in a scrolled state fade there by design (motion.md, "Scroll
    /// edges"), so a contrast issue on an element under that band is listed,
    /// not failed. An audit the busy Mac couldn't finish is tried once more
    /// on a new launch.
    @discardableResult
    private func audit(_ state: String, world: String = "mira", mark: String, xxxl: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = true
        let extra = xxxl ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] : []
        let name = xxxl ? "\(state) at XXXL" : state
        var app = launchReady(state, world: world, mark: mark, extra: extra)
        var result: AuditResult
        do {
            result = try audit(app)
        } catch {
            print("AUDIT \(name): \(error), once more")
            app.terminate()
            app = launchReady(state, world: world, mark: mark, extra: extra)
            result = try audit(app)
        }
        for (title, lines) in [("issues outside this branch's screens", result.foreign),
                               ("words under the soft edge, fading there by design", result.underEdge)] where !lines.isEmpty {
            let note = XCTAttachment(string: lines.joined(separator: "\n"))
            note.name = "\(name): \(title)"
            note.lifetime = .keepAlways
            add(note)
        }
        print("AUDIT \(name): \(result.mine.count) ours, \(result.underEdge.count) under the edge, \(result.foreign.count) elsewhere")
        if !result.mine.isEmpty {
            print("AUDIT \(name):\n" + result.mine.joined(separator: "\n"))
            XCTFail("\(name): \(result.mine.count) audit issue(s):\n" + result.mine.joined(separator: "\n"))
        }
        return app
    }

    private struct AuditResult {
        var mine: [String] = []
        var underEdge: [String] = []
        var foreign: [String] = []
    }

    private func audit(_ app: XCUIApplication) throws -> AuditResult {
        let ours = try ourElements(app)
        let edge = softEdge(app)
        var result = AuditResult()
        try app.performAccessibilityAudit { issue in
            let snap = try? issue.element?.snapshot()
            let frame = snap?.frame ?? .zero
            let line = "\(issue.compactDescription): [\(snap?.identifier ?? "")] \(snap?.label ?? "") \(frame) \(issue.detailedDescription)"
            let isOurs = snap.map { ours.contains(Self.signature($0)) } ?? false
            if !isOurs {
                result.foreign.append(line)
            } else if issue.auditType == .contrast, let edge, frame.intersects(edge) {
                result.underEdge.append(line)
            } else {
                result.mine.append(line)
            }
            return true
        }
        return result
    }

    /// Every element inside this branch's screens, by what the tree says of it.
    private func ourElements(_ app: XCUIApplication) throws -> Set<String> {
        let root = try app.snapshot()
        var out = Set<String>()
        func visit(_ node: XCUIElementSnapshot, inside: Bool) {
            let id = node.identifier
            let here = inside || id == "settings.sheet" || id.hasPrefix("settings.page.") || id == "join.sheet" || id == "welcome"
            if here { out.insert(Self.signature(node)) }
            node.children.forEach { visit($0, inside: here) }
        }
        visit(root, inside: false)
        return out
    }

    private static func signature(_ e: XCUIElementAttributes) -> String {
        let f = e.frame
        return "\(e.elementType.rawValue)|\(Int(f.minX.rounded()))|\(Int(f.minY.rounded()))|\(Int(f.width.rounded()))|\(Int(f.height.rounded()))|\(e.identifier)|\(e.label)"
    }

    /// The band of the soft edge over a scrolled list: 26 under the head
    /// (the round ✕'s row and its 6 below). Nil while the list is at its top.
    private func softEdge(_ app: XCUIApplication) -> CGRect? { nil }
}
