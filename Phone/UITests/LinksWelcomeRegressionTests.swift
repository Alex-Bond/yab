import XCTest

final class LinksWelcomeRegressionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func save(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            activity.add(shot)
            try? app.screenshot().pngRepresentation.write(to: Atlas.out.appendingPathComponent(name + ".png"))
            try? app.debugDescription.write(to: Atlas.out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
    }

    func testContinueFromPrivateLandsOnHomeWithoutKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "empty", "-YabState", "welcome.15", "-YabNoAnim", "NO"]
        app.launch()
        let next = app.buttons["welcome.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        save(app, "Private before Continue")
        next.tap()
        // The default-browser page is optional. Skip completes that page.
        let skip = app.buttons["welcome.skip"]
        if app.buttons["welcome.makeDefault"].waitForExistence(timeout: 2) { skip.tap() }
        XCTAssertTrue(TransitionCatalog.wait(10) { !app.descendants(matching: .any)["welcome"].exists })
        save(app, "Continue settled")
        XCTAssertFalse(app.textFields["field.input"].exists, "Continue must not open search")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Continue must not summon the keyboard")
        XCTAssertTrue(app.descendants(matching: .any)["empty.home"].exists)
        app.terminate()
    }

    func testFirstExternalLinkFromBackgroundShowsRequestedPage() throws {
        try externalLink(suspended: false)
    }

    func testFirstExternalLinkFromSuspensionShowsRequestedPage() throws {
        try externalLink(suspended: true)
    }

    func testFirstExternalLinkFromBackgroundInPrivateShowsRequestedPage() throws {
        try externalLink(suspended: false, privately: true)
    }

    func testFirstExternalLinkAfterPageProcessesEndShowsRequestedPage() throws {
        try externalLink(suspended: false, killedPages: true, warmTarget: true)
    }

    func testFirstExternalLinkAfterLongAbsenceShowsRequestedPage() throws {
        try externalLink(suspended: false, longAway: true)
    }

    func testFirstExternalLinkAfterLongSuspensionAndStoppedPagesShowsRequestedPage() throws {
        try externalLink(suspended: true, killedPages: true, longAway: true, warmTarget: true)
    }

    func testPlainReturnKeepsLastPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabNoAnim", "NO", "-YabLaunchKeyboard", "YES"]
        app.launch()
        // Launch may open the field; put it away before leaving a page.
        XCTAssertTrue(app.closeField(timeout: 5))
        let plate = app.descendants(matching: .any)["chrome.plate"]
        XCTAssertTrue(plate.waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["Onboarding v3"].waitForExistence(timeout: 20))
        let previous = plate.label
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(TransitionCatalog.wait { app.state == .runningBackground || app.state == .runningBackgroundSuspended })
        app.activate()
        XCTAssertTrue(TransitionCatalog.wait(20) { plate.exists && plate.label == previous })
        XCTAssertFalse(app.textFields["field.input"].exists)
        XCTAssertTrue(app.webViews.staticTexts["Onboarding v3"].waitForExistence(timeout: 20))
        save(app, "Plain return")
        app.terminate()
    }

    private func externalLink(suspended: Bool, privately: Bool = false, killedPages: Bool = false, longAway: Bool = false, warmTarget: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", privately ? "external-link-private" : "mira", "-YabNoAnim", "NO"]
        let scenario = "private-\(privately)-stop-\(suspended)-kill-\(killedPages)-long-\(longAway)"
        app.launchEnvironment["YAB_LINK_JOURNAL"] = Atlas.out.appendingPathComponent(scenario + ".log").path
        if killedPages { app.launchArguments += ["-YabTestEndPagesAway", "YES"] }
        if longAway { app.launchArguments += ["-YabLaunchKeyboard", "YES", "-YabTestAwaySeconds", "172800"] }
        app.launch()
        XCTAssertTrue(app.closeField())
        XCTAssertTrue(app.descendants(matching: .any)["chrome.plate"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["Onboarding v3"].waitForExistence(timeout: 20))
        if warmTarget {
            XCUIDevice.shared.system.open(URL(string: "yab-open://https%3A%2F%2Flumen.events%2Fe%2Fdesign-systems-night")!)
            XCTAssertTrue(app.webViews.staticTexts["Design Systems Night"].waitForExistence(timeout: 20))
            XCUIDevice.shared.system.open(URL(string: "yab-open://https%3A%2F%2Ffigma.com%2Fdesign%2FxK29fLm8%2FOnboarding-v3")!)
            XCTAssertTrue(app.webViews.staticTexts["Onboarding v3"].waitForExistence(timeout: 20))
        }
        let pid = try ExternalLinkSuspension.pid(of: app)
        save(app, "Original page " + scenario)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(TransitionCatalog.wait { app.state == .runningBackground || app.state == .runningBackgroundSuspended })
        if suspended {
            // This simulator did not naturally suspend under XCTest. The host
            // verifies a real SIGSTOP, then resumes this same process after the
            // SpringBoard URL request has begun. This never terminates the app.
            try ExternalLinkSuspension.stop(pid: pid)
        }
        // XCTest delivers through SpringBoard on the device hosting this test.
        XCUIDevice.shared.system.open(URL(string: "yab-open://https%3A%2F%2Flumen.events%2Fe%2Fdesign-systems-night")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        if suspended { XCTAssertEqual(try ExternalLinkSuspension.pid(of: app), pid, "the suspended process must resume, not cold-launch") }
        let plate = app.descendants(matching: .any)["chrome.plate"]
        let requested = TransitionCatalog.wait(30) { plate.exists && plate.label.contains("Lumen") }
        save(app, "Returned " + scenario)
        XCTAssertTrue(requested, plate.label)
        XCTAssertTrue(app.webViews.staticTexts["Design Systems Night"].waitForExistence(timeout: 20), "the requested page content must load, not only its address")
        save(app, privately ? "First link in Private" : suspended ? "First link from suspension" : "First link from background")
        XCTAssertFalse(app.textFields["field.input"].exists)
        app.terminate()
    }
}

/// Stops only the simulator app whose PID XCTest captured before going Home.
enum ExternalLinkSuspension {
    static func pid(of app: XCUIApplication) throws -> Int {
        let expression = try NSRegularExpression(pattern: "pid: ([0-9]+)")
        let description = app.debugDescription
        let match = try XCTUnwrap(expression.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)))
        return try XCTUnwrap(Int((description as NSString).substring(with: match.range(at: 1))))
    }

    static func stop(pid: Int) throws {
        let request = Atlas.out.appendingPathComponent("link-probe-request.json")
        let response = Atlas.out.appendingPathComponent("link-probe-response.json")
        try? FileManager.default.removeItem(at: response)
        let payload: [String: Any] = ["pid": pid, "device": try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])]
        try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
        XCTAssertTrue(TransitionCatalog.wait(30) { FileManager.default.fileExists(atPath: response.path) }, "suspension helper did not answer")
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any])
        XCTAssertEqual(proof["stopped"] as? Bool, true, String(describing: proof))
        XCTAssertEqual(proof["pid"] as? Int, pid)
    }
}
