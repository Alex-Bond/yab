import XCTest

/// The field, its words, the eyes, the plate's menu and links from other apps, driven the way
/// a person does: tap the plate, type, Return; hold the plate; a link from
/// another app. Frames are checked against the prototype's (sizes.md), the
/// haptics against its table (motion.md) through the app's haptics journal.
final class FieldTests: XCTestCase {
    private var journal: URL!
    private var motions: URL!

    override func setUp() {
        continueAfterFailure = false
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("yab-haptics-\(UUID().uuidString).log")
        motions = FileManager.default.temporaryDirectory.appendingPathComponent("yab-motion-\(UUID().uuidString).log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: journal)
        try? FileManager.default.removeItem(at: motions)
    }

    private func launch(_ extra: [String] = [], still: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira"] + (still ? ["-YabNoAnim", "YES"] : []) + extra
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launchEnvironment["YAB_MOTION_JOURNAL"] = motions.path
        app.launch()
        let state = extra.firstIndex(of: "-YabState").flatMap { index in
            extra.indices.contains(index + 1) ? extra[index + 1] : nil
        }
        // These fixtures start with the field covering the chrome. Covered
        // controls are correctly absent from the accessibility tree.
        let fieldIsOpen = ["newtab.1", "privacy.1", "privacy.2"].contains(state ?? "")
        let ready = fieldIsOpen ? app.textFields["field.input"] : app.descendants(matching: .any)["chrome.plate"]
        XCTContext.runActivity(named: "Field launch: \(state ?? "page") waits for \(fieldIsOpen ? "field.input" : "chrome.plate")") { _ in
            XCTAssertTrue(ready.waitForExistence(timeout: 15), fieldIsOpen ? "no field" : "no plate")
        }
        return app
    }

    /// The haptics played so far: "kind reason" each.
    private func haptics() -> [String] {
        let text = (try? String(contentsOf: journal, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { line in
            line.split(separator: " ", maxSplits: 1).dropFirst().joined()
        }
    }

    /// The morphs and cross-fades run so far: "name" or "crossFade <morph>".
    private func motionsRun() -> [String] {
        ((try? String(contentsOf: motions, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func waitFor(_ element: XCUIElement, label words: String, timeout: TimeInterval = 5) -> Bool {
        let has = NSPredicate(format: "label CONTAINS %@", words)
        return XCTWaiter.wait(for: [expectation(for: has, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func waitFor(_ element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let has = NSPredicate(format: "exists == true AND value == %@", value)
        return XCTWaiter.wait(for: [expectation(for: has, evaluatedWith: element)], timeout: timeout) == .completed
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// In the tree and on the screen: the card's pages keep their neighbors
    /// laid out beside the one in front.
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return frame.width > 0 && frame.height > 0 && app.windows.firstMatch.frame.intersects(frame)
    }

    /// The field's frame and the keyboard's height as the app stands them.
    private func fieldFrame(_ app: XCUIApplication) -> (CGRect, CGFloat) {
        let frame = element(app, "field.frame")
        XCTAssertTrue(frame.waitForExistence(timeout: 5), "no field frame")
        let height = (frame.value as? String)?.split(separator: " ").last.flatMap { Double($0) } ?? 0
        XCTAssertGreaterThan(height, 200, "the keyboard is up")
        return (frame.frame, CGFloat(height))
    }

    /// The keyboard's return key by the word it says (go, search, send):
    /// iOS draws some as glyphs, so it is found by its label, any case.
    private func key(_ app: XCUIApplication, _ word: String) -> XCUIElement {
        app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", word, word)).firstMatch
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// The pixels of an element in the selected address's highlight (light
    /// appearance, Metrics.Field.selection: #BBD8FF).
    private func highlighted(_ element: XCUIElement) -> Int {
        guard let image = element.screenshot().image.cgImage else { XCTFail("no native screenshot pixels"); return -1 }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var count = 0
        for at in stride(from: 0, to: bytes.count, by: 4)
        where abs(Int(bytes[at]) - 0xBB) <= 8 && abs(Int(bytes[at + 1]) - 0xD8) <= 8 && abs(Int(bytes[at + 2]) - 0xFF) <= 8 {
            count += 1
        }
        return count
    }

    // MARK: - the plate's field

    func testThePlateGrowsIntoTheFieldWithTheAddressSelected() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "no field")
        XCTAssertEqual(input.value as? String, "figma.com/design/xK29fLm8/Onboarding-v3")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard rises with the field")
        // No page card: its actions are the page menu's, and the field stands
        // in the space's one card, as New Tab's does (448423cb); ⓧ clears.
        XCTAssertFalse(element(app, "field.card").exists, "the page's card is gone")
        XCTAssertTrue(element(app, "newtab.spaces").exists, "the field stands in the space's card")
        XCTAssertTrue(element(app, "field.clearWords").exists, "ⓧ clears the address")
        // Where New Tab's field stands: 8 from the sides as its rows' card, 48 high, 8 over
        // the keyboard; ✕ its own 48 circle, 7 beside it (65619b17, 448423cb).
        let screen = app.windows.firstMatch.frame
        let (field, keyboard) = fieldFrame(app)
        XCTAssertEqual(field.minX, 8, accuracy: 1)
        XCTAssertEqual(field.height, 48, accuracy: 1)
        XCTAssertEqual(screen.height - keyboard - field.maxY, 8, accuracy: 1, "8 over the keyboard")
        let close = app.buttons["field.close"].frame
        XCTAssertEqual(close.minX - field.maxX, 7, accuracy: 1, "✕ 7 beside the field")
        XCTAssertEqual(close.width, 48, accuracy: 1)
        XCTAssertEqual(close.height, field.height, accuracy: 1, "✕ as tall as the field")
        XCTAssertEqual(close.minY, field.minY, accuracy: 1)
        XCTAssertEqual(close.maxX, screen.width - 8, accuracy: 1)
        XCTAssertTrue(input.frame.minY >= field.minY && input.frame.maxY <= field.maxY + 1, "the words inside the field")
        // Return over the address reloads it, and the field lands.
        key(app, "go").tap()
        // The toast stays 2.2 s: looked for first.
        XCTAssertTrue(element(app, "chrome.toast").waitForExistence(timeout: 2), "Reloading is said")
        XCTAssertTrue(waitGone(input), "go closes the field")
    }

    func testAWordFindsItsTabAndGoSwitches() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("hacker")
        let best = element(app, "field.best")
        XCTAssertTrue(best.waitForExistence(timeout: 3))
        XCTAssertTrue(best.label.contains("Hacker News"), "best: \(best.label)")
        XCTAssertEqual(best.value as? String, "go")
        XCTAssertTrue(key(app, "go").exists, "the key says go")
        key(app, "go").tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(element(app, "chrome.plate").label.contains("Hacker News"), "the plate says \(element(app, "chrome.plate").label)")
        XCTAssertFalse(haptics().contains { $0.hasPrefix("light") || $0.hasPrefix("medium") }, "the field is quiet: \(haptics())")
    }

    func testTheKeyNamesTheTopRow() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("lisbon weather october")
        XCTAssertTrue(key(app, "search").waitForExistence(timeout: 3), "a search's key says search")
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "lisbon weather october".count))
        XCTAssertEqual(input.value as? String ?? "", input.placeholderValue ?? "", "deleting the words keeps the field open")
        input.typeText("what does anna want?")
        XCTAssertTrue(element(app, "field.best").label.contains("Ask Claude"), "a question asks: \(element(app, "field.best").label)")
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "what does anna want?".count))
        input.typeText("book the tap 18:35 to lisbon, window seat")
        XCTAssertTrue(key(app, "send").waitForExistence(timeout: 3), "a task's key says send")
        key(app, "send").tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(element(app, "chrome.now").waitForExistence(timeout: 5), "the Now line takes the task")
        XCTAssertTrue(haptics().contains("light task sent"), "send is confirmed: \(haptics())")
    }

    func testADraftWaitsAtItsPage() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("what to pack")
        // ✕ beside the field: it goes back into the plate, words kept. The
        // space's card fills the screen around it, so there is no beside.
        app.buttons["field.close"].tap()
        XCTAssertTrue(waitGone(input), "✕ closes the field")
        element(app, "chrome.plate").tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "what to pack", "the draft is back")
    }

    /// With motion on, the plate's growth into the field and its landing
    /// back run inside their signposts (Motion.fieldOpen, Motion.fieldClose),
    /// which is what Instruments and this metric measure.
    func testTheFieldsMotionsRunInsideTheirSignposts() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira"]
        app.launchEnvironment["YAB_HAPTICS_JOURNAL"] = journal.path
        app.launch()
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 15))
        let metrics = ["fieldOpen", "fieldClose"].map {
            XCTOSSignpostMetric(subsystem: "dev.serafim.fast.iphone", category: "PointsOfInterest", name: $0)
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: metrics, options: options) {
            plate.tap()
            let input = app.textFields["field.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            // ✕: a tap "beside" lands on the space's card around the field.
            app.buttons["field.close"].tap()
            XCTAssertTrue(waitGone(input))
            // The landing done before the next round.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
    }

    // MARK: - holding the plate

    func testPullingTheMenuDownFromARowDoesNotPressIt() {
        let app = launch()
        element(app, "chrome.plate").press(forDuration: 0.7)
        XCTAssertTrue(element(app, "plate.menu").waitForExistence(timeout: 3))
        let desktop = element(app, "plate.menu.desktop")
        XCTAssertTrue(desktop.waitForExistence(timeout: 2))
        let label = desktop.label
        let start = desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)), withVelocity: .slow, thenHoldForDuration: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(desktop.exists, "a short pull leaves the menu up")
        XCTAssertEqual(desktop.label, label, "the row under the finger was pressed")
        desktop.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(element(app, "plate.menu").exists && desktop.label == label, "a plain tap still presses it")
    }

    func testHoldingThePlateGrowsItsMenu() {
        let app = launch()
        element(app, "chrome.plate").press(forDuration: 0.7)
        let menu = element(app, "plate.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 3), "no menu; haptics: \(haptics())")
        // The menu's layout: the address row, four tiles, the list, Site Settings.
        for item in ["back", "forward", "copy", "reload", "ask", "find", "keep", "share",
                     "reader", "zoom", "desktop", "onMac", "task", "siteSettings"] {
            XCTAssertTrue(element(app, "plate.menu.\(item)").waitForExistence(timeout: 2), "no \(item)")
        }
        XCTAssertFalse(element(app, "plate.menu.hide").exists, "Hide Something is gone")
        // The sheet 8 from the screen's sides and foot; the plate is its row
        // now, and everything inside keeps the row's 14 (448423cb).
        let screen = app.windows.firstMatch.frame
        let ask = element(app, "plate.menu.ask").frame, share = element(app, "plate.menu.share").frame
        XCTAssertEqual(ask.minX, 8 + 14, accuracy: 1.5)
        XCTAssertEqual(share.maxX, screen.width - 8 - 14, accuracy: 1.5)
        let site = element(app, "plate.menu.siteSettings").frame
        XCTAssertEqual(site.maxY, screen.height - 8 - 16, accuracy: 2)
        XCTAssertFalse(element(app, "chrome.plate").exists, "the plate is the menu's row")
        XCTAssertTrue(haptics().contains("medium menu"), "holding is a medium click: \(haptics())")
        // Open on Mac answers in its own row.
        element(app, "plate.menu.onMac").tap()
        XCTAssertTrue(waitFor(element(app, "plate.menu.onMac"), label: "Opened on"), element(app, "plate.menu.onMac").label)
        XCTAssertFalse(element(app, "chrome.toast").exists)
        // Copy Link, as the Mac's: a tick where the link was, the menu stays.
        element(app, "plate.menu.copy").tap()
        XCTAssertTrue(waitFor(element(app, "plate.menu.copy"), value: "Copied"), "\(String(describing: element(app, "plate.menu.copy").value))")
        XCTAssertFalse(element(app, "chrome.toast").exists, "the tick says it")
        XCTAssertTrue(menu.exists, "the menu stays")
    }

    /// The page's card left the field (448423cb): Copy Link is the page
    /// menu's, ≡ on the plate; it turns into a tick and the menu stays.
    func testThePageMenuCopiesItsLink() {
        let app = launch()
        let pageMenu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(pageMenu.waitForExistence(timeout: 5), "no ≡ on the plate")
        pageMenu.tap()
        let copy = app.buttons["plate.menu.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "no Copy Link in the menu's row")
        copy.tap()
        XCTAssertTrue(waitFor(copy, value: "Copied"), "\(String(describing: copy.value))")
        XCTAssertTrue(element(app, "plate.menu").exists, "the menu stays, as the Mac's plate does")
    }

    // MARK: - New Tab and the eyes

    /// New Tab is the spaces' card around its field (efa361a2, 9f085a0c): the
    /// whole screen, the capsule of pages on top (Private, Chats, then the
    /// spaces) between Yab's mark and the gear, the space's pins, what it
    /// keeps and today's tabs, and the field at its foot.
    func testNewTabOffersTheSpacesPages() {
        let app = launch(["-YabState", "newtab.1"])
        let spaces = element(app, "newtab.spaces")
        XCTAssertTrue(spaces.waitForExistence(timeout: 10))
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(spaces.frame.minY, screen.minY, accuracy: 1, "the whole screen")
        XCTAssertEqual(spaces.frame.height, screen.height, accuracy: 1)
        XCTAssertEqual(spaces.frame.width, screen.width, accuracy: 1)
        let capsule = element(app, "newtab.capsule")
        XCTAssertTrue(capsule.exists, "no capsule of pages")
        XCTAssertGreaterThanOrEqual(capsule.frame.minY, 54, "never into the status bar")
        let work = capsule.buttons["Work"]
        XCTAssertTrue(work.exists, "the capsule names the space")
        XCTAssertEqual(work.value as? String, "current", "New Tab opens on the space in front")
        for id in ["newtab.about", "newtab.settings", "newtab.space.work", "newtab.folder.work-onboarding"] {
            XCTAssertTrue(element(app, id).exists, "no \(id)")
        }
        // The field 8 from the sides, 48 high, 8 over the keyboard, with
        // its ✕ 7 beside it and the eyes (open) inside (65619b17).
        let (field, keyboard) = fieldFrame(app)
        XCTAssertEqual(field.minX, 8, accuracy: 1)
        XCTAssertEqual(field.height, 48, accuracy: 1)
        XCTAssertEqual(screen.height - keyboard - field.maxY, 8, accuracy: 1)
        let close = app.buttons["field.close"].frame
        XCTAssertEqual(close.minX - field.maxX, 7, accuracy: 1)
        XCTAssertEqual(close.maxX, screen.width - 8, accuracy: 1)
        XCTAssertEqual(element(app, "field.eyes").value as? String, "off")
        // Nothing chosen: no key to press.
        XCTAssertFalse(key(app, "go").isEnabled, "go is off while New Tab is empty")
        // Hacker News from today's tabs: its tab, no new one.
        let hn = element(app, "newtab.tab.work-hn")
        XCTAssertTrue(hn.isHittable, "today's Hacker News stands over the field")
        hn.tap()
        XCTAssertTrue(waitGone(spaces))
        XCTAssertTrue(element(app, "chrome.plate").label.contains("Hacker News"), element(app, "chrome.plate").label)
    }

    func testTheEyesShutForIncognitoAndOpenAPrivateTab() {
        let app = launch(["-YabState", "privacy.1"])
        let eyes = element(app, "field.eyes")
        XCTAssertTrue(eyes.waitForExistence(timeout: 10), "no eyes in New Tab's field")
        XCTAssertEqual(eyes.value as? String, "off")
        eyes.tap()
        XCTAssertEqual(eyes.value as? String, "on")
        // The card goes to its Private page: the private tabs under its lock
        // when Private asks for Face ID, else the tabs (or the empty page)
        // themselves; the space's tabs are out of sight (efa361a2, 2fa09628).
        let privatePage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["private.lock", "private.tabs", "private.empty"])).firstMatch
        XCTAssertTrue(privatePage.waitForExistence(timeout: 3), "the eyes go to Private's page")
        XCTAssertTrue(waitFor(element(app, "newtab.capsule").buttons["Private"], value: "current"))
        XCTAssertFalse(onScreen(app, element(app, "newtab.tab.work-hn")), "no space's tabs while the eyes are shut")
        XCTAssertTrue(haptics().contains("soft eyes"), "the eyes are a soft click: \(haptics())")
        let input = app.textFields["field.input"]
        input.typeText("gift ideas for jonas")
        let best = element(app, "field.best")
        XCTAssertTrue(best.waitForExistence(timeout: 3))
        XCTAssertTrue(best.label.contains("Search Google · new tab"), best.label)
        XCTAssertFalse(element(app, "field.row.1").exists, "only the search")
        key(app, "search").tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(element(app, "chrome.plate").label.contains("Google"), element(app, "chrome.plate").label)
        // Shut softly, and open again softly as the private tab opens.
        XCTAssertEqual(haptics().filter { $0 == "soft eyes" }.count, 2, "two soft clicks: \(haptics())")
        XCTAssertEqual(element(app, "chrome.plus").value as? String, "Private")
        // The spaces from the private tab (the column's swipe, aaf8443d): the
        // eyes take the card to Private, where the tab waits under the lock,
        // and back to the space; ✕ leaves the private tab in front.
        SpacesGesture.open(in: app)
        let spaces = element(app, "newtab.spaces")
        XCTAssertTrue(spaces.waitForExistence(timeout: 5), "the upward swipe brought no spaces")
        let capsule = element(app, "newtab.capsule")
        let spacesEyes = element(app, "field.eyes")
        XCTAssertTrue(spacesEyes.waitForExistence(timeout: 3))
        let space = capsule.buttons.matching(NSPredicate(format: "value == %@", "current")).firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 3), "the capsule names no page")
        let spaceName = space.label
        XCTAssertNotEqual(spaceName, "Private", "the spaces open on a space, not on Private")
        spacesEyes.tap()
        XCTAssertTrue(element(app, "private.lock").waitForExistence(timeout: 3), "Private's page holds the private tab")
        XCTAssertTrue(waitFor(capsule.buttons["Private"], value: "current"))
        spacesEyes.tap()
        XCTAssertTrue(waitFor(capsule.buttons[spaceName], value: "current"), "the eyes open back to \(spaceName)")
        XCTContext.runActivity(named: "The spaces after Private and back") { activity in
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "private-tab-spaces"
            picture.lifetime = .keepAlways
            activity.add(picture)
        }
        app.buttons["field.close"].tap()
        XCTAssertTrue(waitGone(spaces))
        XCTAssertEqual(element(app, "chrome.plus").value as? String, "Private")
        XCTAssertTrue(element(app, "chrome.plate").label.contains("Google"))
    }

    /// The spaces at rest (the plate swiped up, keyboard down) go back into
    /// the plate with a finger down from the top of their list (75c15ae1).
    /// New Tab with the keyboard up closes by ✕.
    func testTheSpacesSwipeDownIntoThePlate() {
        let app = launch()
        SpacesGesture.open(in: app)
        let spaces = element(app, "newtab.spaces")
        XCTAssertTrue(spaces.waitForExistence(timeout: 5), "the upward swipe brought no spaces")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the spaces rest with the keyboard down")
        // Down from the top of the space's list (CardPull, measured in the
        // window), slowly and held before lifting: taken more than a quarter
        // of the way, they go whatever the speed. The head's own drag is read
        // in the capsule's space, which moves down with the finger, and a
        // synthesized drag on it came back (cbcafa1832dd4eba,
        // e524571462204ad2, 83d31f27d06843e4).
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitGone(spaces), "pulled down, the spaces go back into the plate")
        XCTAssertTrue(element(app, "chrome.plate").label.contains("Figma"), "no tab was made")
    }

    /// Down by their capsule, the spaces' head, as far as by their list: the
    /// finger is read in the screen's points, not in the capsule's own, which
    /// move down with the spaces (a drag there came out short and the spaces
    /// sprang back up, cbcafa1832dd4eba, e524571462204ad2, 83d31f27d06843e4).
    func testTheSpacesGoDownByTheirCapsule() {
        let app = launch()
        SpacesGesture.open(in: app)
        let spaces = element(app, "newtab.spaces")
        XCTAssertTrue(spaces.waitForExistence(timeout: 5), "the upward swipe brought no spaces")
        let capsule = element(app, "newtab.capsule")
        XCTAssertTrue(capsule.waitForExistence(timeout: 3))
        capsule.waitUntilStill(timeout: 3)
        let window = app.windows.firstMatch
        let frame = capsule.frame
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitGone(spaces), "taken down by their capsule, the spaces go back into the plate")
        XCTAssertTrue(element(app, "chrome.plate").waitForExistence(timeout: 5), "the plate is back")
    }

    /// Large text: a space's list scrolled down takes a pull down itself, back
    /// toward its top, before the pull can take the spaces into the plate
    /// (CardPull in NewTabSpaces, 75c15ae1).
    func testLargeSpacesScrollBeforeTheirTopLowersThem() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        SpacesGesture.open(in: app)
        let spaces = element(app, "newtab.spaces")
        XCTAssertTrue(spaces.waitForExistence(timeout: 5), "the upward swipe brought no spaces")
        let first = element(app, "newtab.folder.work-onboarding")
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let top = first.frame.minY
        let window = app.windows.firstMatch
        let up = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        up.press(forDuration: 0.05, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -240)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(TransitionCatalog.wait(3) { first.frame.minY < top - 60 }, "large rows scroll: \(top) to \(first.frame.minY)")
        let scrolled = first.frame.minY
        let down = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        down.press(forDuration: 0.05, thenDragTo: down.withOffset(CGVector(dx: 0, dy: 100)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(spaces.exists, "the scroll consumes the pull before the spaces go")
        XCTAssertEqual(spaces.frame.minY, window.frame.minY, accuracy: 1, "the spaces stay the whole screen")
        XCTAssertGreaterThan(first.frame.minY, scrolled + 10, "the content moves inside the card")
        app.buttons["field.close"].tap()
        XCTAssertTrue(waitGone(spaces))
    }

    // MARK: - editing, Back, a private tab's own field

    func testATapInTheSelectedAddressEditsItInPlace() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // A finger in the middle of the address: the caret goes there.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        input.typeText("x")
        let value = input.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("figma.com/") && value.contains("x") && value.count == "figma.com/design/xK29fLm8/Onboarding-v3".count + 1,
                      "one letter put inside the address: \(value)")
        XCTAssertNotEqual(value, "figma.com/design/xK29fLm8/Onboarding-v3")
    }

    func testDeleteOverTheSelectedAddressTakesAllOfIt() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String ?? "", input.placeholderValue ?? "", "the address is gone")
        input.typeText("hacker")
        XCTAssertEqual(input.value as? String, "hacker")
    }

    /// Typed over the selected address, the words are plain: its highlight
    /// went with it, not on to what was typed (it once stayed under them).
    func testWordsTypedOverTheSelectedAddressAreNotHighlighted() {
        let app = launch()
        element(app, "chrome.plate").tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(highlighted(input), 100, "the address shows selected")
        input.typeText("hacker news")
        XCTAssertEqual(input.value as? String, "hacker news")
        let left = highlighted(input)
        if left > 0 {
            let shot = XCTAttachment(screenshot: input.screenshot())
            shot.name = "highlighted words"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertEqual(left, 0, "the typed words drawn highlighted")
    }

    func testBackReturnsAfterASearchFromThePlate() {
        let app = launch()
        let plate = element(app, "chrome.plate")
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("lisbon weather october")
        key(app, "search").tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(waitFor(plate, label: "Google"), plate.label)
        element(app, "chrome.back").tap()
        XCTAssertTrue(waitFor(plate, label: "Figma", timeout: 8), "Back returns to the page before: \(plate.label)")
    }

    func testCloseOnSearchResultsLeavesTheSameResultsAndWorkingBack() {
        let app = launch()
        let plate = element(app, "chrome.plate")
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("lisbon weather october")
        key(app, "search").tap()
        XCTAssertTrue(waitGone(input))
        let result = app.webViews.staticTexts["lisbon weather october: what to expect"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "the local search results must actually load")
        plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let close = app.buttons["field.close"]
        XCTAssertEqual(close.label, "Close")
        close.tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(waitGone(app.keyboards.firstMatch))
        XCTAssertTrue(result.exists, "closing must keep the results page")
        plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5), "browser controls accept the next tap")
        close.tap()
        XCTAssertTrue(waitGone(input))
        element(app, "chrome.back").tap()
        XCTAssertTrue(waitFor(plate, label: "Figma", timeout: 8), "closing must preserve Back")
    }

    func testAPrivateTabsFieldOffersOnlyWhereTheWordsGo() {
        let app = launch(["-YabState", "privacy.4"])
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(waitFor(plate, label: "Google", timeout: 10))
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        // No page card (its actions are the menu's, 448423cb), and no eyes:
        // a private tab's field is private already (09c48e1c).
        XCTAssertFalse(element(app, "field.card").exists, "the page's card is gone")
        XCTAssertFalse(element(app, "field.eyes").exists, "no eyes over a private tab")
        // Behind it only Private's own page: nothing of Chats or the spaces,
        // whose tabs are public.
        let privatePage = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
                                                                                ["private.lock", "private.tabs", "private.empty"])).firstMatch
        XCTAssertTrue(privatePage.waitForExistence(timeout: 3), "Private's page stands behind a private tab's field")
        XCTAssertFalse(element(app, "newtab.chats").exists, "no Chats behind a private tab's field")
        XCTAssertFalse(element(app, "newtab.capsule").exists, "no spaces to page to over a private tab")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'newtab.space.'")).count, 0,
                       "no public space's tabs behind a private tab's field")
        XCTAssertEqual(input.label, "Address or private search")
        XCTAssertEqual(input.value as? String, "gift ideas for jonas", "the private Google page shows its search query")
        input.typeText("hacker")
        let best = element(app, "field.best")
        XCTAssertTrue(best.waitForExistence(timeout: 3))
        XCTAssertTrue(best.label.contains("Search Google · in this tab"), best.label)
        XCTAssertFalse(element(app, "field.row.1").exists, "no tabs, no Claude")
        best.tap()
        XCTAssertTrue(waitGone(input))
        XCTAssertTrue(waitFor(plate, label: "hacker"), plate.label)
        // Held, its menu has nothing of the agent's or the Mac's.
        plate.press(forDuration: 0.7)
        XCTAssertTrue(element(app, "plate.menu").waitForExistence(timeout: 3))
        for item in ["copy", "reader", "find", "share", "zoom", "desktop"] { XCTAssertTrue(element(app, "plate.menu.\(item)").exists, item) }
        for item in ["ask", "task", "onMac", "keep"] { XCTAssertFalse(element(app, "plate.menu.\(item)").exists, item) }
        element(app, "plate.menu.scrim").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitGone(element(app, "plate.menu")), "a tap beside closes the menu")
    }

    func testTheEyesOpenAgain() {
        let app = launch(["-YabState", "privacy.2"])
        let eyes = element(app, "field.eyes")
        XCTAssertTrue(eyes.waitForExistence(timeout: 10))
        XCTAssertEqual(eyes.value as? String, "on")
        eyes.tap()
        XCTAssertEqual(eyes.value as? String, "off")
        XCTAssertTrue(element(app, "newtab.card").waitForExistence(timeout: 2), "the history is back")
        XCTAssertTrue(haptics().contains("soft eyes"))
    }

    // MARK: - links from other apps

    private let lumen = URL(string: "yab-open://https%3A%2F%2Flumen.events%2Fe%2Fdesign-systems-night")!

    func testALinkFromAnotherAppOpensAsATab() {
        let app = launch()
        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 10))
        app.open(lumen)
        let shown = NSPredicate { _, _ in plate.label.contains("Lumen") }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: shown, evaluatedWith: nil)], timeout: 10), .completed, plate.label)
    }

    func testReduceMotionFadesWhatWouldMorph() {
        let app = launch(["-YabReduceMotion", "YES"], still: false)
        let plate = element(app, "chrome.plate")
        plate.press(forDuration: 0.7)
        XCTAssertTrue(element(app, "plate.menu").waitForExistence(timeout: 3))
        element(app, "plate.menu.scrim").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitGone(element(app, "plate.menu")))
        let ran = motionsRun()
        XCTAssertTrue(ran.contains("crossFade plateMenu"), "plateMenu fades: \(ran)")
        XCTAssertFalse(ran.contains("plateMenu"), "plateMenu doesn't morph: \(ran)")
    }
}
