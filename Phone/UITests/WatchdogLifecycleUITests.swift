import XCTest

/// Simulator coverage of real scene transitions with a durable, populated ledger.
/// These timings do not stand in for physical-device watchdog validation.
final class WatchdogLifecycleUITests: XCTestCase {
    func testThousandTabsBackgroundReturnAndExit() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Watchdog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: folder) }
        let identity = UUID().uuidString
        let tabs: [[String: Any]] = (0..<1000).map {
            ["id": "watchdog-\($0)", "title": "Owned tab \($0)", "site": "Owned", "icon": "globe", "url": "about:blank"]
        }
        func write(_ object: Any, _ name: String) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        try write(["version": 1, "dataStoreID": identity], "website-data-store.json")
        try write(["version": 1, "spaceID": "watchdog", "navigation": [:], "visits": [], "spaces": [
            ["id": "watchdog", "name": "Watchdog", "tint": [238,233,226], "today": tabs, "current": "watchdog-0"]
        ]], "profile.json")
        let clock: [String: Any] = ["date": Date().timeIntervalSinceReferenceDate, "uptime": ProcessInfo.processInfo.systemUptime]
        let entries = Dictionary(uniqueKeysWithValues: tabs.map {
            ($0["id"] as! String, ["space": "watchdog", "address": "about:blank", "last": clock, "localOnly": true] as [String: Any])
        })
        try write(["version": 1, "profile": identity, "entries": entries], "tab-activity.json")
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-settings.welcomed", "YES", "-settings.autoClearToday", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["chrome.plate"].waitForExistence(timeout: 30))
        var timings: [[String: Any]] = []
        for cycle in 1...3 {
            let start = ProcessInfo.processInfo.systemUptime
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
            let background = ProcessInfo.processInfo.systemUptime - start
            XCTAssertLessThan(background, 10, "scene transition exceeded historical 10-second limit")
            // A real ledger write must complete, including revocation on reload.
            let saved = expectation(description: "background ledger flushed")
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let data = try Data(contentsOf: folder.appendingPathComponent("tab-activity.json"))
                let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let activities = try XCTUnwrap(file["entries"] as? [String: [String: Any]])
                if activities.count == 1000 && activities.values.allSatisfy({ $0["localOnly"] as? Bool == false }) {
                    saved.fulfill(); break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            wait(for: [saved], timeout: 0.1)
            let foregroundStart = ProcessInfo.processInfo.systemUptime
            app.activate()
            XCTAssertTrue(app.buttons["chrome.plate"].waitForExistence(timeout: 8))
            let foreground = ProcessInfo.processInfo.systemUptime - foregroundStart
            XCTAssertLessThan(foreground, 10)
            let exitStart = ProcessInfo.processInfo.systemUptime
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            let exit = ProcessInfo.processInfo.systemUptime - exitStart
            XCTAssertLessThan(exit, 5, "termination request exceeded historical 5-second limit")
            timings.append(["cycle": cycle, "tabs": 1000, "backgroundSeconds": background, "foregroundSeconds": foreground, "terminationSeconds": exit])
            if cycle < 3 { app.launch(); XCTAssertTrue(app.buttons["chrome.plate"].waitForExistence(timeout: 30)) }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "watchdog-lifecycle-timings"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
