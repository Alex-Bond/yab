import XCTest

/// Native Safari on the farm lane's simulator, opened only to this test's
/// loopback article. This reference never opens a personal browser or account.
final class SafariMenuReferenceTests: XCTestCase {
    private var site: PageControlsSite!
    private var safari: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        site = try PageControlsSite()
        let ready = expectation(description: "Safari reference site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        safari?.terminate()
        site?.stop()
    }

    func testPageMenuOnOwnedArticleWithNativeDefaultMotion() throws {
        safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(site.url("article"))
        let page = safari.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Page controls article"].waitForExistence(timeout: 20))
        // The lane's fresh Safari may show its own first-launch toolbar tip.
        // Dismiss only the observed transient tip, without changing settings.
        let tip = safari.staticTexts["View Bookmarks, Share Menu, and Open Tabs"]
        if tip.exists {
            record("Safari owned first-launch toolbar tip")
            let close = safari.buttons["xmark.circle.fill"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(wait { !tip.exists })
        }
        record("Safari owned article before page menu")
        let ax = XCTAttachment(string: safari.debugDescription)
        ax.name = "Safari owned article before menu accessibility"; ax.lifetime = .keepAlways; add(ax)
        let menu = safari.buttons.matching(NSPredicate(format: "label ==[c] 'Page Menu'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "the native Page Menu must be identified before recording its transition")
        XCTAssertTrue(wait { menu.isHittable })
        let film = Atlas.environment["YAB_FILM_SAFARI_MENU"] == "1" ? Atlas.out.appendingPathComponent("film", isDirectory: true) : nil
        if let film {
            try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
            for name in ["ready", "recording", "done"] { try? FileManager.default.removeItem(at: film.appendingPathComponent(name)) }
            try Data().write(to: film.appendingPathComponent("ready"))
            XCTAssertTrue(Atlas.waitForFile(film.appendingPathComponent("recording"), timeout: 30))
        }
        let start = Date()
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let touched = Date()
        let reader = safari.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Show Reader' OR label ==[c] 'Reader'")).firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5), "the actual native Page Menu did not expand")
        let expanded = Date()
        record("Safari native page menu expanded and settled")
        let expandedAX = XCTAttachment(string: safari.debugDescription)
        expandedAX.name = "Safari native expanded menu accessibility"; expandedAX.lifetime = .keepAlways; add(expandedAX)
        safari.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        XCTAssertTrue(wait { !reader.exists && menu.isHittable })
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        record("Safari native menu dismissed to working owned page")
        if let film {
            try Atlas.json([
                "transition": "safariMenu", "state": "real owned article in lane Safari", "noAnimation": false,
                "start": start.timeIntervalSince1970, "touched": touched.timeIntervalSince1970,
                "expanded": expanded.timeIntervalSince1970, "arrived": Date().timeIntervalSince1970, "ok": true,
            ]).write(to: film.appendingPathComponent("done"))
        }
    }

    private func wait(_ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func record(_ name: String) {
        let shot = XCTAttachment(screenshot: safari.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
