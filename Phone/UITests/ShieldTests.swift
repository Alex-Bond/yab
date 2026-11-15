import XCTest

/// The ad blocker on a page, as a finger meets it (Page/Shield). The news
/// page (Pages/shield.html) asks for an ad script from doubleclick.net and a
/// pixel from google-analytics.com, served from the app when nothing stops
/// them, and has two ad slots the generic hiding names; its strip says what
/// loaded. Blocked by default (shield.1) and in a private tab (shield.3);
/// Site Settings' Block Ads and Trackers off loads the page again with all of
/// it, on again blocks it again; Settings › Privacy's switch off takes the
/// row out of Site Settings and the next load blocks nothing.
final class ShieldTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabNoAnim", "YES"]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func words(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.webViews.staticTexts[text].firstMatch
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// What the page's strip says once it has loaded.
    private func assertBlocked(_ app: XCUIApplication, _ blocked: Bool, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let script = blocked ? "Ad script: blocked" : "Ad script: loaded"
        XCTAssertTrue(words(app, script).waitForExistence(timeout: 30), "\(when): no \"\(script)\"", file: file, line: line)
        XCTAssertTrue(words(app, blocked ? "Tracker: blocked" : "Tracker: loaded").exists, "\(when): the tracker", file: file, line: line)
        XCTAssertTrue(words(app, blocked ? "Ad slots: hidden" : "Ad slots: shown").exists, "\(when): the ad slots", file: file, line: line)
        let sponsor = words(app, "Sponsored: a ferry pass for the whole summer")
        XCTAssertEqual(sponsor.exists, !blocked, "\(when): the ad script's box", file: file, line: line)
    }

    private func openSiteSettings(_ app: XCUIApplication) {
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no page menu button")
        menu.tap()
        let site = app.buttons["plate.menu.siteSettings"]
        XCTAssertTrue(site.waitForExistence(timeout: 5), "no Site Settings in the page menu")
        site.tap()
        XCTAssertTrue(app.buttons["site.back"].waitForExistence(timeout: 5), "Site Settings didn't open")
    }

    private func closeMenu(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(wait { !self.element(app, "plate.menu").exists }, "the page menu stayed")
    }

    /// A switch flipped where a finger would: its knob's side.
    private func flip(_ toggle: XCUIElement, to on: Bool) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no switch \(toggle)")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        if !wait({ (toggle.value as? String) == (on ? "1" : "0") }, timeout: 3) { toggle.tap() }
        XCTAssertTrue(wait { (toggle.value as? String) == (on ? "1" : "0") }, "the switch stayed \(String(describing: toggle.value))")
    }

    func testThePageIsBlockedAndSiteSettingsTurnsItOffAndOnForTheSite() {
        let app = launch("shield.1")
        assertBlocked(app, true, "by default")
        attach(app, "shield.1 blocked")

        openSiteSettings(app)
        let row = element(app, "site.blocksAds")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Block Ads and Trackers in Site Settings")
        let toggle = app.switches["site.blocksAds.toggle"]
        XCTAssertEqual(toggle.value as? String, "1", "on for a site nobody turned it off for")
        flip(toggle, to: false)
        attach(app, "site settings, off for the site")
        closeMenu(app)
        // Off for the site: the page loaded again with everything.
        assertBlocked(app, false, "off for the site")
        attach(app, "off for the site")

        openSiteSettings(app)
        flip(app.switches["site.blocksAds.toggle"], to: true)
        closeMenu(app)
        assertBlocked(app, true, "on again for the site")
    }

    func testAPrivateTabIsBlockedToo() {
        let app = launch("shield.3")
        assertBlocked(app, true, "in a private tab")
        attach(app, "shield.3 private")
    }

    func testTheSiteChoiceIsKeptForTheSite() {
        // shield.2 starts with the site off: the page has all of it.
        let app = launch("shield.2")
        assertBlocked(app, false, "off for the site")
        openSiteSettings(app)
        XCTAssertEqual(app.switches["site.blocksAds.toggle"].value as? String, "0")
    }

    func testTheSwitchInSettingsOffTakesTheRowAwayAndTheNextLoadBlocksNothing() {
        let app = launch("shield.site")
        assertBlocked(app, true, "by default")
        XCTAssertTrue(element(app, "site.blocksAds").waitForExistence(timeout: 5))
        // Yab Settings ›, Privacy, the switch.
        let yab = app.buttons["site.yabSettings"]
        for _ in 0..<3 where !yab.isHittable { element(app, "site.settings").swipeUp(velocity: .slow) }
        yab.tap()
        let privacy = app.buttons["settings.row.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), "Settings didn't open")
        for _ in 0..<4 where !privacy.isHittable { element(app, "settings.index").swipeUp(velocity: .slow) }
        privacy.tap()
        let main = app.switches["settings.row.privacy.shield"]
        XCTAssertTrue(main.waitForExistence(timeout: 5), "no Block ads and trackers in Privacy")
        XCTAssertEqual(main.value as? String, "1")
        flip(main, to: false)
        XCTAssertTrue(element(app, "settings.footer.privacy.shield").label.contains("Off. Every site loads everything it asks for."))
        attach(app, "settings, the blocker off")
        app.buttons["settings.back"].tap()
        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(wait { !self.element(app, "settings.sheet").exists }, "Settings stayed")

        openSiteSettings(app)
        XCTAssertFalse(element(app, "site.blocksAds").exists, "no per-site switch while the blocker is off")
        app.buttons["site.back"].tap()
        let reload = app.buttons["plate.menu.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 5))
        reload.tap()
        _ = wait({ !self.element(app, "plate.menu").exists }, timeout: 3)
        if element(app, "plate.menu").exists { closeMenu(app) }
        assertBlocked(app, false, "the switch off, reloaded")
    }
}
