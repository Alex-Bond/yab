import Network
import UIKit
import XCTest

/// Normal profile, owned HTTP page and actual system keyboard. These tests
/// edit only their temporary browser data and never open Mail or an account.
final class SettingsRootTests: XCTestCase {
    private var folder: URL!
    private var site: SettingsRootSite!
    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-settings-root-\(UUID().uuidString)")
        site = try SettingsRootSite()
        let ready = expectation(description: "owned Settings page ready")
        site.ready = { ready.fulfill() }; site.start()
        wait(for: [ready], timeout: 10)
    }
    override func tearDownWithError() throws {
        XCUIApplication().terminate(); site?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testActualSearchPushBackAndFeedbackDraftKeepTheirState() {
        let app = launch()
        openSettings(app)
        let search = app.textFields["settings.search"]
        XCTAssertTrue(wait { search.isHittable }); search.tap(); search.typeText("dark")
        let result = app.buttons["settings.search.result.appearance.appearance.dark"]
        XCTAssertTrue(wait { result.isHittable && app.keyboards.firstMatch.exists })
        assertInWindow(app, result)
        XCTAssertLessThanOrEqual(result.frame.maxY, app.keyboards.firstMatch.frame.minY)
        save(app, "Settings search above actual keyboard")
        result.tap()
        let dark = app.buttons["settings.choice.appearance.dark"]
        XCTAssertTrue(wait { dark.isHittable && !app.keyboards.firstMatch.exists })
        dark.tap(); XCTAssertTrue(dark.isSelected)
        save(app, "Search opens the actual Dark choice and native hero")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { search.exists && search.value as? String == "dark" && result.isHittable })
        XCTAssertFalse(element(app, "settings.page.appearance").exists)
        app.buttons["settings.search.clear"].tap()
        let feedback = app.buttons["settings.row.feedback"]
        reveal(app, feedback); feedback.tap()
        let draft = app.textViews["settings.feedback.draft"].exists ? app.textViews["settings.feedback.draft"] : element(app, "settings.feedback.draft")
        XCTAssertTrue(wait { draft.isHittable }); draft.tap(); draft.typeText("The native title should stay sharp.")
        XCTAssertTrue(app.buttons["settings.feedback.send"].isEnabled)
        // Do not send it.
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { feedback.isHittable && !app.keyboards.firstMatch.exists }); feedback.tap()
        XCTAssertEqual(draft.value as? String, "The native title should stay sharp.")
        save(app, "Back preserves a reviewable Feedback draft")
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && !app.keyboards.firstMatch.exists })
        app.webViews.buttons["Actual Settings page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Action 1"].waitForExistence(timeout: 5))
    }

    func testSettingsEditsActualSpaceMetadataWithoutReloadingItsPageAndRelaunchKeepsIt() throws {
        let app = launch()
        let action = app.webViews.buttons["Actual Settings page action"]
        action.tap(); XCTAssertTrue(app.webViews.staticTexts["Action 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait { savedSpace() != nil })
        let before = try XCTUnwrap(savedSpace())
        let original = try XCTUnwrap((before["today"] as? [[String: Any]])?.first { $0["url"] as? String == site.url.absoluteString })
        openSettings(app)
        app.buttons["settings.row.spaces"].tap()
        let personal = app.buttons["settings.space.local.personal"]
        XCTAssertTrue(wait { personal.isHittable }); personal.tap()
        app.buttons["settings.space.name"].tap()
        let input = app.textFields["settings.space.name.input"]
        XCTAssertTrue(wait { input.isHittable && app.keyboards.firstMatch.exists })
        let old = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Research")
        let done = app.buttons["settings.space.done"]
        // Keep the real drawn and AX state even when the native button query
        // fails before the later successful-path screenshot can be saved.
        save(app, "Settings Name actual Done and keyboard before target assertion")
        XCTAssertTrue(wait { done.isHittable && done.frame.maxY <= app.keyboards.firstMatch.frame.minY })
        assertInWindow(app, done); save(app, "Settings Name and native Done above keyboard")
        done.tap()
        XCTAssertTrue(wait { app.buttons["settings.space.emoji"].isHittable && !app.keyboards.firstMatch.exists })
        app.buttons["settings.space.emoji"].tap()
        // The emoji page comes in from the right as iOS pushes one (fc244762):
        // a tap taken while it slides lands on the next cell (🎨, a3044dc9cee9468e).
        let books = app.buttons["column.tray.emoji.pick.📚"]
        XCTAssertTrue(books.waitForExistence(timeout: 5)); books.waitUntilStill(); books.tap()
        XCTAssertTrue(wait { books.value as? String == "selected" }, "📚 isn't chosen: \(String(describing: books.value))")
        app.buttons["settings.space.done"].tap()
        XCTAssertTrue(wait { app.buttons["settings.space.color"].isHittable }); app.buttons["settings.space.color"].tap()
        // Drawings: Life, then its strength on the native slider.
        let life = app.buttons["space.look.drawings.life"]
        reveal(app, life); life.tap()
        let strength = app.sliders["space.look.drawings"]
        XCTAssertTrue(strength.waitForExistence(timeout: 3), "picking a set brings its strength")
        reveal(app, strength); strength.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(wait { strength.isHittable && done.isHittable && element(app, "settings.space.editor").exists },
                      "the native strength pointer must not pop its Color page")
        assertInWindow(app, done)
        save(app, "Settings Color uses the actual Look field and native sliders")
        app.buttons["settings.space.done"].tap()
        XCTAssertTrue(wait { element(app, "settings.page.title").label == "Research" })
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists })
        action.tap()
        XCTAssertTrue(app.webViews.staticTexts["Action 2"].waitForExistence(timeout: 5), "the same live WK page must survive metadata editing")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(wait { savedSpace()?["name"] as? String == "Research" && savedSpace()?["emoji"] as? String == "📚" },
                      "saved name \(String(describing: savedSpace()?["name"])), emoji \(String(describing: savedSpace()?["emoji"]))")
        let saved = try XCTUnwrap(savedSpace())
        let after = try XCTUnwrap((saved["today"] as? [[String: Any]])?.first { $0["id"] as? String == original["id"] as? String })
        XCTAssertEqual(after["url"] as? String, original["url"] as? String)
        XCTAssertEqual(saved["current"] as? String, before["current"] as? String)
        let raw = try XCTUnwrap((saved["look"] as? [String: Any])?["raw"] as? [String: Any])
        XCTAssertEqual(raw["drawings"] as? String, "life")
        XCTAssertGreaterThanOrEqual(raw["drawingsStrength"] as? Double ?? 0, 0.7)
        app.terminate()
        let relaunched = launch(initial: false)
        openSettings(relaunched); relaunched.buttons["settings.row.spaces"].tap()
        let retained = relaunched.buttons["settings.space.local.personal"]
        save(relaunched, "Relaunched Settings actual space row before assertions")
        let restored = try XCTUnwrap(savedSpace())
        let profileReceipt = XCTAttachment(data: try Data(contentsOf: folder.appendingPathComponent("profile.json")),
                                          uniformTypeIdentifier: "public.json")
        profileReceipt.name = "Owned profile after real metadata relaunch"; profileReceipt.lifetime = .keepAlways
        add(profileReceipt)
        XCTAssertEqual(restored["id"] as? String, before["id"] as? String)
        XCTAssertEqual(restored["name"] as? String, "Research")
        XCTAssertEqual(restored["emoji"] as? String, "📚")
        // SpaceLookTile is intentionally decorative in the list. Verify the
        // real visible Emoji setting, rather than inventing an AX tile label.
        XCTAssertTrue(wait { retained.isHittable && retained.label.contains("Research") })
        retained.tap()
        let retainedName = relaunched.buttons["settings.space.name"]
        let retainedEmoji = relaunched.buttons["settings.space.emoji"]
        XCTAssertTrue(wait { retainedName.isHittable && retainedName.label.contains("Research") &&
                             retainedEmoji.isHittable && retainedEmoji.label.contains("📚") })
        save(relaunched, "Relaunched Settings retains actual Name and Emoji controls")
        relaunched.buttons["settings.space.color"].tap()
        let retainedStrength = relaunched.sliders["space.look.drawings"]
        reveal(relaunched, retainedStrength)
        let restoredLook = try XCTUnwrap((restored["look"] as? [String: Any])?["raw"] as? [String: Any])
        for (control, key) in [(retainedStrength, "drawingsStrength")] {
            let expected = try XCTUnwrap(raw[key] as? Double)
            XCTAssertEqual(restoredLook[key] as? Double, expected)
            XCTAssertEqual(control.value as? String, "\(Int((expected * 100).rounded()))%")
            assertInWindow(relaunched, control)
        }
        save(relaunched, "Relaunched Color retains the actual native slider values")
    }

    func testNativeColorSlidersKeepTheirPageAndARealEmptyEdgeSwipeGoesBack() {
        let app = launch()
        openSettings(app)
        app.buttons["settings.row.spaces"].tap()
        let personal = app.buttons["settings.space.local.personal"]
        XCTAssertTrue(wait { personal.isHittable }); personal.tap()
        app.buttons["settings.space.color"].tap()
        let done = app.buttons["settings.space.done"]
        let browser = app.buttons["space.look.drawings.browser"]
        reveal(app, browser); browser.tap()
        let strength = app.sliders["space.look.drawings"]
        XCTAssertTrue(strength.waitForExistence(timeout: 3))
        reveal(app, strength)
        strength.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(wait { strength.isHittable && done.isHittable })
        strength.adjust(toNormalizedSliderPosition: 0.85)
        XCTAssertTrue(wait { strength.isHittable && done.isHittable })
        assertInWindow(app, done)
        save(app, "The actual minimum thumb owns its pointer drag")
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: window.frame.height * 0.65))
        let end = start.withOffset(CGVector(dx: 160, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 400, thenHoldForDuration: 0.1)
        XCTAssertTrue(wait { !done.exists && app.buttons["settings.space.color"].isHittable },
                      "the actual empty viewport edge must still go Back")
        XCTAssertTrue(element(app, "settings.sheet").exists)
        save(app, "A genuine empty edge swipe returns to this space only")
        closeSettings(app)
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists })
        app.webViews.buttons["Actual Settings page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Action 1"].waitForExistence(timeout: 5))
    }

    /// Largest text: the one head (× on the left, the title in the middle)
    /// and the search's controls stay reachable over the keyboard; × drops the
    /// plain sheet and nothing (no column, no tray) comes back up.
    func testLargestTextKeepsTheHeadAndKeyboardControlsReachableAndCloseOpensNothing() throws {
        let app = launch(extra: ["-YabReduceMotion", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        openSettings(app)
        let close = app.buttons["settings.close"]
        XCTAssertTrue(wait { close.isHittable })
        assertInWindow(app, close)
        XCTAssertEqual(close.frame.minX, 12, accuracy: 1, "× sits on the left")
        XCTAssertFalse(app.buttons["settings.back"].exists, "the root has no ‹")
        let search = app.textFields["settings.search"]
        search.tap(); search.typeText("private")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.search.result.privateTabs.")).firstMatch
        XCTAssertTrue(wait { result.isHittable }); assertInWindow(app, result)
        XCTAssertLessThanOrEqual(result.frame.maxY, app.keyboards.firstMatch.frame.minY)
        let clear = app.buttons["settings.search.clear"]
        assertInWindow(app, clear)
        XCTAssertEqual(clear.frame.width, 44, accuracy: 1)
        XCTAssertEqual(clear.frame.height, 44, accuracy: 1)
        XCTAssertLessThanOrEqual(clear.frame.maxY, app.keyboards.firstMatch.frame.minY)
        save(app, "Largest-text search and the head's × above keyboard")
        try app.performAccessibilityAudit()
        close.tap()
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && !app.keyboards.firstMatch.exists })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(element(app, "newtab.spaces").exists, "closing Settings reopens nothing")
        app.webViews.buttons["Actual Settings page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Action 1"].waitForExistence(timeout: 5))
    }

    func testSelectedHtmlRootOrderSyncAndAboutUseTheActualNativePages() throws {
        let app = launch()
        openSettings(app)
        app.buttons["settings.row.appearance"].tap()
        let light = app.buttons["settings.choice.appearance.light"]
        XCTAssertTrue(wait { light.isHittable }); light.tap()
        XCTAssertTrue(light.isSelected)
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { app.buttons["settings.row.general"].isHittable })
        let ids = ["general", "search", "appearance", "appIcon", "tabs", "sync", "ai", "spaces", "history", "passwords", "autofill", "privacy", "about", "feedback"]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.row."))
        XCTAssertEqual(rows.count, ids.count)
        save(app, "Selected HTML Settings root with real Mac marks and Sync before AI")
        for id in ids {
            let row = app.buttons["settings.row." + id]
            showReferenceRow(app, row); assertInWindow(app, row)
            // AX order remains the document order even after a small screen
            // scrolls each later row into its real visible touch region.
            let ordered = rows.allElementsBoundByIndex.map(\.identifier)
            XCTAssertEqual(ordered, ids.map { "settings.row." + $0 })
            XCTAssertTrue(row.frame.minY.isFinite)
        }
        let sync = app.buttons["settings.row.sync"]
        showReferenceRow(app, sync); sync.tap()
        XCTAssertTrue(wait { element(app, "settings.page.title").label == "Sync" && app.buttons["settings.back"].isHittable })
        save(app, "Actual Sync basic-page hero keeps the Mac system glyph fallback")
        app.buttons["settings.back"].tap()
        let about = app.buttons["settings.row.about"]
        showReferenceRow(app, about); about.tap()
        XCTAssertTrue(wait { element(app, "settings.page.title").label == "About" && app.buttons["settings.back"].isHittable })
        save(app, "Actual About hero uses the info drawing instead of an app-logo substitute")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { about.exists && app.textFields["settings.search"].exists })
        try app.performAccessibilityAudit()
        app.buttons["settings.close"].tap()
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists })
        app.buttons["Actual Settings page action"].tap()
        XCTAssertTrue(app.staticTexts["Action 1"].waitForExistence(timeout: 5), "Native Settings art must not replace or reload the actual page")
    }

    func testSelectedHtmlMarksInDarkAtLargestTextKeepSearchBackAndActualPage() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openSettings(app)
        let appearance = app.buttons["settings.row.appearance"]
        showReferenceRow(app, appearance); appearance.tap()
        let dark = app.buttons["settings.choice.appearance.dark"]
        reveal(app, dark); dark.tap()
        XCTAssertTrue(wait { dark.isSelected && app.buttons["settings.back"].isHittable })
        save(app, "Largest native text and Dark Appearance with actual palette hero")
        app.buttons["settings.back"].tap()
        let search = app.textFields["settings.search"]
        XCTAssertTrue(wait { search.isHittable && !app.keyboards.firstMatch.exists })
        save(app, "Dark Settings root top at accessibility XXXL")
        let footer = app.buttons["settings.row.about"]
        showReferenceRow(app, footer); assertInWindow(app, footer)
        save(app, "Dark Settings footer at accessibility XXXL keeps About and Feedback reachable")
        // The root offset and query are still owned by the existing native
        // Settings stack. Search must restore them through a real push/Back.
        for _ in 0..<5 where !search.isHittable { element(app, "settings.sheet").swipeDown(velocity: .slow) }
        XCTAssertTrue(search.isHittable); search.tap(); search.typeText("about")
        let result = app.buttons["settings.search.result.about.page"]
        XCTAssertTrue(wait { result.isHittable && app.keyboards.firstMatch.exists })
        assertInWindow(app, result)
        XCTAssertLessThanOrEqual(result.frame.maxY, app.keyboards.firstMatch.frame.minY)
        result.tap()
        XCTAssertTrue(wait { element(app, "settings.page.title").label == "About" && !app.keyboards.firstMatch.exists })
        save(app, "Dark largest-text native About page after literal search")
        app.buttons["settings.back"].tap()
        XCTAssertTrue(wait { search.value as? String == "about" && result.isHittable })
        app.buttons["settings.search.clear"].tap()
        try app.performAccessibilityAudit()
        app.buttons["settings.close"].tap()
        XCTAssertTrue(wait { !element(app, "settings.sheet").exists && !app.keyboards.firstMatch.exists })
        app.buttons["Actual Settings page action"].tap()
        XCTAssertTrue(app.staticTexts["Action 1"].waitForExistence(timeout: 5))
    }

    private func showReferenceRow(_ app: XCUIApplication, _ row: XCUIElement) {
        let sheet = element(app, "settings.sheet")
        XCTAssertTrue(row.exists)
        let window = app.windows.firstMatch.frame
        for _ in 0..<5 where !(row.isHittable && window.contains(row.frame)) {
            if row.frame.minY < sheet.frame.minY + 60 { sheet.swipeDown(velocity: .slow) }
            else { sheet.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(row.isHittable)
    }

    @discardableResult private func launch(initial: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path] + (initial ? ["-YabURL", site.url.absoluteString] : []) + extra
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate(); app.launch()
        let later = app.buttons["welcome.skip"]
        XCTAssertTrue(later.waitForExistence(timeout: 15)); app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the welcome's New Tab field stayed over the page")
        XCTAssertTrue(app.webViews.staticTexts["Owned Settings page"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(wait { sheet.exists && abs(sheet.frame.minY) < 1 && !input.exists })
        XCTAssertTrue(wait { app.buttons["settings.close"].isHittable })
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
    private func reveal(_ app: XCUIApplication, _ control: XCUIElement) {
        for _ in 0..<5 where !control.isHittable { element(app, "settings.sheet").swipeUp(velocity: .slow) }
        XCTAssertTrue(control.isHittable)
    }
    private func assertInWindow(_ app: XCUIApplication, _ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(control.isHittable, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.minY, window.minY + 60, file: file, line: line)
        XCTAssertTrue(window.contains(control.frame), file: file, line: line)
    }
    private func savedSpace() -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("profile.json")),
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (profile["spaces"] as? [[String: Any]])?.first { $0["id"] as? String == "local.personal" }
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func wait(_ condition: () -> Bool) -> Bool { TransitionCatalog.wait(10, condition) }
    private func save(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let photo = XCTAttachment(screenshot: app.screenshot()); photo.name = name; photo.lifetime = .keepAlways; activity.add(photo)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " AX"; tree.lifetime = .keepAlways; activity.add(tree)
        }
    }
}

private final class SettingsRootSite {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.settings-root-site")
    private var connections: [NWConnection] = []
    var ready: (() -> Void)?
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: self.queue); self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = data; if let bytes { request.append(bytes) }
            guard request.count <= 65_536 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            let title = "Owned Settings page"
            let html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1,viewport-fit=cover'><link rel=icon href=data:,><title>\(title)</title><style>body{font:20px system-ui;padding:80px 20px}button{font:18px system-ui;padding:14px}</style><h1>\(title)</h1><button onclick=\"document.getElementById('receipt').textContent='Action '+(++window.actions)\">Actual Settings page action</button><p id=receipt></p><script>window.actions=0</script>"
            let content = Data(html.utf8)
            let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(content.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: head + content, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in if error != nil { connection.cancel() } })
        }
    }
    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections = [] }
    }
}
