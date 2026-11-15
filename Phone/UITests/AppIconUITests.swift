import Network
import XCTest

/// Actual UIKit icon requests in the farm's owned simulator. No fake icon
/// preference or overridden completion handler is used by these journeys.
final class AppIconUITests: XCTestCase {
    private var folder: URL!
    private var site: PageControlsSite!
    private var hapticsJournal: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp/yab-app-icon-\(UUID().uuidString)", isDirectory: true)
        site = try PageControlsSite()
        let ready = expectation(description: "owned real icon page")
        site.ready = { ready.fulfill() }; site.start()
        wait(for: [ready], timeout: 10)
        try restoreKnownInterruptedNativeIcon()
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate(); site.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testRealIconSelectionAndRelaunchKeepTheBrowserAndNativeState() throws {
        let app = try launch()
        let before = try profileIdentity()
        openIcons(app)
        let title = app.staticTexts["settings.appIcon.preview.title"]
        let use = app.buttons["settings.appIcon.use"]
        XCTAssertEqual(title.label, "Flat", "A new farm installation must begin with its primary icon, Flat")
        XCTAssertEqual(use.label, "In Use", "the icon in use says so at once")
        XCTAssertFalse(use.isEnabled)
        let next = app.buttons["settings.appIcon.next"]
        assertControl(app, next); next.tap()
        XCTAssertTrue(wait { title.label == "Default" && use.label == "Use This Icon" })
        XCTAssertEqual(element(app, "settings.appIcon.note").label, "Follows Dark, Tinted and Clear")
        record(app, "Mac artwork preview before actual native icon request")
        assertControl(app, use); XCTAssertTrue(use.isEnabled); use.tap()
        dismissIconNoticeIfPresent(app)
        XCTAssertTrue(wait { use.label == "In Use" && !use.isEnabled })
        XCTAssertFalse(app.staticTexts["settings.appIcon.error"].exists)
        record(app, "Actual YabOriginal alternate confirms Default")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { app.buttons["settings.row.appIcon"].label.contains("Default") }, "the root row says the new icon")
        app.terminate()
        let reopened = try launch(initial: false)
        XCTAssertEqual(try profileIdentity(), before)
        openIcons(reopened)
        XCTAssertEqual(reopened.staticTexts["settings.appIcon.preview.title"].label, "Default")
        XCTAssertEqual(reopened.buttons["settings.appIcon.use"].label, "In Use")
        record(reopened, "Relaunch reads the actual native icon instead of a saved app preference")
        let previous = reopened.buttons["settings.appIcon.previous"]
        assertControl(reopened, previous); previous.tap()
        XCTAssertTrue(wait { reopened.staticTexts["settings.appIcon.preview.title"].label == "Flat" })
        let restore = reopened.buttons["settings.appIcon.use"]
        XCTAssertEqual(restore.label, "Use This Icon", "browsing has no system effect")
        assertControl(reopened, restore); restore.tap(); dismissIconNoticeIfPresent(reopened)
        XCTAssertTrue(wait { restore.label == "In Use" && !restore.isEnabled })
        closeSettings(reopened)
        XCTAssertTrue(wait { !element(reopened, "settings.sheet").exists && reopened.buttons["Page action"].isHittable })
        reopened.buttons["Page action"].tap()
        XCTAssertTrue(reopened.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(try profileIdentity(), before)
        record(reopened, "Flat restored and original browser still accepts touch")
    }

    func testRealPumpkinSelectionAndLockedReferralArtworkKeepTheBrowserUsable() throws {
        var last = DateComponents()
        last.year = 2026; last.month = 11; last.day = 3
        let end = try XCTUnwrap(Calendar.current.date(from: last))
        guard Date() < end else { throw XCTSkip("The unearned Halloween gallery has left for this season.") }
        let app = try launch()
        let before = try profileIdentity()
        openIcons(app)
        defer { restoreFlat(app) }
        let title = app.staticTexts["settings.appIcon.preview.title"]
        let use = app.buttons["settings.appIcon.use"]
        XCTAssertEqual(title.label, "Flat")
        for expected in ["Default", "Watercolor Glass", "Opal", "Pumpkin"] {
            let next = app.buttons["settings.appIcon.next"]
            assertControl(app, next); next.tap()
            XCTAssertTrue(wait { title.label == expected }, "unearned post rewards stay out of the gallery")
        }
        XCTAssertEqual(use.label, "Use This Icon")
        assertControl(app, use); use.tap(); dismissIconNoticeIfPresent(app)
        XCTAssertTrue(wait { use.label == "In Use" && !use.isEnabled })
        XCTAssertFalse(app.staticTexts["settings.appIcon.error"].exists)
        record(app, "Actual native Pumpkin alternate accepted")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { app.buttons["settings.row.appIcon"].label.contains("Pumpkin") })
        app.buttons["settings.row.appIcon"].tap()
        awaitIconPage(app)
        XCTAssertTrue(wait { title.label == "Pumpkin" && use.label == "In Use" })

        for expected in ["Ghost", "Mummy", "Witch", "Wax Seal"] {
            let next = app.buttons["settings.appIcon.next"]
            assertControl(app, next); next.tap()
            XCTAssertTrue(wait { title.label == expected })
        }
        XCTAssertTrue(element(app, "settings.appIcon.locked").exists)
        XCTAssertEqual(use.label, "Locked")
        XCTAssertFalse(use.isEnabled, "browsing referral artwork cannot choose an unearned icon")
        record(app, "Unearned Wax Seal preview stays locked after a real native choice")

        restoreFlat(app)
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && app.buttons["Page action"].isHittable })
        app.buttons["Page action"].tap()
        XCTAssertTrue(app.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(try profileIdentity(), before)
        record(app, "Native Flat restored after Pumpkin and locked referral browsing")
    }

    func testLargestNativeTypeKeepsFullIconNamesAndActual44PointControls() throws {
        let app = try launch(large: true)
        let before = try profileIdentity()
        openIcons(app)
        let title = app.staticTexts["settings.appIcon.preview.title"]
        let current = title.label
        let next = app.buttons["settings.appIcon.next"]
        assertControl(app, next); next.tap()
        XCTAssertTrue(wait { title.label == "Default" })
        reveal(app, next); assertControl(app, next); next.tap()
        XCTAssertTrue(wait { title.label == "Watercolor Glass" })
        let use = app.buttons["settings.appIcon.use"]
        assertControl(app, use)
        XCTAssertEqual(use.label, "Use This Icon")
        record(app, "Largest native type: complete artwork title and 44-point controls")
        let previous = app.buttons["settings.appIcon.previous"]
        reveal(app, previous); assertControl(app, previous); previous.tap()
        XCTAssertTrue(wait { title.label == "Default" })
        // A genuine horizontal finger gesture changes only the preview.
        let gallery = element(app, "settings.appIcon.gallery")
        reveal(app, gallery)
        let frame = gallery.frame
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame))
        let window = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        window.withOffset(CGVector(dx: frame.midX + 30, dy: frame.midY))
            .press(forDuration: 0.05, thenDragTo: window.withOffset(CGVector(dx: frame.midX - 90, dy: frame.midY)))
        XCTAssertTrue(wait { title.label != "Default" })
        XCTAssertEqual(try profileIdentity(), before)
        record(app, "Actual Cover Flow swipe previews without changing the native icon")
        // Back to the icon in use: it says In Use, nothing was asked of iOS.
        for _ in 0..<7 where title.label != current {
            let back = app.buttons["settings.appIcon.previous"]
            guard back.exists else { break }
            reveal(app, back); back.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(wait { title.label == current && use.label == "In Use" })
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && app.buttons["Page action"].isHittable })
        app.buttons["Page action"].tap()
        XCTAssertTrue(app.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
    }

    func testActualNativeIconChoicesTickOnceAndRelaunchRestorationStaysQuiet() throws {
        let app = try launch()
        let before = try profileIdentity()
        openIcons(app)
        XCTAssertEqual(try iconHaptics(), [])
        let title = app.staticTexts["settings.appIcon.preview.title"]
        XCTAssertEqual(title.label, "Flat")
        let next = app.buttons["settings.appIcon.next"]
        assertControl(app, next); next.tap()
        XCTAssertTrue(wait { title.label == "Default" })
        XCTAssertEqual(try iconHaptics(), ["selection icon preview"])
        assertControl(app, next); next.tap()
        XCTAssertTrue(wait { title.label == "Watercolor Glass" })
        XCTAssertEqual(element(app, "settings.appIcon.note").label, "Dark and Tinted are made by iOS")
        XCTAssertEqual(try iconHaptics(), ["selection icon preview", "selection icon preview"])
        let previous = app.buttons["settings.appIcon.previous"]
        assertControl(app, previous); previous.tap()
        XCTAssertTrue(wait { title.label == "Default" })
        XCTAssertEqual(try iconHaptics(), Array(repeating: "selection icon preview", count: 3))
        let use = app.buttons["settings.appIcon.use"]
        assertControl(app, use); use.tap(); dismissIconNoticeIfPresent(app)
        XCTAssertTrue(wait { use.label == "In Use" && !use.isEnabled })
        XCTAssertEqual(try iconHaptics(), Array(repeating: "selection icon preview", count: 3) + ["light icon use"])
        XCTAssertFalse(app.staticTexts["settings.appIcon.error"].exists)
        record(app, "Actual Mac choice marks and one accepted native icon haptic")
        app.terminate()
        let restored = try launch(initial: false)
        openIcons(restored)
        XCTAssertEqual(restored.staticTexts["settings.appIcon.preview.title"].label, "Default")
        XCTAssertEqual(restored.buttons["settings.appIcon.use"].label, "In Use")
        XCTAssertEqual(try iconHaptics(), [], "Opening and restoring the actual native icon must not play selection feedback")
        let back = restored.buttons["settings.appIcon.previous"]
        assertControl(restored, back); back.tap()
        XCTAssertTrue(wait { restored.staticTexts["settings.appIcon.preview.title"].label == "Flat" })
        let restore = restored.buttons["settings.appIcon.use"]
        assertControl(restored, restore); restore.tap(); dismissIconNoticeIfPresent(restored)
        XCTAssertTrue(wait { restore.label == "In Use" && !restore.isEnabled })
        XCTAssertEqual(try iconHaptics(), ["selection icon preview", "light icon use"])
        closeSettings(restored)
        XCTAssertTrue(wait { !element(restored, "settings.sheet").exists && restored.buttons["Page action"].isHittable })
        restored.buttons["Page action"].tap()
        XCTAssertTrue(restored.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(try profileIdentity(), before)
        record(restored, "Native icon restoration and browser identity after quiet relaunch")
    }

    /// One head in light and dark: × on the left at the root, ‹ in the same
    /// spot on Appearance and on App Icon (whose head says its name), and ×
    /// leaves the page behind with nothing reopened.
    func testOneHeadBackAndCloseAcrossLightAndDark() throws {
        let app = try launch()
        let before = try profileIdentity()
        var initialAppearance = "system"
        for (index, appearance) in ["light", "dark"].enumerated() {
            openSettings(app)
            XCTAssertTrue(wait { app.buttons["settings.row.appearance"].isHittable }); app.buttons["settings.row.appearance"].tap()
            let choice = app.buttons["settings.choice.appearance." + appearance]
            XCTAssertTrue(wait { choice.isHittable })
            if index == 0 {
                initialAppearance = try XCTUnwrap(["system", "light", "dark"].first {
                    app.buttons["settings.choice.appearance." + $0].isSelected
                })
            }
            XCTAssertFalse(app.buttons["settings.row.appearance.appIcon"].exists, "App Icon left Appearance")
            choice.tap(); XCTAssertTrue(wait { choice.isSelected })
            app.buttons["settings.back"].tap()
            let close = app.buttons["settings.close"]
            XCTAssertTrue(wait { close.isHittable && !app.buttons["settings.back"].exists })
            assertControl(app, close); XCTAssertEqual(app.buttons.matching(identifier: "settings.close").count, 1)
            XCTAssertEqual(close.frame.minX, 12, accuracy: 1)
            XCTAssertEqual(element(app, "settings.title").label, "Settings")
            record(app, "One head, " + appearance + ": × on the left, Settings in the middle")
            let row = app.buttons["settings.row.appIcon"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); reveal(app, row); row.tap()
            let back = app.buttons["settings.back"]
            XCTAssertTrue(wait { app.buttons["settings.appIcon.use"].exists && back.isHittable && !close.exists })
            assertControl(app, back); XCTAssertEqual(app.buttons.matching(identifier: "settings.back").count, 1)
            XCTAssertEqual(back.frame.minX, 12, accuracy: 1)
            XCTAssertEqual(element(app, "settings.title").label, "App Icon")
            record(app, "One head, " + appearance + ": ‹ App Icon")
            back.tap()
            XCTAssertTrue(wait { close.isHittable && row.isHittable })
            close.tap()
            XCTAssertTrue(wait { !element(app, "settings.sheet").exists && app.buttons["Page action"].isHittable })
            XCTAssertFalse(element(app, "newtab.spaces").exists, "closing Settings reopens nothing")
            XCTAssertEqual(try profileIdentity(), before)
        }
        // Restore the actual starting appearance through the existing preference action.
        openSettings(app)
        app.buttons["settings.row.appearance"].tap()
        let original = app.buttons["settings.choice.appearance." + initialAppearance]
        XCTAssertTrue(wait { original.isHittable }); original.tap(); XCTAssertTrue(wait { original.isSelected })
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && app.buttons["Page action"].isHittable })
        app.buttons["Page action"].tap()
        XCTAssertTrue(app.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(try profileIdentity(), before)
        XCTAssertEqual(try iconHaptics(), [], "Navigation, appearance, and native readback never request an icon or play icon feedback")
        record(app, "Original appearance and actual browser after Back and Close")
    }

    /// Repair only the known Default or Pumpkin icon left by our interrupted owned-Simulator
    /// journey. Use the same real picker/callback as a person; never edit preferences.
    private func restoreKnownInterruptedNativeIcon() throws {
        let app = try launch()
        defer { app.terminate() }
        let before = try profileIdentity()
        openIcons(app)
        let title = app.staticTexts["settings.appIcon.preview.title"]
        let name = title.label
        guard ["Flat", "Default", "Pumpkin"].contains(name) else {
            XCTFail("Owned fixture refuses an unexpected native icon; only its known Default or Pumpkin may be restored")
            throw NSError(domain: "OwnedAppIconFixture", code: 1)
        }
        XCTAssertEqual(try iconHaptics(), [], "Fixture arrival reads the actual native icon without requesting a change")
        if name != "Flat" {
            record(app, "Owned fixture: known interrupted \(name) before native Flat restoration")
            restoreFlat(app)
            XCTAssertFalse(app.staticTexts["settings.appIcon.error"].exists)
            let previews = name == "Default" ? 1 : 4
            XCTAssertEqual(try iconHaptics(), Array(repeating: "selection icon preview", count: previews) + ["light icon use"])
            record(app, "Owned fixture: real native Flat callback completed before the original journey")
        }
        XCTAssertEqual(title.label, "Flat")
        XCTAssertEqual(app.buttons["settings.appIcon.use"].label, "In Use")
        XCTAssertEqual(try profileIdentity(), before)
    }

    /// Restore through the same real controls even after a failed assertion
    /// in the seasonal journey; no simulator preferences are changed by hand.
    private func restoreFlat(_ app: XCUIApplication) {
        let title = app.staticTexts["settings.appIcon.preview.title"]
        guard title.exists else { return }
        for _ in 0..<20 where title.label != "Flat" {
            let previous = app.buttons["settings.appIcon.previous"]
            guard previous.exists else { break }
            let before = title.label
            reveal(app, previous); assertControl(app, previous); previous.tap()
            XCTAssertTrue(wait { title.label != before })
        }
        XCTAssertEqual(title.label, "Flat")
        let use = app.buttons["settings.appIcon.use"]
        if use.label != "In Use" {
            reveal(app, use); assertControl(app, use); XCTAssertTrue(use.isEnabled); use.tap()
            dismissIconNoticeIfPresent(app)
        }
        XCTAssertTrue(wait { use.label == "In Use" && !use.isEnabled })
    }

    private func iconHaptics() throws -> [String] {
        let path = try XCTUnwrap(hapticsJournal)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[2] == "icon preview" || parts[2] == "icon use" else { return nil }
            return String(parts[1]) + " " + String(parts[2])
        }
    }

    private func launch(initial: Bool = true, large: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        // Journal.shared is lazy. A quiet new process must not read its predecessor's file.
        let journal = folder.appendingPathComponent("app-icon-haptics-\(UUID().uuidString).log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        hapticsJournal = journal
        app.launchEnvironment = ["YAB_TEST":"1", "YAB_HAPTICS_SILENT":"1",
                                 "YAB_HAPTICS_JOURNAL": journal.path]
        app.launchArguments = ["-YabProfileDirectory", folder.path]
            + (initial ? ["-YabURL", site.url("/article").absoluteString] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.terminate(); app.launch()
        XCTAssertTrue(wait { app.staticTexts["Page controls article"].exists || app.buttons["welcome.skip"].exists
            || app.textFields["field.input"].exists || app.buttons["join.close"].exists })
        let identity = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("website-data-store.json"))) as? [String:Any])
        _ = try XCTUnwrap((identity["dataStoreID"] as? String).flatMap(UUID.init(uuidString:)))
        if app.buttons["join.close"].exists { XCTAssertTrue(app.buttons["join.close"].isHittable); app.buttons["join.close"].tap() }
        // The page draws before the welcome's tray rises over it (1.3 s in): wait for it.
        app.passWelcome(timeout: 6)
        if app.textFields["field.input"].exists { app.closeField() }
        XCTAssertTrue(wait { app.staticTexts["Page controls article"].exists && app.buttons["Page action"].isHittable
            && !app.textFields["field.input"].exists })
        return app
    }
    private func openSettings(_ app: XCUIApplication) {
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(wait { plate.exists && app.windows.firstMatch.frame.contains(plate.frame) })
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: plate.frame.midX, dy: plate.frame.midY)).tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(wait { input.isHittable && app.keyboards.firstMatch.exists })
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (input.value as? String ?? "").count) + "settings")
        let best = app.buttons["field.best"]
        XCTAssertTrue(wait { best.isHittable && best.label.contains("Settings") }); best.tap()
        // Settings rises as the whole screen (d0ca2190, 0.5 s): its × is
        // asked about once it has landed, not while it is still off screen.
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(wait { sheet.exists && abs(sheet.frame.minY) < 1 })
        XCTAssertTrue(wait { app.buttons["settings.close"].isHittable })
    }
    private func openIcons(_ app: XCUIApplication) {
        openSettings(app)
        let row = app.buttons["settings.row.appIcon"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); reveal(app, row); row.tap()
        awaitIconPage(app)
        XCTAssertFalse(element(app, "settings.appIcon.unavailable").exists)
    }
    private func awaitIconPage(_ app: XCUIApplication) {
        let next = app.buttons["settings.appIcon.next"]
        XCTAssertTrue(wait {
            app.buttons["settings.appIcon.use"].isHittable && app.staticTexts["settings.appIcon.preview.title"].exists
                && next.exists && next.isHittable && app.windows.firstMatch.frame.contains(next.frame)
        })
    }
    /// Back to the root through the head's ‹, then × there: pages have no ×.
    private func closeSettings(_ app: XCUIApplication) {
        let back = app.buttons["settings.back"]
        for _ in 0..<6 where back.exists && back.isHittable {
            back.tap()
            _ = wait { app.buttons["settings.close"].isHittable || back.isHittable }
        }
        XCTAssertTrue(wait { app.buttons["settings.close"].isHittable })
        app.buttons["settings.close"].tap()
    }
    private func profileIdentity() throws -> String {
        let bytes = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        let profile = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        let selectedSpace = try XCTUnwrap(profile["spaceID"] as? String)
        let spaces = try XCTUnwrap(profile["spaces"] as? [[String:Any]])
        let space = try XCTUnwrap(spaces.first { $0["id"] as? String == selectedSpace })
        let tab = try XCTUnwrap(space["current"] as? String)
        let navigation = try XCTUnwrap(profile["navigation"] as? [String:Any])
        let history = try XCTUnwrap(navigation[tab] as? [String:Any])
        let entries = try XCTUnwrap(history["entries"] as? [[String:Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["url"] as? String, site.url("/article").absoluteString)
        XCTAssertEqual(history["index"] as? Int, 0)
        let identity = try Data(contentsOf: folder.appendingPathComponent("website-data-store.json"))
        return selectedSpace + ":" + tab + ":" + identity.base64EncodedString()
    }
    private func dismissIconNoticeIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(wait {
            let okay = app.alerts.buttons["OK"].firstMatch
            let systemOkay = springboard.alerts.buttons["OK"].firstMatch
            if okay.exists && okay.isHittable { record(app, "Actual UIKit app icon notice"); okay.tap(); return true }
            if systemOkay.exists && systemOkay.isHittable { record(app, "Actual system app icon notice"); systemOkay.tap(); return true }
            return app.buttons["settings.appIcon.use"].label == "In Use"
                && !app.buttons["settings.appIcon.use"].isEnabled
        })
    }
    private func reveal(_ app: XCUIApplication, _ control: XCUIElement) {
        for _ in 0..<5 where !control.isHittable || !app.windows.firstMatch.frame.contains(control.frame) {
            // The sheet's head is 52 high under its top.
            let top = element(app, "settings.sheet").frame.minY + 52
            if control.frame.minY < top { element(app, "settings.sheet").swipeDown(velocity: .slow) }
            else { element(app, "settings.sheet").swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(control.isHittable)
    }
    private func assertControl(_ app: XCUIApplication, _ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let frame = control.frame
        func coordinates(_ rectangle: CGRect) -> String {
            String(format: "minX=%.17g minY=%.17g maxX=%.17g maxY=%.17g width=%.17g height=%.17g",
                   Double(rectangle.minX), Double(rectangle.minY), Double(rectangle.maxX), Double(rectangle.maxY),
                   Double(rectangle.width), Double(rectangle.height))
        }
        let details = "\(control.identifier): window {\(coordinates(window))}; control {\(coordinates(frame))}"
        XCTAssertTrue(control.isHittable, file: file, line: line)
        // Native AX subtraction can lose a few ULPs at a 44pt target.
        // Admit at most 1e-9pt of arithmetic roundoff; the drawn target,
        // strict hittability and window containment stay unchanged.
        let native44 = CGFloat(44) - 1e-9
        XCTAssertGreaterThanOrEqual(frame.width, native44, details, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, native44, details, file: file, line: line)
        let contained = window.contains(frame)
        if !contained { record(app, "App icon control containment failure: " + details) }
        XCTAssertTrue(contained, details, file: file, line: line)
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func wait(_ condition: () -> Bool) -> Bool { TransitionCatalog.wait(10, condition) }
    private func record(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let png = XCTAttachment(screenshot: app.screenshot()); png.name = name; png.lifetime = .keepAlways; activity.add(png)
            let ax = XCTAttachment(string: app.debugDescription); ax.name = name + " AX"; ax.lifetime = .keepAlways; activity.add(ax)
        }
    }
}
