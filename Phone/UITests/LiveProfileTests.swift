import Network
import UIKit
import XCTest

/// A normal launch browses HTTP and restores the same page after quitting.
/// An in-process loopback fixture avoids external sites and the person's data.
final class LiveProfileTests: XCTestCase {
    private var server: ProfileTestSite!
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-live-profile-\(UUID().uuidString)")
        server = try ProfileTestSite()
        let ready = expectation(description: "loopback site ready")
        server.ready = { ready.fulfill() }
        server.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        server?.stop()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
           let profile = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: profile)
            attachment.name = "real-profile-before-cleanup"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch(url: URL? = nil, animationsEnabled: Bool = false, filmFolder: URL? = nil, privateAuthentication: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabNoAnim", animationsEnabled ? "NO" : "YES"]
        if let url { app.launchArguments += ["-YabURL", url.absoluteString] }
        if let privateAuthentication { app.launchArguments += ["-YabPrivateLockTestAuthentication", privateAuthentication] }
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        if let filmFolder {
            app.launchEnvironment["YAB_FRAMEMETER"] = "1"
            app.launchEnvironment["YAB_FILM_MARK"] = filmFolder.appendingPathComponent("recording").path
            app.launchEnvironment["YAB_PERF_OUT"] = filmFolder.appendingPathComponent("frames.jsonl").path
        }
        app.terminate()
        app.launch()
        // Test settings start empty at every launch. Follow the real welcome,
        // then close the New Tab field it opens before touching the page:
        // by its ✕, since New Tab's spaces fill the screen around the field
        // and a tap beside it lands on a row.
        let notNow = app.buttons["welcome.start"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        app.passWelcome()
        XCTAssertTrue(wait { !app.alerts["welcome"].exists })
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the welcome's New Tab field stayed over the page")
        return app
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func savedTab() -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = json["spaces"] as? [[String: Any]] else { return nil }
        return spaces.lazy.compactMap { space -> [String: Any]? in
            guard let current = space["current"] as? String,
                  let today = space["today"] as? [[String: Any]] else { return nil }
            return today.first { $0["id"] as? String == current }
        }.first
    }

    private func savedURL() -> String? { savedTab()?["url"] as? String }
    private func savedTitle() -> String? { savedTab()?["title"] as? String }

    private func record(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCookieAndLocalStorageSurviveProfileMoveAndProcessRelaunch() throws {
        var app = launch(url: server.url.appendingPathComponent("identity-seed"))
        XCTAssertTrue(app.webViews.staticTexts["Profile seeded"].waitForExistence(timeout: 15))
        app.webViews.links["Check profile storage"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Profile cookie kept"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Profile local kept"].exists)
        XCTAssertTrue(wait { self.savedURL() == self.server.url.appendingPathComponent("identity-check").absoluteString })
        app.terminate()

        let previous = try XCTUnwrap(folder)
        let moved = previous.deletingLastPathComponent().appendingPathComponent("yab-live-profile-moved-\(UUID())")
        try FileManager.default.moveItem(at: previous, to: moved)
        folder = moved
        app = launch()
        XCTAssertTrue(app.webViews.staticTexts["Profile cookie kept"].waitForExistence(timeout: 15),
                      "the restored page must receive its persisted cookie without seeding it again")
        XCTAssertTrue(app.webViews.staticTexts["Profile local kept"].exists,
                      "the same WebKit namespace must retain localStorage across a process relaunch")
    }

    func testAddressFieldBlursRealPageAndRestoresPageTouches() throws {
        let app = launch(url: server.url.appendingPathComponent("field-backdrop"))
        let action = app.webViews.buttons["Page action"]
        XCTAssertTrue(action.waitForExistence(timeout: 15))
        func record(_ name: String) {
            let photo = XCTAttachment(screenshot: app.screenshot())
            photo.name = name
            photo.lifetime = .keepAlways
            add(photo)
        }
        record("Real page before address editing")
        app.descendants(matching: .any)["chrome.plate"].firstMatch.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        record("Real page through address blur")
        XCTAssertTrue(app.closeField())
        action.tap()
        XCTAssertTrue(app.webViews.staticTexts["Page action worked"].waitForExistence(timeout: 5))
        record("Real page after address editing")
    }

    func testActualScrollThenOneFoldedPlateTapOpensTheSameAddress() throws {
        try checkFoldedAddressTap(isPrivate: false)
    }

    func testActualPrivateScrollThenOneFoldedPlateTapKeepsPrivateActions() throws {
        try checkFoldedAddressTap(isPrivate: true)
    }

    func testFoldedMovementKeepsTheNextTapAndUpwardSpacesGesture() throws {
        let url = server.url.appendingPathComponent("viewport-normal")
        let app = launch(url: url, animationsEnabled: true)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Viewport header"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedURL() == url.absoluteString })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try XCTUnwrap(savedNavigation(id))
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        let window = app.windows.firstMatch
        let input = app.textFields["field.input"]
        func foldByPageScroll() {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                .press(forDuration: 0.08, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
            XCTAssertTrue(wait { plate.value as? String == "folded" && abs(plate.frame.height - 44) < 1 })
        }
        func plateCenter() -> XCUICoordinate {
            let frame = plate.frame
            return window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
        }
        foldByPageScroll()
        let horizontal = plateCenter()
        horizontal.press(forDuration: 0.05, thenDragTo: horizontal.withOffset(CGVector(dx: -60, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertFalse(input.exists, "movement of the folded pill must not fire its address button")
        XCTAssertEqual(plate.value as? String, "folded")
        record(app.screenshot(), name: "Folded horizontal movement kept the same page")
        // The very next physical tap must work. No waiting or second tap
        // can hide a movement cooldown that swallows an intended address tap.
        plateCenter().tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5), "the first tap after movement was swallowed")
        XCTAssertEqual(input.value as? String, url.absoluteString)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        record(app.screenshot(), name: "Folded movement followed by the first intended tap")
        app.closeField()
        XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists && plate.value as? String == "open" })
        foldByPageScroll()
        let vertical = plateCenter()
        vertical.press(forDuration: 0.05, thenDragTo: vertical.withOffset(CGVector(dx: 0, dy: -160)),
                       withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(wait { app.descendants(matching: .any)["newtab.spaces"].exists },
                      "an upward folded-plate gesture must bring the spaces")
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedURL(), url.absoluteString)
        let after = try XCTUnwrap(savedNavigation(id))
        XCTAssertEqual(after.urls, before.urls)
        XCTAssertEqual(after.index, before.index)
        record(app.screenshot(), name: "Folded upward movement brought the spaces over the same page")
    }

    private func checkFoldedAddressTap(isPrivate: Bool) throws {
        let mode = isPrivate ? "private" : "public"
        let url = try XCTUnwrap(URL(string: "viewport-normal?q=" + mode + "%2B1#part", relativeTo: server.url)?.absoluteURL)
        let app = launch(url: isPrivate ? nil : url, animationsEnabled: true, privateAuthentication: isPrivate ? "off" : nil)
        if isPrivate {
            let plus = app.buttons["chrome.plus"]
            XCTAssertTrue(wait { plus.isHittable })
            plus.tap()
            let input = app.textFields["field.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            let eyes = app.descendants(matching: .any)["field.eyes"].firstMatch
            XCTAssertTrue(eyes.isHittable)
            eyes.tap()
            XCTAssertEqual(eyes.value as? String, "on")
            input.typeText(url.absoluteString)
            let go = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
            XCTAssertTrue(go.isHittable)
            go.tap()
            XCTAssertTrue(wait { !input.exists })
            XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        }
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Viewport header"].waitForExistence(timeout: 15))
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        let tabID: String?
        let before: (urls: [String], index: Int)?
        if isPrivate {
            tabID = nil
            before = nil
        } else {
            XCTAssertTrue(wait { self.savedURL() == url.absoluteString })
            let id = try XCTUnwrap(savedTab()?["id"] as? String)
            tabID = id
            before = try XCTUnwrap(savedNavigation(id))
        }
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.08, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        XCTAssertTrue(wait { plate.value as? String == "folded" && abs(plate.frame.height - 44) < 1 },
                      "the actual scroll did not reach its folded 44-point target")
        XCTAssertFalse(app.buttons["chrome.pageMenu"].exists)
        record(app.screenshot(), name: "Folded address \(mode) before one tap")
        record(plate.screenshot(), name: "Folded address \(mode) 44pt target around 34pt glass")
        let window = app.windows.firstMatch
        let frame = plate.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)).tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "one folded tap must open the address, not need a second tap")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, url.absoluteString)
        // The plate's field has no page card since 448423cb (the page's
        // actions are its menu's, checked below): ⓧ clears the address, and
        // no eyes while it holds words.
        XCTAssertTrue(app.buttons["field.clearWords"].isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["field.eyes"].exists)
        record(app.screenshot(), name: "Folded address \(mode) opened by one tap")
        app.closeField()
        XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists && plate.exists && plate.value as? String == "open" })
        let dismissed = XCTAttachment(string: "Address field closed; plate group isHittable=\(plate.isHittable)\n\(app.debugDescription)")
        dismissed.name = "Folded address \(mode) browser touch target after dismissal"
        dismissed.lifetime = .keepAlways
        add(dismissed)
        record(app.screenshot(), name: "Folded address \(mode) browser after dismissal")
        // The pill is an accessibility group. Touch its actual center again
        // to prove the address button works after the field closes.
        let reopenedFrame = plate.frame
        XCTAssertGreaterThan(reopenedFrame.width, 0)
        XCTAssertGreaterThan(reopenedFrame.height, 0)
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: reopenedFrame.midX - window.frame.minX, dy: reopenedFrame.midY - window.frame.minY)).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5), "the real address button stopped accepting taps after dismissal")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, url.absoluteString)
        XCTAssertTrue(app.buttons["field.clearWords"].isHittable)
        record(app.screenshot(), name: "Folded address \(mode) reopened by browser tap")
        app.closeField()
        XCTAssertTrue(wait { !input.exists && !app.keyboards.firstMatch.exists && plate.exists && plate.value as? String == "open" })
        // The page's actions, in its menu: a private page keeps Find and
        // Share without Keep. Ask and On Mac need a Mac, which this run has not.
        app.buttons["chrome.pageMenu"].tap()
        XCTAssertTrue(app.buttons["plate.menu.share"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["plate.menu.find"].exists)
        XCTAssertEqual(app.buttons["plate.menu.keep"].exists, !isPrivate)
        XCTAssertFalse(app.buttons["plate.menu.ask"].exists)
        XCTAssertFalse(app.buttons["plate.menu.onMac"].exists)
        record(app.screenshot(), name: "Folded address \(mode) page menu actions")
        app.descendants(matching: .any)["plate.menu.scrim"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(wait { !app.descendants(matching: .any)["plate.menu"].exists })
        if let tabID {
            XCTAssertEqual(savedTab()?["id"] as? String, tabID)
            XCTAssertEqual(savedURL(), url.absoluteString)
            let after = try XCTUnwrap(savedNavigation(tabID))
            XCTAssertEqual(after.index, before?.index)
            XCTAssertEqual(after.urls, before?.urls)
        } else {
            let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(url.absoluteString),
                           "editing a private address must not persist its URL")
        }
        record(app.screenshot(), name: "Folded address \(mode) after field dismissal")
    }

    func testCoverViewportKeepsFixedControlsOutsideHardwareAndChrome() throws {
        try checkViewport("viewport-cover")
    }

    func testNormalViewportKeepsFixedControlsOutsideHardwareAndChrome() throws {
        try checkViewport("viewport-normal")
    }

    private func checkViewport(_ path: String) throws {
        let app = launch(url: server.url.appendingPathComponent(path))
        let page = app.webViews.firstMatch
        let header = page.staticTexts["Viewport header"]
        let footer = page.staticTexts["Viewport footer"]
        XCTAssertTrue(header.waitForExistence(timeout: 30))
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        let status = app.statusBars.firstMatch.exists ? app.statusBars.firstMatch
            : XCUIApplication(bundleIdentifier: "com.apple.springboard").statusBars.firstMatch
        XCTAssertTrue(status.exists, "the native hardware boundary must be measured")
        XCTAssertGreaterThan(status.frame.height, 0)
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        assertFixedControls(app, page: page, header: header, footer: footer,
                            top: status.frame.maxY, bottom: plate.frame.minY, phase: "\(path)-unfolded")
        let expandedPlate = plate.frame
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28)))
        XCTAssertTrue(wait { plate.value as? String == "folded" && abs(plate.frame.height - 44) < 1 }, "the real page scroll must fold the chrome")
        XCTAssertTrue(wait { footer.frame.maxY > expandedPlate.minY }, "the fixed footer must use the newly visible area")
        assertFixedControls(app, page: page, header: header, footer: footer,
                            top: status.frame.maxY, bottom: plate.frame.midY - 34 / 2, phase: "\(path)-folded")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        XCTAssertTrue(wait { plate.frame.height >= expandedPlate.height - 1 }, "scrolling up must restore the chrome")
        assertFixedControls(app, page: page, header: header, footer: footer,
                            top: status.frame.maxY, bottom: plate.frame.minY, phase: "\(path)-unfolded-again")
    }

    private func assertFixedControls(_ app: XCUIApplication, page: XCUIElement, header: XCUIElement,
                                     footer: XCUIElement, top: CGFloat, bottom: CGFloat, phase: String) {
        XCTAssertTrue(wait { header.frame.minY >= top - 1 && footer.frame.maxY <= bottom + 1 },
                      "\(phase): fixed controls overlap hardware/chrome: header=\(header.frame), footer=\(footer.frame), safe=\(top)...\(bottom)")
        // A safe-area CSS declaration must not duplicate the native inset.
        // Text sits 9 points inside each 40-point fixed bar on this test site.
        XCTAssertLessThan(header.frame.minY - top, 30, "the header acquired a second top inset")
        XCTAssertLessThan(bottom - footer.frame.maxY, 30, "the footer acquired a second bottom inset")
        XCTAssertTrue(header.isHittable)
        XCTAssertTrue(footer.isHittable)
        let report = page.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Viewport CSS ")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        let note = XCTAttachment(string: "CSS: \(report.label)\nStatus top: \(top), chrome top: \(bottom)\nHeader: \(header.frame), footer: \(footer.frame)\nAX:\n\(app.debugDescription)")
        note.name = "safe-area-\(phase)"
        note.lifetime = .keepAlways
        add(note)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "safe-area-\(phase)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSafariPagePillReloadStopAndAddressKeepCurrentTab() throws {
        let first = server.url.appendingPathComponent("refresh-start")
        let second = URL(string: "refresh-page?q=a%2Bb#part", relativeTo: server.url)!.absoluteURL
        let app = launch(url: first)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.links["Open refresh page"].waitForExistence(timeout: 15))
        page.links["Open refresh page"].tap()
        XCTAssertTrue(page.staticTexts["Refresh request 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try XCTUnwrap(savedNavigation(id))
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        let menu = app.buttons["chrome.pageMenu"]
        let reload = app.buttons["chrome.reload"]
        XCTAssertTrue(wait { reload.label == "Reload Page" && reload.isEnabled })
        XCTAssertTrue(menu.isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.minX, plate.frame.minX)
        XCTAssertLessThanOrEqual(menu.frame.maxX, reload.frame.minX)
        XCTAssertLessThanOrEqual(reload.frame.maxX, plate.frame.maxX)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(reload.frame.width, 44)
        record(app.screenshot(), name: "Safari page pill actual normal page")
        server.holdNextRefreshResponse()
        reload.tap()
        XCTAssertTrue(wait { self.server.count(of: "/refresh-page") == 2 && reload.label == "Stop Loading" })
        record(app.screenshot(), name: "Safari page pill actual loading and Stop")
        reload.tap()
        XCTAssertTrue(wait { reload.label == "Reload Page" }, "Stop did not finish the actual navigation")
        server.releaseRefreshResponse()
        reload.tap()
        XCTAssertTrue(page.staticTexts["Refresh request 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { reload.label == "Reload Page" })
        XCTAssertTrue(page.staticTexts["Refresh storage kept"].exists)
        XCTAssertEqual(server.count(of: "/refresh-page"), 3)
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString })
        let after = try XCTUnwrap(savedNavigation(id))
        XCTAssertEqual(after.urls, before.urls)
        XCTAssertEqual(after.index, before.index)
        menu.tap()
        XCTAssertTrue(app.buttons["plate.menu.reader"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["plate.menu.reader"].isEnabled, "a short fixture must not offer a fake Reader")
        app.descendants(matching: .any)["plate.menu.scrim"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(wait { !app.descendants(matching: .any)["plate.menu"].exists })
        plate.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5), "the center address no longer opens its field")
        record(app.screenshot(), name: "Safari page pill address opens actual page blur")
        XCTAssertTrue(app.closeField())
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.links["Open refresh page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == first.absoluteString })
        record(app.screenshot(), name: "Safari page pill Reload and Stop preserve actual Back")
    }

    func testSafariPageMenuReaderHintAndExitRestoreActualPage() throws {
        let article = server.url.appendingPathComponent("plate-article")
        let app = launch(url: article)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Reader fixture article"].waitForExistence(timeout: 15))
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(wait { menu.value as? String == "Reader available" }, "the real article never offered Reader")
        XCTAssertTrue(wait { self.savedURL() == article.absoluteString })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try XCTUnwrap(savedNavigation(id))
        page.buttons["Article page action"].tap()
        XCTAssertTrue(page.staticTexts["Article page action worked"].waitForExistence(timeout: 5))
        record(app.screenshot(), name: "Safari page pill actual Reader available hint")
        menu.tap()
        let reader = app.buttons["plate.menu.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 3))
        XCTAssertTrue(reader.isEnabled)
        XCTAssertEqual(reader.label, "Reader")
        reader.tap()
        XCTAssertTrue(wait { menu.value as? String == "Reader on" })
        XCTAssertTrue(page.staticTexts["Reader fixture article"].exists)
        XCTAssertFalse(page.buttons["Article page action"].exists, "Reader kept the original interactive page visible")
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedURL(), article.absoluteString)
        record(app.screenshot(), name: "Safari page menu actual Reader document")
        menu.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 3))
        XCTAssertEqual(reader.label, "Exit Reader")
        reader.tap()
        XCTAssertTrue(wait { menu.value as? String == "Reader available" })
        XCTAssertTrue(page.buttons["Article page action"].waitForExistence(timeout: 5))
        XCTAssertTrue(page.staticTexts["Article page action worked"].exists, "Reader exit replaced the original DOM state")
        page.buttons["Article page action"].tap()
        XCTAssertTrue(page.staticTexts["Article page action worked again"].waitForExistence(timeout: 5))
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedURL(), article.absoluteString)
        let after = try XCTUnwrap(savedNavigation(id))
        XCTAssertEqual(after.urls, before.urls)
        XCTAssertEqual(after.index, before.index)
        XCTAssertEqual(server.count(of: "/plate-article"), 1, "Reader must keep the same actual page, without another request")
        record(app.screenshot(), name: "Safari page menu Reader exit restores actual DOM and touch")
    }

    func testActualTopPullReloadsPageWithoutChangingTabOrHistory() throws {
        let first = server.url.appendingPathComponent("refresh-start")
        let second = URL(string: "refresh-page?q=a%2Bb#part", relativeTo: server.url)!.absoluteURL
        let app = launch(url: first)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.links["Open refresh page"].waitForExistence(timeout: 15))
        page.links["Open refresh page"].tap()
        XCTAssertTrue(page.staticTexts["Refresh request 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try XCTUnwrap(savedNavigation(id))
        record(app.screenshot(), name: "Pull to refresh before actual page gesture")
        let report = page.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page scroll ")).firstMatch
        func scrollY() -> Double { Double(report.label.replacingOccurrences(of: "Page scroll ", with: "")) ?? -1 }
        let settled = page.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Page settled ")).firstMatch
        func settledState() -> (generation: Int, y: Double)? {
            let parts = settled.label.split(separator: " ")
            guard parts.count == 4, let generation = Int(parts[2]), let y = Double(parts[3]) else { return nil }
            return (generation, y)
        }
        XCTAssertTrue(settled.waitForExistence(timeout: 5))
        let firstGeneration = try XCTUnwrap(settledState()).generation
        page.swipeUp()
        XCTAssertTrue(wait {
            guard let state = settledState() else { return false }
            return state.generation > firstGeneration && state.y > 250 && scrollY() > 250
        }, "the actual upward page scroll did not finish below the top")
        let downGeneration = try XCTUnwrap(settledState()).generation
        let screen = app.windows.firstMatch
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50)))
        XCTAssertTrue(wait {
            guard let state = settledState() else { return false }
            return state.generation > downGeneration && state.y > 20 && scrollY() > 20
        }, "the downward page scroll did not finish above the top")
        XCTAssertEqual(server.count(of: "/refresh-page"), 1, "a downward page scroll must not reload")
        page.buttons["Back to page top"].tap()
        XCTAssertTrue(page.staticTexts["Back to page top clicked 1"].waitForExistence(timeout: 5),
                      "the fixture did not receive the page button's click")
        XCTAssertTrue(wait { scrollY() == 0 }, "the fixture's window.scrollTo did not reach the actual document top")
        server.holdNextRefreshResponse()
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
            .press(forDuration: 0.1, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        XCTAssertTrue(wait { self.server.count(of: "/refresh-page") == 2 })
        record(app.screenshot(), name: "Pull to refresh actual native indicator while request is pending")
        server.releaseRefreshResponse()
        XCTAssertTrue(page.staticTexts["Refresh request 2"].waitForExistence(timeout: 10),
                      "the downward top pull did not replace the actual document")
        XCTAssertTrue(page.staticTexts["Refresh storage kept"].exists)
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString })
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        let after = try XCTUnwrap(savedNavigation(id))
        XCTAssertEqual(after.urls, before.urls)
        XCTAssertEqual(after.index, before.index)
        XCTAssertEqual(server.count(of: "/refresh-page"), 2)
        page.buttons["Page touch action"].tap()
        XCTAssertTrue(page.staticTexts["Page touch worked"].waitForExistence(timeout: 5),
                      "the page stopped accepting touches after refresh")
        XCTAssertTrue(app.buttons["chrome.plus"].exists, "the real New Tab control is available after refresh")
        record(app.screenshot(), name: "Pull to refresh actual reloaded page and working touch")
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.links["Open refresh page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == first.absoluteString })
        record(app.screenshot(), name: "Pull to refresh Back keeps original first page")
    }

    private func savedNavigation(_ id: String) -> (urls: [String], index: Int)? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let navigation = json["navigation"] as? [String: [String: Any]],
              let state = navigation[id], let entries = state["entries"] as? [[String: Any]],
              let index = state["index"] as? Int else { return nil }
        return (entries.compactMap { $0["url"] as? String }, index)
    }

    func testRealPageNavigationBackAndRelaunchKeepExactURL() throws {
        let first = server.url.appendingPathComponent("first")
        let second = URL(string: "second?q=a%2Bb&order=2%2F3#part", relativeTo: server.url)!.absoluteURL
        let app = launch(url: first)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["First real page"].waitForExistence(timeout: 30))
        let next = page.links["Go to second page"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(page.staticTexts["Second real page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString },
                      "expected \(second.absoluteString), saved \(savedURL() ?? "nil")")
        XCTAssertTrue(wait { self.savedTitle() == "Second real page" },
                      "expected the document title, saved \(savedTitle() ?? "nil")")
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["First real page"].waitForExistence(timeout: 10), "Back did not return to the actual first page")
        XCTAssertTrue(wait { self.savedURL() == first.absoluteString },
                      "expected \(first.absoluteString), saved \(savedURL() ?? "nil")")
        page.links["Go to second page"].tap()
        XCTAssertTrue(page.staticTexts["Second real page"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedURL() == second.absoluteString },
                      "expected \(second.absoluteString), saved \(savedURL() ?? "nil")")
        XCTAssertTrue(wait { self.savedTitle() == "Second real page" },
                      "expected the document title, saved \(savedTitle() ?? "nil")")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "real-browser-before-relaunch"
        before.lifetime = .keepAlways
        add(before)
        app.terminate()
        let restored = launch()
        XCTAssertTrue(restored.webViews.firstMatch.staticTexts["Second real page"].waitForExistence(timeout: 30), "normal launch did not restore the real page")
        XCTAssertEqual(savedURL(), second.absoluteString)
        XCTAssertTrue(wait { self.savedTitle() == "Second real page" },
                      "restored page title stayed \(savedTitle() ?? "nil")")
        let after = XCTAttachment(screenshot: restored.screenshot())
        after.name = "real-browser-after-relaunch"
        after.lifetime = .keepAlways
        add(after)
    }

    // MARK: - links from other apps (row 1176)

    /// A link another app opens in Yab, as iOS hands it over (openURLContexts):
    /// yab-open carries it in the simulator, where Yab can't be the default
    /// browser, down the same path http and https take.
    private func openFromAnotherApp(_ name: String) -> URL {
        let page = server.url.appendingPathComponent("outside-" + name)
        let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page.absoluteString
        XCUIDevice.shared.system.open(URL(string: "yab-open://" + encoded)!)
        return page
    }

    /// The page of the link is the one in front: drawn, in the plate, saved as the tab in front.
    private func checkLinkInFront(_ app: XCUIApplication, _ name: String, _ page: URL,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let shown = app.webViews.firstMatch.staticTexts["Outside " + name].waitForExistence(timeout: 20)
        record(app.screenshot(), name: "link from another app: " + name)
        XCTAssertTrue(shown, "Yab came to the front without the link's page (\(name))", file: file, line: line)
        XCTAssertTrue(wait { self.savedURL() == page.absoluteString },
                      "the tab in front is \(savedURL() ?? "nil"), not the link (\(name))", file: file, line: line)
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(wait { plate.exists && plate.isHittable }, "the page's plate is covered (\(name))", file: file, line: line)
    }

    func testLinkFromAnotherAppWhileYabIsInFront() throws {
        let app = launch(url: server.url.appendingPathComponent("first"))
        XCTAssertTrue(app.webViews.staticTexts["First real page"].waitForExistence(timeout: 15))
        checkLinkInFront(app, "front", openFromAnotherApp("front"))
    }

    func testLinkFromAnotherAppWhileYabIsAway() throws {
        let app = launch(url: server.url.appendingPathComponent("first"))
        XCTAssertTrue(app.webViews.staticTexts["First real page"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        checkLinkInFront(app, "away", openFromAnotherApp("away"))
        // Twice: the second link from the same app comes to a Yab that took one.
        XCUIDevice.shared.press(.home)
        checkLinkInFront(app, "again", openFromAnotherApp("again"))
    }

    func testLinkFromAnotherAppWhileAllTabsWasOpen() throws {
        let app = launch(url: server.url.appendingPathComponent("first"))
        XCTAssertTrue(app.webViews.staticTexts["First real page"].waitForExistence(timeout: 15))
        // A second tab, so the stack opens All Tabs.
        checkLinkInFront(app, "second", openFromAnotherApp("second"))
        let stack = app.buttons["chrome.plus"]
        XCTAssertTrue(wait { stack.exists && stack.isHittable })
        stack.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tabs.gallery"].firstMatch.waitForExistence(timeout: 5), "All Tabs didn't open")
        XCUIDevice.shared.press(.home)
        checkLinkInFront(app, "alltabs", openFromAnotherApp("alltabs"))
        XCTAssertFalse(app.descendants(matching: .any)["tabs.gallery"].firstMatch.exists, "All Tabs stayed over the page")
    }

    func testLinkFromAnotherAppWhileAChatWasOpen() throws {
        let app = launch(url: server.url.appendingPathComponent("first"))
        XCTAssertTrue(app.webViews.staticTexts["First real page"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.newChatFromPlus(), "no new chat")
        XCUIDevice.shared.press(.home)
        checkLinkInFront(app, "chat", openFromAnotherApp("chat"))
        XCTAssertFalse(app.textFields["chat.field"].isHittable, "the chat stayed over the page")
    }

    /// Yab not running: the link launches it (connectionOptions.urlContexts),
    /// with the same profile, as a person's Yab that iOS ended while away.
    func testLinkFromAnotherAppLaunchesYab() throws {
        let app = launch(url: server.url.appendingPathComponent("first"))
        XCTAssertTrue(app.webViews.staticTexts["First real page"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedURL() == self.server.url.appendingPathComponent("first").absoluteString })
        app.terminate()
        let page = openFromAnotherApp("cold")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "the link didn't launch Yab")
        // A system launch carries none of the test's arguments: the
        // simulator's own profile, whose first run may still ask.
        app.passWelcome(timeout: 3)
        app.closeField(timeout: 2)
        let shown = app.webViews.firstMatch.staticTexts["Outside cold"].waitForExistence(timeout: 30)
        record(app.screenshot(), name: "link from another app: cold launch")
        XCTAssertTrue(shown, "a link that launched Yab didn't open its page")
    }
}

private final class ProfileTestSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.profile-test-site")
    private var counts: [String: Int] = [:]
    private var holdsRefresh = false
    private var heldRefresh: [(connection: NWConnection, remainder: Data)] = []
    var ready: (() -> Void)?
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready?() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
                let route = path.components(separatedBy: "?").first ?? path
                self?.counts[route, default: 0] += 1
                let second = request.hasPrefix("GET /second")
                // /outside-<name>: a link another app opens in Yab, titled by its name.
                let outside = route.hasPrefix("/outside-") ? "Outside " + route.dropFirst("/outside-".count) : nil
                let title = outside ?? (second ? "Second real page" : "First real page")
                let link = second ? "" : "<a href='/second?q=a%2Bb&amp;order=2%2F3#part'>Go to second page</a>"
                var body = "<!doctype html><meta name='viewport' content='width=device-width'><title>\(title)</title><style>body{font:20px system-ui;padding:64px 20px}</style><h1 id='part'>\(title)</h1>\(link)"
                if route == "/plate-article" {
                    let paragraph = "A browser keeps the page and its address together while you read. This article explains how a clear interface lets a person move between an original page and a readable view, then return with the same position and useful controls. The page remains in its own tab with its own browsing history and storage. Its paragraphs contain ordinary prose rather than a navigation list or links, and they are long enough to represent a real article that can be read comfortably."
                    let prose = (1...16).map { "<p>Paragraph \($0). \(paragraph)</p>" }.joined()
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>Reader fixture article</title>
                    <style>body{font:20px system-ui;padding:64px 20px}button{padding:12px}article{max-width:36em}</style>
                    <button onclick="document.getElementById('action').textContent=(++window.clicks===1?'Article page action worked':'Article page action worked again')">Article page action</button><p id="action"></p>
                    <article><h1>Reader fixture article</h1>\(prose)</article><script>window.clicks=0</script>
                    """
                }
                if route == "/refresh-start" {
                    body = "<!doctype html><meta name=viewport content=width=device-width><link rel=icon href=data:,><title>Refresh first page</title><style>body{font:20px system-ui;padding:64px 20px}</style><a href='/refresh-page?q=a%2Bb#part'>Open refresh page</a><script>document.cookie='refresh-token=kept;path=/';localStorage.setItem('refresh-token','kept')</script>"
                }
                if route == "/refresh-page" {
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><title>Pull to refresh page</title>
                    <style>body{margin:0;min-height:5000px;font:20px system-ui;background:linear-gradient(#cfefff,#fff)}h1,p{margin:20px}
                    #scroll{position:fixed;top:40%;left:20px}#settled{position:fixed;top:45%;left:20px}#clicked{position:fixed;top:50%;left:20px}nav{position:fixed;left:20px;bottom:180px}button{display:block;margin:8px;padding:12px}</style>
                    <h1 id="part">Refresh request \(self?.counts[route, default: 0] ?? 0)</h1><p id="storage"></p><p id="result"></p><output id="scroll">Page scroll 0</output><output id="settled">Page settled 0 0</output><output id="clicked">Back to page top clicked 0</output>
                    <nav><button onclick="document.getElementById('clicked').textContent='Back to page top clicked '+(++window.topClicks);window.scrollTo(0,0)">Back to page top</button><button onclick="document.getElementById('result').textContent='Page touch worked'">Page touch action</button></nav>
                    <script>window.topClicks=0;let scrollEnds=0;document.getElementById('storage').textContent='Refresh storage '+(localStorage.getItem('refresh-token')==='kept'&&document.cookie.includes('refresh-token=kept')?'kept':'missing');
                    function report(){document.getElementById('scroll').textContent='Page scroll '+window.scrollY.toFixed(0)}addEventListener('scroll',report);addEventListener('load',report);
                    document.addEventListener('scrollend',()=>{report();document.getElementById('settled').textContent='Page settled '+(++scrollEnds)+' '+window.scrollY.toFixed(0)});</script>
                    """
                }
                if request.hasPrefix("GET /hold-") {
                    let cold = request.hasPrefix("GET /hold-cold")
                    let colors = cold ? "#16af50 50%,#285bd9 50%" : "#00aade 50%,#ed7000 50%"
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,">
                    <title>\(cold ? "Cold held page" : "Current browser page")</title>
                    <style>body{margin:0;min-height:200vh;font:20px system-ui;background:linear-gradient(90deg,\(colors))}
                    h1{margin:16px;font-size:22px}button{margin:24px;padding:16px}#result{margin:24px}</style>
                    <h1>\(cold ? "Cold held page" : "Current browser page")</h1>
                    \(cold ? "" : "<button onclick=\"document.getElementById('result').textContent='Current page action worked'\">Current page action</button><p id='result'></p>")
                    """
                }
                if request.hasPrefix("GET /field-backdrop") {
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Address blur check</title>
                    <style>body{margin:0;height:200vh;font:20px system-ui;background:linear-gradient(90deg,#00aade 50%,#ed7000 50%)}
                    .detail{position:absolute;top:130px;left:0;right:0;height:80px;background:repeating-linear-gradient(90deg,transparent 0 5px,#fff 5px 10px)}
                    button{position:relative;margin:24px;padding:16px}#result{margin:24px}</style>
                    <button onclick="document.getElementById('result').textContent='Page action worked'">Page action</button>
                    <div class="detail"></div><p id="result"></p>
                    """
                }
                if request.hasPrefix("GET /identity-") {
                    let seed = request.hasPrefix("GET /identity-seed")
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width"><title>Profile storage</title>
                    <style>body{font:20px system-ui;padding:64px 20px}</style>
                    <h1>\(seed ? "Profile seeded" : "Profile storage check")</h1>
                    <p id="cookie"></p><p id="local"></p><a href="/identity-check">Check profile storage</a>
                    <script>
                    \(seed ? "document.cookie='profile-token=kept;max-age=86400;path=/';localStorage.setItem('profile-token','kept');" : "")
                    document.getElementById('cookie').textContent='Profile cookie '+(document.cookie.split(';').some(x=>x.trim()==='profile-token=kept')?'kept':'missing');
                    document.getElementById('local').textContent='Profile local '+(localStorage.getItem('profile-token')==='kept'?'kept':'missing');
                    </script>
                    """
                }
                if request.hasPrefix("GET /viewport-") {
                    let fit = request.hasPrefix("GET /viewport-cover") ? ",viewport-fit=cover" : ""
                    body = """
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1\(fit)">
                    <title>Viewport test</title><link rel="icon" href="data:,">
                    <style>
                    body{margin:0;min-height:3000px;font:20px system-ui;background:linear-gradient(#fff,#def)}
                    header,footer{position:fixed;left:env(safe-area-inset-left);right:env(safe-area-inset-right);height:40px;display:flex;align-items:center;justify-content:center;background:#cef}
                    header{top:env(safe-area-inset-top)}footer{bottom:env(safe-area-inset-bottom)}
                    #probe{position:absolute;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom);padding-left:env(safe-area-inset-left);padding-right:env(safe-area-inset-right)}
                    #report{position:fixed;top:45%;left:16px;right:16px;font-size:14px}
                    </style><header>Viewport header</header><footer>Viewport footer</footer>
                    <div id="probe"></div><output id="report"></output>
                    <script>
                    function report(){const p=getComputedStyle(document.getElementById('probe'));
                    document.getElementById('report').textContent='Viewport CSS top='+parseFloat(p.paddingTop)+' bottom='+parseFloat(p.paddingBottom)+' left='+parseFloat(p.paddingLeft)+' right='+parseFloat(p.paddingRight)+' height='+visualViewport.height.toFixed(1)+' scroll='+scrollY.toFixed(1);}
                    addEventListener('load',report);addEventListener('resize',report);addEventListener('scroll',report);
                    visualViewport.addEventListener('resize',report);visualViewport.addEventListener('scroll',report);
                    </script>
                    """
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                let bytes = Data(response.utf8)
                if route == "/refresh-page", self?.holdsRefresh == true {
                    self?.holdsRefresh = false
                    self?.heldRefresh.append((connection, Data(bytes.suffix(1))))
                    connection.send(content: Data(bytes.dropLast()), completion: .contentProcessed { _ in })
                } else {
                    connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
    }

    func count(of route: String) -> Int { queue.sync { counts[route, default: 0] } }
    func holdNextRefreshResponse() { queue.sync { holdsRefresh = true } }
    func releaseRefreshResponse() {
        queue.sync {
            for response in heldRefresh {
                response.connection.send(content: response.remainder, completion: .contentProcessed { _ in response.connection.cancel() })
            }
            heldRefresh = []
        }
    }
    func stop() {
        listener.cancel()
        queue.sync { heldRefresh.forEach { $0.connection.cancel() }; heldRefresh = [] }
    }
}
