import XCTest

/// Live chats on New Tab's Chats page and the Mac-style chat surfaces, with
/// default motion.
/// The live profile has no account, fixture world, or private keychain.
final class ChatPresentationTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-chat-presentation-\(UUID().uuidString)")
    }

    override func tearDown() {
        XCUIApplication().terminate()
        try? FileManager.default.removeItem(at: folder)
    }

    private func node(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-AX"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func live() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let later = app.buttons["welcome.start"]
        XCTAssertTrue(later.waitForExistence(timeout: 15))
        XCTAssertTrue(wait { later.isHittable })
        app.passWelcome()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the first run's New Tab field did not close by its ✕")
        // New Chat under the right button (15b7c3a0), then ‹, which goes to
        // New Tab's Chats page. The new chat, never asked, isn't listed.
        XCTAssertTrue(app.newChatFromPlus(), "New Chat under the right button did not open a chat")
        XCTAssertTrue(wait { node(app, "chat.history").isHittable })
        node(app, "chat.history").tap()
        XCTAssertTrue(wait { onChatsPage(app) }, "‹ did not go to the Chats page")
        return app
    }

    /// New Tab's Chats page in front, no chat over it, no keyboard.
    private func onChatsPage(_ app: XCUIApplication) -> Bool {
        app.canTouch(app.chatsPageNewChat) && !node(app, "chat.title").exists && !app.keyboards.firstMatch.exists
    }

    /// ‹ in a chat: into its row on the Chats page; ✕ folds the spaces back
    /// onto the browser.
    private func backThenClose(_ app: XCUIApplication) {
        node(app, "chat.history").tap()
        XCTAssertTrue(wait({ onChatsPage(app) }, timeout: 5), "‹ did not go to the Chats page")
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
        XCTAssertTrue(wait({ !node(app, "newtab.spaces").exists && node(app, "chrome.plate").exists }, timeout: 5))
    }

    private func create(_ count: Int, in app: XCUIApplication) {
        for index in 0..<count {
            app.chatsPageNewChat.tap()
            let field = app.textFields["chat.field"]
            XCTAssertTrue(wait { field.isHittable && app.keyboards.firstMatch.exists })
            field.typeText("Owned chat \(index + 1)")
            node(app, "chat.send").tap()
            XCTAssertTrue(wait { node(app, "chat.question").label == "Owned chat \(index + 1)" })
            XCTAssertTrue(wait { abs(node(app, "chat.history").frame.minY - 58) < 2 })
            node(app, "chat.history").tap()
            XCTAssertTrue(wait { onChatsPage(app) }, "‹ did not go to the Chats page")
        }
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery { app.chatsPageRows }

    func testLiveChatsAreListedOnTheChatsPageWithoutSelectingAConversation() {
        let app = live()
        XCTAssertEqual(rows(app).count, 0, "a new chat never asked is not listed")
        create(2, in: app)
        XCTAssertTrue(wait { self.rows(app).count == 2 })
        XCTAssertFalse(node(app, "chat.title").exists)
        record(app, "live-2-chats-on-the-chats-page")
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
        XCTAssertTrue(node(app, "chrome.plate").waitForExistence(timeout: 5))
    }

    func testMacStyleFaceNameMoreInfoAndArchiveUseTheSameConversation() {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", "chat.3", "-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        let face = node(app, "chat.face")
        let title = node(app, "chat.title")
        let more = node(app, "chat.more")
        let back = node(app, "chat.history")
        XCTAssertTrue(wait({ face.isHittable && title.isHittable && abs(face.frame.minY - 54) < 2 }, timeout: 15))
        XCTAssertEqual(face.frame.width, 44, accuracy: 1)
        XCTAssertEqual(more.frame.width, 44, accuracy: 1)
        XCTAssertEqual(back.frame.height, 44, accuracy: 1)
        XCTAssertFalse(node(app, "chat.close").exists, "no × in a chat: ‹ leaves it")
        XCTAssertFalse(node(app, "chat.line").exists, "who answers is said in Chat Info")
        let name = title.label
        record(app, "mac-style-native-chat-header")
        more.tap()
        let menuActions = app.collectionViews.buttons
        XCTAssertTrue(wait { menuActions.matching(identifier: "Chat Info").count == 1 && menuActions["Chat Info"].isHittable })
        for item in ["Rename Chat", "Copy Answer", "Archive Chat", "Chat Info"] {
            XCTAssertTrue(menuActions[item].isHittable)
        }
        record(app, "mac-style-native-chat-more")
        menuActions["Chat Info"].tap()
        XCTAssertTrue(wait { node(app, "chat.info.title").label == name && node(app, "chat.info.back").isHittable
            && abs(face.frame.width - 104) < 1 && abs(face.frame.height - 104) < 1 }, "Chat Info did not reach its full face geometry")
        XCTAssertFalse(app.textFields["chat.field"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(node(app, "chat.face").frame.width, 104, accuracy: 1)
        XCTAssertEqual(node(app, "chat.face").frame.height, 104, accuracy: 1)
        record(app, "mac-style-native-chat-info")
        node(app, "chat.info.back").tap()
        XCTAssertTrue(wait { title.label == name && app.textFields["chat.field"].exists })
        title.tap()
        XCTAssertTrue(wait { node(app, "chat.info").exists })
        // Telegram's profile: ✎ on the right, the model and when, a chip
        // saying where, four round actions, one card of rows.
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(node(app, "chat.info.line").label.hasPrefix("Claude Opus"), node(app, "chat.info.line").label)
        XCTAssertTrue(node(app, "chat.info.where").label.contains("on your Mac"))
        let rename = node(app, "chat.info.rename")
        XCTAssertTrue(rename.isHittable)
        XCTAssertEqual(rename.frame.maxX, window.maxX - 12, accuracy: 1, "✎ sits on the right")
        XCTAssertEqual(node(app, "chat.info.back").frame.minX, window.minX + 12, accuracy: 1, "‹ sits on the left")
        for id in ["chat.info.pin", "chat.info.unread", "chat.info.mac", "chat.info.archive"] { XCTAssertTrue(node(app, id).isHittable, id) }
        XCTAssertEqual((node(app, "chat.info.unread").frame.maxX + node(app, "chat.info.mac").frame.minX) / 2, window.midX, accuracy: 1,
                       "the actions stand evenly")
        XCTAssertTrue(node(app, "chat.info.copy").isHittable)
        XCTAssertTrue(node(app, "chat.info.page").label.contains("figma.com"))
        node(app, "chat.info.copy").tap()
        XCTAssertTrue(wait { node(app, "chat.info.copy").label.contains("Copied") }, "the row says Copied")
        rename.tap()
        XCTAssertTrue(wait { app.alerts["Rename Chat"].exists })
        app.alerts["Rename Chat"].buttons["Cancel"].tap()
        XCTAssertTrue(wait { !app.alerts["Rename Chat"].exists })
        node(app, "chat.info.archive").tap()
        XCTAssertTrue(wait { onChatsPage(app) && !node(app, "chat.info").exists }, "Archive goes to the Chats page")
        let row = app.chatsPageRows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(wait { !row.exists }, "archived, it left the page's rows")
        let archive = node(app, "field.archive")
        XCTAssertTrue(wait { archive.isHittable })
        archive.tap()
        XCTAssertTrue(wait { row.exists && row.isHittable }, "the archive at the field's left keeps it")
        record(app, "mac-style-archived-chat-retained")
    }

    func testLiveInfoBackRestoresTheSameDraftAndActualKeyboard() {
        let app = live()
        create(1, in: app)
        rows(app).firstMatch.tap()
        let field = app.textFields["chat.field"]
        XCTAssertTrue(wait { field.isHittable && abs(node(app, "chat.history").frame.minY - 58) < 2 })
        field.tap()
        field.typeText("Unsent native draft")
        node(app, "chat.title").tap()
        XCTAssertTrue(wait { node(app, "chat.info").exists && !app.keyboards.firstMatch.exists })
        record(app, "live-info-preserves-conversation")
        node(app, "chat.info.back").tap()
        XCTAssertTrue(wait { field.isHittable && app.keyboards.firstMatch.exists })
        XCTAssertEqual(field.value as? String, "Unsent native draft")
        record(app, "live-info-back-restored-draft-keyboard")
        backThenClose(app)
    }

    func testNativeInfoZoomCancelThenDismissRestoresTheSameDraftAndKeyboard() {
        let app = live(); create(1, in: app); rows(app).firstMatch.tap()
        let field = app.textFields["chat.field"]
        XCTAssertTrue(wait({ field.isHittable && node(app, "chat.face").isHittable }, timeout: 5))
        let title = node(app, "chat.title").label
        field.tap(); field.typeText("Unsent interactive draft")
        node(app, "chat.title").tap()
        XCTAssertTrue(wait({ node(app, "chat.info.back").isHittable && !app.keyboards.firstMatch.exists }, timeout: 5))
        XCTAssertEqual(node(app, "chat.face").frame.width, 104, accuracy: 1)
        let window = app.windows.firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - window.frame.minX, dy: y - window.frame.minY))
        }
        // The system zoom recognizer, on unused header space, not a scroll row.
        let start = point(window.frame.maxX - 72, window.frame.minY + 112)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 18, dy: 54)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(wait({ node(app, "chat.info.back").isHittable && node(app, "chat.info.title").label == title }, timeout: 5))
        XCTAssertFalse(field.isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        record(app, "native-info-cancelled-interactive-zoom")
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 48, dy: 540)),
                    withVelocity: .fast, thenHoldForDuration: 0.05)
        // iOS's zoom decides on the finger's speed; a synthesized drag on a
        // loaded farm Mac sometimes ends slow and the page springs back
        // (farm 1053b79b2a834b33), so one more drag, as a person would.
        if wait({ !node(app, "chat.info").exists }, timeout: 3) == false, node(app, "chat.info.back").isHittable {
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 48, dy: 540)),
                        withVelocity: .fast, thenHoldForDuration: 0.05)
        }
        XCTAssertTrue(wait({ !node(app, "chat.info").exists && field.isHittable && app.keyboards.firstMatch.exists }, timeout: 5))
        XCTAssertEqual(node(app, "chat.title").label, title)
        XCTAssertEqual(field.value as? String, "Unsent interactive draft")
        XCTAssertEqual(node(app, "chat.face").frame.width, 44, accuracy: 1)
        record(app, "native-info-completed-zoom-restored-draft")
        backThenClose(app)
    }

    func testActualHeaderPullKeepsTheChatAndAnEdgeSwipeGoesToTheChatsPage() {
        let app = live(); create(1, in: app); rows(app).firstMatch.tap()
        XCTAssertTrue(wait({ node(app, "chat.history").isHittable }, timeout: 5))
        let title = node(app, "chat.title").label, window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width * 0.28, dy: 82))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertTrue(wait({ node(app, "chat.title").label == title && node(app, "chat.history").isHittable
            && abs(node(app, "chat.history").frame.minY - 58) < 2 }, timeout: 5), "a pull down moved the chat page")
        record(app, "actual-chat-pull-kept-full-page")
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        edge.press(forDuration: 0.05, thenDragTo: edge.withOffset(CGVector(dx: window.frame.width * 0.7, dy: 0)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait({ onChatsPage(app) && !node(app, "chat.history").exists }, timeout: 5),
                      "the edge swipe did not go to the Chats page")
        XCTAssertEqual(rows(app).count, 1); record(app, "actual-chat-edge-to-chats-page")
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
        XCTAssertTrue(wait({ !node(app, "newtab.spaces").exists && node(app, "chrome.plate").exists }, timeout: 5))
        // Chats again from the page: the spaces' Chats page (b3e8fe50) lists
        // the one chat and stands none of them up.
        XCTAssertTrue(app.openChatsPage(), "the spaces' Chats page did not come")
        XCTAssertFalse(node(app, "chat.field").exists); XCTAssertFalse(node(app, "chat.title").exists)
        XCTAssertEqual(app.chatsPageRows.count, 1); record(app, "actual-reopened-chats-stays-list-after-gesture-close")
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
        XCTAssertTrue(wait({ !node(app, "newtab.spaces").exists && node(app, "chrome.plate").exists }, timeout: 5))
    }
}
