import XCTest

/// Real drags in All Tabs over a large, isolated profile and loopback pages.
final class ManyTabsCloseUITests: XCTestCase {
    func testEightCardsCloseInAProfileWith512Tabs() throws {
        continueAfterFailure = false
        let site = try GoingBackSite()
        let ready = expectation(description: "loopback pages ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
        defer { site.stop() }
        let folder = URL(fileURLWithPath: "/tmp/yab-many-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tabs: [[String: Any]] = (0..<512).map { n in
            ["id": "tab-\(n)", "title": "Page \(n)", "site": "Loopback", "icon": "globe", "url": site.url("/one").absoluteString]
        }
        let profile: [String: Any] = ["version": 1, "spaceID": "s", "navigation": [String: Any](), "visits": [Any](), "spaces": [
            ["id": "s", "name": "Many Tabs", "emoji": "", "tint": [240, 240, 240], "today": tabs, "current": "tab-511"]
        ]]
        let file = folder.appendingPathComponent("profile.json")
        try JSONSerialization.data(withJSONObject: profile).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", site.url("/one").absoluteString,
                               "-YabNoAnim", "NO", "-YabTabWarmup", "NO"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        defer { app.terminate() }
        app.passWelcome()
        if app.textFields["field.input"].waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        XCTAssertTrue(app.webViews.staticTexts["Page one"].waitForExistence(timeout: 15))
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tabs.gallery"].firstMatch.waitForExistence(timeout: 10))
        func count() -> Int {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spaces = profile["spaces"] as? [[String: Any]] else { return -1 }
            return spaces.reduce(0) { $0 + (($1["today"] as? [[String: Any]])?.count ?? 0) }
        }
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(count(), 512)
        shot("512 tabs before closing")
        for n in 0..<8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -240)), withVelocity: .fast, thenHoldForDuration: 0)
            let deadline = Date().addingTimeInterval(10)
            while count() != 511 - n && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertEqual(count(), 511 - n, "each drag must close exactly one card")
        }
        shot("504 tabs after eight close drags")
    }
}
