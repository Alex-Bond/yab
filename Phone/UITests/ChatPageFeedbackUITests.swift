import SyncKit
import UIKit
import XCTest

/// Real production chats reached through encrypted owned records and finger
/// input. Render words are fixtures; this does not run or certify a provider.
final class ChatPageFeedbackUITests: XCTestCase {
    private var folder: URL!
    private var site: ChatWireSite!
    private var app: XCUIApplication!
    private let chat = "a:owned-readable-chat"
    private let title = "Owned readable chat"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Under /private/tmp, for production sync: the app takes a test's
        // own sync key only from a profile there or in its own tmp
        // (SyncBridge), and this runner's tmp is neither, so the key was
        // never read and the iPhone stood joining with a code.
        folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("yab-chat-page-ui-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        site = try ChatWireSite(chat: chat)
        let ready = expectation(description: "owned chat sync ready")
        site.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        XCTAssertTrue(site.ready)
        site.useMagentaPage()
        let keys = folder.appendingPathComponent("Sync-test/keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try site.seal.raw.write(to: keys.appendingPathComponent("key"), options: .atomic)
        try Data("owned-phone".utf8).write(to: keys.appendingPathComponent("device"), options: .atomic)
    }

    override func tearDownWithError() throws {
        app?.terminate(); site?.stop(); site = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func record(_ name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let image = XCTAttachment(screenshot: screenshot)
        image.name = name; image.lifetime = .keepAlways; add(image)
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = name + "-AX"; ax.lifetime = .keepAlways; add(ax)
        return screenshot
    }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        let window = app.windows.firstMatch
        return window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
    }
    /// A chat opened from the spaces' Chats page closes back there: ‹
    /// shrinks it into its row (b3e8fe50), then ✕ folds the spaces into the plate.
    private func closeChat() {
        backToChatsPage()
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
    }

    /// ‹ in the chat: the spaces' Chats page under it again, keyboard down.
    private func backToChatsPage() {
        tap(app.buttons["chat.history"])
        XCTAssertTrue(wait { self.app.chatsPageNewChat.isHittable && !self.element("chat.title").exists
            && !self.app.keyboards.firstMatch.exists }, "‹ did not take the chat back into the Chats page")
    }

    private func tap(_ control: XCUIElement) {
        XCTAssertTrue(wait { control.exists && control.isHittable })
        let frame = control.frame
        // 44 as laid out: a frame read back can be 43.99999999999999.
        XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.01)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame))
        point(frame.midX, frame.midY).tap()
    }
    private func launch(large: Bool = false, film: URL? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabSync", site.base.absoluteString,
                               "-YabURL", site.base.appendingPathComponent("owned-page").absoluteString,
                               "-YabNoAnim", "NO", "-settings.welcomed", "YES"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        if let film {
            app.launchEnvironment["YAB_FRAMEMETER"] = "1"
            app.launchEnvironment["YAB_FILM_MARK"] = film.appendingPathComponent("recording").path
            app.launchEnvironment["YAB_PERF_OUT"] = film.appendingPathComponent("frames.jsonl").path
        }
        app.terminate(); app.launch()
        // The owned key on disk is an iPhone that joined, so it passed the
        // welcome (-settings.welcomed above). Without that the welcome comes
        // up when the key hasn't joined by the first frame and stays until
        // answered (FirstLaunch.shows), and its only answer here, Use Without
        // a Mac, stops the join the test needs.
        XCTAssertTrue(wait { self.element("chrome.plate").exists })
        XCTAssertFalse(app.alerts["welcome"].exists, "the welcome came over a joined iPhone")
        let input = app.textFields["field.input"]
        if input.exists { XCTAssertTrue(app.closeField()) }
        // The same real WK page is exposed to XCTest at the application level,
        // as in the existing ChatWireSite production UI helper.
        let browserReady = wait { !input.exists && self.element("chrome.plate").exists
            && self.app.staticTexts["Owned page"].exists && self.app.buttons["Owned page action"].isHittable
            && self.site.phoneRegistered }
        if !browserReady {
            _ = record("owned-chat-browser-startup-before-original-ready-failure")
            let parts = XCTAttachment(string: "field \(input.exists) plate \(element("chrome.plate").exists) "
                + "words \(app.staticTexts["Owned page"].exists) action \(app.buttons["Owned page action"].exists)/"
                + "\(app.buttons["Owned page action"].isHittable) registered \(site.phoneRegistered)")
            parts.name = "owned-chat-browser-startup-parts"; parts.lifetime = .keepAlways; add(parts)
        }
        XCTAssertTrue(browserReady)
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.base.appendingPathComponent("owned-page").absoluteString })
        _ = record("owned-magenta-browser-before-chat")
    }
    /// The synced chat from the page: the plate swiped up to the spaces,
    /// their Chats page, its row (the column's Chats button went, aaf8443d).
    private func openChat() {
        let plate = element("chrome.plate")
        XCTAssertTrue(wait { plate.exists && plate.frame.width > 0 })
        XCTAssertTrue(app.openChatsPage(), "the spaces' Chats page did not come")
        openRow()
    }

    /// The chat's row on the Chats page grows into the chat.
    private func openRow() {
        let row = element("newtab.chat.\(chat)")
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(wait { row.isHittable }); row.tap()
        XCTAssertTrue(wait { self.element("chat.title").exists && self.element("chat.title").label == self.title
            && self.element("chat.history").isHittable && self.element("chat.body").exists })
    }
    private func markdown(long: Bool = false) -> String {
        let start = "# Readable heading\n\n**Bold answer** and `inline code` read without formatting marks.\n\n- First readable bullet\n- Second readable bullet\n\n```swift\nlet ownedValue = 7\n```\n\n| Name | Value |\n| --- | --- |\n| Native | **Readable** |"
        let body = long ? (0..<6).map { "## Owned section \($0)\n\nOwned paragraph \($0). This readable text wraps at the largest accessibility size and continues under the actual header and input. **Native emphasis** stays readable while the real scroller moves." }.joined(separator: "\n\n") : ""
        return start + "\n\n" + body + "\n\n[Owned browser source](\(site.base.appendingPathComponent("owned-page").absoluteString))\n\nOwned final readable turn"
    }
    private func moveBody(up: Bool) {
        let body = element("chat.body"), frame = body.frame
        XCTAssertTrue(body.exists); XCTAssertGreaterThan(frame.height, 300)
        let start = point(frame.midX, up ? min(frame.maxY - 150, 690) : max(frame.minY + 200, 220))
        let end = point(frame.midX, up ? max(frame.minY + 200, 220) : min(frame.maxY - 150, 690))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
    }
    private func visible(_ control: XCUIElement, below: CGFloat = 152, above: CGFloat? = nil) -> Bool {
        guard control.exists, control.isHittable else { return false }
        let frame = control.frame
        return frame.height > 0 && frame.minY >= below && frame.maxY <= (above ?? app.textFields["chat.field"].frame.minY)
    }
    private func showTop() {
        let heading = app.staticTexts["Readable heading"]
        for _ in 0..<10 where !visible(heading) { moveBody(up: false) }
        XCTAssertTrue(wait { self.visible(heading) })
    }
    private func showLast() {
        let last = app.staticTexts["Owned final readable turn"]
        for _ in 0..<10 where !visible(last) { moveBody(up: true) }
        XCTAssertTrue(wait { self.visible(last) }, "the actual final turn must be reachable above the input")
    }
    private func openMenu() {
        tap(app.buttons["chat.more"])
        XCTAssertTrue(wait({ self.app.buttons["Copy Answer"].isHittable && self.app.buttons["Archive Chat"].isHittable }, timeout: 5))
        // Nothing of Yab's says Delete; the keyboard's own delete key may stand under a new chat's menu.
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'delete' AND elementType != %lu",
                                                                           XCUIElement.ElementType.key.rawValue)).firstMatch.exists)
    }
    private func dismissMenu() {
        point(6, 300).tap()
        XCTAssertTrue(wait { !self.app.buttons["Copy Answer"].exists && self.app.buttons["chat.more"].isHittable })
    }
    private func profile() throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func savedTab() -> [String: Any]? {
        guard let profile = try? profile(), let spaces = profile["spaces"] as? [[String: Any]] else { return nil }
        for space in spaces {
            guard let id = space["current"] as? String, let tabs = space["today"] as? [[String: Any]] else { continue }
            if let tab = tabs.first(where: { $0["id"] as? String == id }) { return tab }
        }
        return nil
    }
    private func navigation(_ id: String) throws -> [String] {
        let all = try XCTUnwrap(profile()["navigation"] as? [String: Any])
        let state = try XCTUnwrap(all[id] as? [String: Any])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(state["index"] as? Int)
        return entries.compactMap { $0["url"] as? String } + ["index=\(index)"]
    }
    private func opaqueSides(_ screenshot: XCUIScreenshot, bottom: CGFloat = 850, green: UInt8 = 225) throws {
        let image = screenshot.image, cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))); return true
        }
        XCTAssertTrue(drawn)
        let window = app.windows.firstMatch.frame
        // XCTest excludes the prediction row from Keyboard.frame on iOS 26.4.
        let predictions = app.otherElements["Typing Predictions"]
        let bottom = predictions.exists ? min(bottom, predictions.frame.minY - 2) : bottom
        for point in [CGPoint(x: window.minX + 2, y: 100), CGPoint(x: window.maxX - 2, y: 100),
                      CGPoint(x: window.minX + 2, y: bottom), CGPoint(x: window.maxX - 2, y: bottom)] {
            let x = min(cg.width - 1, max(0, Int(point.x * image.scale)))
            let y = min(cg.height - 1, max(0, Int(point.y * image.scale)))
            let offset = (y * cg.width + x) * 4
            XCTAssertGreaterThan(bytes[offset + 1], green, "the owned magenta browser is visible through the full page at \(point)")
            XCTAssertLessThan(abs(Int(bytes[offset]) - Int(bytes[offset + 1])), 12)
        }
    }
    private func returnedPage(_ id: String, history: [String]) throws {
        XCTAssertTrue(wait { !self.element("chat.title").exists
            && !self.app.keyboards.firstMatch.exists && self.element("chrome.plate").exists
            && self.app.buttons["Owned page action"].isHittable })
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, site.base.appendingPathComponent("owned-page").absoluteString)
        XCTAssertEqual(try navigation(id), history)
        app.buttons["Owned page action"].tap()
        XCTAssertTrue(app.buttons["Owned page touch worked"].waitForExistence(timeout: 5))
        XCTAssertTrue(site.sends.isEmpty, "unsent drafts and rendering must not dispatch a provider command")
        XCTAssertTrue(site.failures.isEmpty)
        _ = record("returned-owned-browser-real-touch-history")
    }

    func testActualFullMarkdownPageNativeMenuArchiveNewChatAndKeyboardPreserveTheBrowser() throws {
        try site.transcript(markdown(), title: title)
        launch(); let id = try XCTUnwrap(savedTab()?["id"] as? String), history = try navigation(id)
        openChat(); showTop()
        let markdownPage = record("real-chat-full-opaque-native-markdown")
        XCTAssertTrue(app.staticTexts["Readable heading"].exists)
        XCTAssertFalse(app.staticTexts["# Readable heading"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '**Bold answer**'")).firstMatch.exists)
        // The code block and the table keep their own identifiers inside
        // the answer's "chat.answer" (TurnsView, ChatMarkdown).
        XCTAssertTrue(element("chat.answer").exists, "the answer keeps its own identifier")
        let code = app.scrollViews["chat.code"]
        XCTAssertTrue(code.exists, "the code block is not its own horizontal scroller named chat.code")
        XCTAssertTrue(code.staticTexts["let ownedValue = 7"].exists, "the code block holds its code")
        let table = element("chat.table")
        XCTAssertTrue(table.exists, "the table is not named chat.table")
        XCTAssertTrue(table.staticTexts["Native"].exists, "the table holds its cells")
        let cell = app.staticTexts["Native"], value = app.staticTexts["Readable"]
        XCTAssertTrue(cell.exists && value.exists && app.staticTexts["Value"].exists, "the table's cells are missing")
        XCTAssertEqual(cell.frame.midY, value.frame.midY, accuracy: 1, "a table row stands on one line")
        XCTAssertEqual(value.frame.minX, app.staticTexts["Value"].frame.minX, accuracy: 1, "a value stands under its column")
        XCTAssertFalse(app.staticTexts["**Readable**"].exists)
        try opaqueSides(markdownPage)
        openMenu(); _ = record("real-chat-native-menu-source-and-items")
        app.buttons["Copy Answer"].tap()
        XCTAssertTrue(wait { !self.app.buttons["Copy Answer"].exists && self.element("chrome.toast").label.contains("Copied") })
        openMenu(); app.buttons["Pin Chat"].tap()
        XCTAssertTrue(wait { !self.app.buttons["Pin Chat"].exists })
        openMenu(); XCTAssertTrue(app.buttons["Unpin Chat"].isHittable); dismissMenu()
        showLast()
        let field = app.textFields["chat.field"]
        XCTAssertTrue(field.isHittable); field.tap(); field.typeText("Owned follow-up draft")
        XCTAssertTrue(wait { self.app.keyboards.firstMatch.exists && field.frame.maxY < self.app.keyboards.firstMatch.frame.minY })
        XCTAssertEqual(field.value as? String, "Owned follow-up draft")
        try opaqueSides(record("real-full-follow-up-keyboard-no-bottom-corners"), bottom: app.keyboards.firstMatch.frame.minY - 2)
        backToChatsPage()
        openRow()
        XCTAssertTrue(wait { self.app.textFields["chat.field"].value as? String == "Owned follow-up draft" })
        openMenu(); app.buttons["Archive Chat"].tap()
        // Archived, the chat goes back into the Chats page it came from, its row gone.
        XCTAssertTrue(wait { self.app.chatsPageNewChat.isHittable && !self.element("chat.title").exists })
        XCTAssertFalse(element("newtab.chat.\(chat)").exists)
        // The page's own light wash, never the magenta browser under it.
        try opaqueSides(record("real-chats-page-opaque-after-archive"), green: 200)
        tap(app.chatsPageNewChat)
        XCTAssertTrue(wait { self.element("chat.title").label == "New Chat" && self.app.keyboards.firstMatch.exists })
        XCTAssertFalse(element("chat.answer").exists)
        try opaqueSides(record("real-new-chat-full-page-before-send-with-keyboard"), bottom: app.keyboards.firstMatch.frame.minY - 2)
        openMenu(); _ = record("real-new-owner-native-menu-after-archive")
        dismissMenu(); XCTAssertEqual(element("chat.title").label, "New Chat")
        closeChat()
        try returnedPage(id, history: history)
    }

    func testLargestActualMarkdownScrollerReachesItsFinalTurnAndNativeWebsiteLink() throws {
        try site.transcript(markdown(long: true), title: title)
        launch(large: true); let id = try XCTUnwrap(savedTab()?["id"] as? String), history = try navigation(id)
        openChat()
        let body = element("chat.body"), screen = app.windows.firstMatch.frame
        // Out of its row the chat settles on a spring: wait for the whole page.
        let whole = wait { body.frame.minY <= screen.minY + 1 && body.frame.maxY >= screen.maxY - 1 }
        if !whole { _ = record("real-largest-chat-not-whole-page") }
        XCTAssertLessThanOrEqual(body.frame.minY, screen.minY + 1)
        XCTAssertGreaterThanOrEqual(body.frame.maxY, screen.maxY - 1)
        showLast()
        try opaqueSides(record("real-largest-chat-final-turn-under-input"))
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Owned browser source")).firstMatch
        for _ in 0..<3 where !visible(link) { moveBody(up: false) }
        XCTAssertTrue(wait { self.visible(link) })
        let last = app.staticTexts["Owned final readable turn"]
        XCTAssertLessThanOrEqual(link.frame.maxY, last.frame.minY)
        _ = record("real-largest-chat-actionable-native-link")
        link.tap()
        try returnedPage(id, history: history)
    }

    /// The existing farm film protocol can record this exact default-motion
    /// native source menu, scroll, keyboard and opaque-page path.
    func testFilmActualChatPageMenuAndScrollWithDefaultMotion() throws {
        let film = Atlas.environment["YAB_FILM_CHAT_PAGE"] == "1" ? Atlas.out.appendingPathComponent("film", isDirectory: true) : nil
        if let film {
            try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
            for name in ["ready", "recording", "done"] { try? FileManager.default.removeItem(at: film.appendingPathComponent(name)) }
        }
        try site.transcript(markdown(long: true), title: title)
        launch(film: film); let id = try XCTUnwrap(savedTab()?["id"] as? String), history = try navigation(id)
        openChat(); showLast()
        if let film {
            try Data().write(to: film.appendingPathComponent("ready"))
            XCTAssertTrue(Atlas.waitForFile(film.appendingPathComponent("recording"), timeout: 30))
        }
        _ = record("chat-page-film-source-before-native-menu")
        let start = Date()
        openMenu(); let touched = Date()
        _ = record("chat-page-film-native-menu-expanded")
        dismissMenu()
        _ = record("chat-page-film-source-after-native-menu-reverse")
        showTop(); showLast()
        _ = record("chat-page-film-returned-last-turn-scroll-anchor")
        let field = app.textFields["chat.field"]
        XCTAssertTrue(field.isHittable); field.tap(); field.typeText("Owned movie draft")
        XCTAssertTrue(wait { self.app.keyboards.firstMatch.exists && field.frame.maxY < self.app.keyboards.firstMatch.frame.minY })
        try opaqueSides(record("chat-page-film-full-keyboard-bottom"), bottom: app.keyboards.firstMatch.frame.minY - 2)
        closeChat()
        try returnedPage(id, history: history)
        if let film {
            try Atlas.json(["transition": "chatPage", "state": "owned real synced transcript", "noAnimation": false,
                            "start": start.timeIntervalSince1970, "touched": touched.timeIntervalSince1970,
                            "arrived": Date().timeIntervalSince1970, "ok": true]).write(to: film.appendingPathComponent("done"))
        }
    }

    /// A real continuation is committed to this test's encrypted loopback
    /// account. There is no Mac consumer, acknowledgement or provider answer.
    /// The optional native film records the hidden flight; AX frames establish
    /// the actual window field and settled bubble, not its intermediate paint.
    func testActualDefaultMotionFollowUpSendCommitsOnlyToOwnedLoopbackAndReturnsToTheBrowser() throws {
        let film = Atlas.environment["YAB_FILM_CHAT_SEND"] == "1" ? Atlas.out.appendingPathComponent("film", isDirectory: true) : nil
        if let film {
            try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
            for name in ["ready", "recording", "done"] { try? FileManager.default.removeItem(at: film.appendingPathComponent(name)) }
        }
        try site.transcript(markdown(long: true), title: title)
        launch(film: film)
        let id = try XCTUnwrap(savedTab()?["id"] as? String), history = try navigation(id)
        openChat(); showLast()
        let words = "Owned follow-up flight"
        let questions = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "chat.question", words))
        XCTAssertEqual(questions.count, 0)
        XCTAssertTrue(site.sends.isEmpty)
        let field = app.textFields["chat.field"]
        XCTAssertTrue(field.isHittable); field.tap(); field.typeText(words)
        let send = app.buttons["chat.send"], keyboard = app.keyboards.firstMatch
        XCTAssertTrue(wait { field.value as? String == words && keyboard.exists
            && field.frame.maxY < keyboard.frame.minY && send.isHittable && send.isEnabled })
        let window = app.windows.firstMatch.frame, fieldSource = field.frame, sendSource = send.frame
        XCTAssertGreaterThan(fieldSource.width, 0); XCTAssertGreaterThan(fieldSource.height, 0)
        XCTAssertTrue(window.contains(fieldSource))
        XCTAssertGreaterThanOrEqual(sendSource.width, 44); XCTAssertGreaterThanOrEqual(sendSource.height, 44)
        XCTAssertTrue(window.contains(sendSource))
        // These exact constants are protected production Metrics.Chat values.
        // This derived source is diagnostic geometry, not a fake flight AX node.
        let sourceFormula = CGRect(x: fieldSource.minX - 2, y: fieldSource.midY - 19,
                                   width: min(fieldSource.width, 300), height: 38)
        XCTAssertTrue(window.contains(sourceFormula))
        try opaqueSides(record("chat-send-real-window-field-keyboard-before-finger"), bottom: keyboard.frame.minY - 2)
        if let film {
            try Data().write(to: film.appendingPathComponent("ready"))
            XCTAssertTrue(Atlas.waitForFile(film.appendingPathComponent("recording"), timeout: 30))
        }
        let start = Date()
        point(sendSource.midX, sendSource.midY).tap()
        let touched = Date() // XCTest returned from the genuine center tap.
        let bubble = questions.firstMatch
        XCTAssertTrue(wait { self.site.sends.count == 1 && questions.count == 1
            && self.visible(bubble) && self.element("chat.typing").exists
            && keyboard.exists && field.frame.maxY < keyboard.frame.minY })
        let arrived = Date() // First strict settled native/transport receipt.
        let target = bubble.frame, body = element("chat.body").frame
        XCTAssertTrue(window.contains(target)); XCTAssertTrue(body.contains(target))
        XCTAssertGreaterThan(target.width, 0); XCTAssertGreaterThan(target.height, 0)
        XCTAssertLessThanOrEqual(target.maxY, field.frame.minY)
        XCTAssertLessThan(target.maxY, sourceFormula.minY)
        XCTAssertEqual(field.frame.minX, fieldSource.minX, accuracy: 1)
        XCTAssertEqual(field.frame.minY, fieldSource.minY, accuracy: 1)
        let empty = field.value as? String
        XCTAssertTrue(empty == nil || empty == "" || empty == field.placeholderValue)

        func waitingSend() throws -> Record {
            XCTAssertEqual(site.sends.count, 1)
            let record = try XCTUnwrap(site.sends.first)
            XCTAssertEqual(record.collection, "send"); XCTAssertTrue(record.alive())
            XCTAssertEqual(record["device"]?.string, "owned-mac")
            XCTAssertEqual(record["clientDevice"]?.string, "owned-phone")
            XCTAssertEqual(record["clientChat"]?.string, chat)
            XCTAssertEqual(record["chat"]?.string, chat)
            XCTAssertEqual(record["question"]?.string, words)
            XCTAssertEqual(record["text"]?.string, words)
            for key in ["kind", "project", "cli", "agentText", "url", "choice", "choiceQuestion", "answerIndex",
                        "state", "took", "reason"] {
                XCTAssertNil(record[key], "a continuation must remain waiting without a fabricated Mac effect: \(key)")
            }
            XCTAssertTrue(site.failures.isEmpty)
            return record
        }
        let sent = try waitingSend()
        func rect(_ value: CGRect) -> [String: Double] {
            ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
        }
        let geometry: [String: Any] = ["schema": 1, "noAnimation": false, "window": rect(window),
            "actualFieldBeforeSend": rect(fieldSource), "actualSendControl": rect(sendSource),
            "sourceFromProtectedProductionFormula": rect(sourceFormula), "actualSettledQuestionBubble": rect(target),
            "actualTranscript": rect(body), "actualKeyboard": rect(keyboard.frame), "sendCount": site.sends.count,
            "onlyOwnedContinuation": true, "macAcknowledged": false, "providerExecuted": false,
            "intermediateFlightRequiresNativeFilmReview": true]
        let data = try Atlas.json(geometry)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "chat-send-actual-window-source-settled-target-and-waiting-wire"; attachment.lifetime = .keepAlways; add(attachment)
        if let film { try data.write(to: film.appendingPathComponent("send-geometry.json")) }
        try opaqueSides(record("chat-send-settled-real-bubble-pending-no-provider-answer"), bottom: keyboard.frame.minY - 2)

        backToChatsPage()
        openRow()
        XCTAssertTrue(wait { questions.count == 1 && self.visible(bubble) })
        XCTAssertEqual(try waitingSend(), sent, "Back and reopening must not rewrite or repeat the real command")
        _ = record("chat-send-reopened-same-pending-question-once")
        closeChat()
        XCTAssertTrue(wait { !self.element("chat.title").exists
            && !keyboard.exists && self.element("chrome.plate").exists && self.app.buttons["Owned page action"].isHittable })
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, site.base.appendingPathComponent("owned-page").absoluteString)
        XCTAssertEqual(try navigation(id), history)
        app.buttons["Owned page action"].tap()
        XCTAssertTrue(app.buttons["Owned page touch worked"].waitForExistence(timeout: 5))
        XCTAssertEqual(try waitingSend(), sent)
        _ = record("chat-send-returned-real-page-touch-and-original-history")
        if let film {
            try Atlas.json(["transition": "chatSend", "state": "owned waiting continuation; no provider",
                            "noAnimation": false, "start": start.timeIntervalSince1970,
                            "touched": touched.timeIntervalSince1970, "arrived": arrived.timeIntervalSince1970,
                            "returned": Date().timeIntervalSince1970, "ok": true]).write(to: film.appendingPathComponent("done"))
        }
    }

}
