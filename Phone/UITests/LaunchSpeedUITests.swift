import XCTest
import UIKit

/// #1776: a real saved profile, without network, sync credentials or fixture worlds.
/// A simulator models screen/runtime compatibility, not A13 CPU performance.
final class LaunchSpeedUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSavedTabsColdAndWarmStartPage() throws {
        // Both the runner and browser use this owned simulator-host fixture,
        // following LiveProfileTests rather than another app's sandbox.
        let folder = URL(fileURLWithPath: "/private/tmp/yab-launch-speed-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icons = folder.appendingPathComponent("SiteIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let tabs: [[String: Any]] = (0..<2000).map { i in
            ["id": "saved-\(i)", "title": "Saved page \(i)", "site": "Example", "icon": "globe",
             "url": "https://saved-\(i).invalid/page", "host": "saved-\(i).invalid"]
        }
        for i in 0..<2000 {
            let origin = "https://saved-\(i).invalid"
            try png.write(to: icons.appendingPathComponent(origin.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        }
        let snapshot: [String: Any] = ["version": 1, "spaceID": "saved", "navigation": [:], "visits": [],
            "spaces": [["id": "saved", "name": "Saved", "emoji": "", "tint": [238, 233, 226],
                        "pins": [], "kept": [], "today": tabs]]]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: folder.appendingPathComponent("profile.json"))
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabLaunchKeyboard", "YES",
                               "-settings.welcomed", "YES", "-settings.withoutMac", "YES"]
        for iteration in 0..<5 {
            app.terminate()
            let stalls = folder.appendingPathComponent("stalls-\(iteration).jsonl")
            app.launchEnvironment = ["YAB_STALLS_OUT": stalls.path, "YAB_HAPTICS_SILENT": "1"]
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            let field = app.textFields["field.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 30))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(app.descendants(matching: .any)["newtab.tab.saved-0"].waitForExistence(timeout: 10),
                          "the browser must restore the seeded profile, not an empty fallback")
            field.typeText("launchprobe")
            XCTAssertEqual(field.value as? String, "launchprobe", "the start page must accept input")
            print("launch speed kind=\(iteration == 0 ? "first-process" : "cached-process") iteration=\(iteration) usable_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
            if iteration == 0 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Saved tabs start page"
                shot.lifetime = .keepAlways
                add(shot)
            }
            XCUIDevice.shared.press(.home)
            let warmStart = ProcessInfo.processInfo.systemUptime
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.typeText("warm")
            XCTAssertTrue((field.value as? String)?.hasSuffix("warm") == true)
            print("launch speed kind=resume iteration=\(iteration) usable_ms=\((ProcessInfo.processInfo.systemUptime - warmStart) * 1000)")
            let trace = try String(contentsOf: stalls, encoding: .utf8)
            for line in trace.split(separator: "\n") { print("launch stall iteration=\(iteration) \(line)") }
            let attachment = XCTAttachment(string: trace)
            attachment.name = "Launch and resume stalls \(iteration)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // XCTest's native responsive-launch metric separates app launch from
        // the automation and text-entry overhead in the end-to-end samples.
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.terminate()
            app.launch()
        }
    }
}
