import XCTest

/// Chat dismissal through actual controls and header touches, including a
/// fresh live profile. The live tests use no world, keychain or remote account.
final class ChatExitTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("yab-chat-exit-\(UUID().uuidString)")
    }

    override func tearDown() {
        XCUIApplication().terminate()
        try? FileManager.default.removeItem(at: folder)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
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
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-AX"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func fixture(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state, "-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let target = element(app, "chat.title")
        let ready = wait({ target.exists && target.isHittable }, timeout: 15)
        record(app, "fixture-startup-" + state)
        XCTAssertTrue(ready, "the requested fixture chat state did not launch")
        XCTAssertFalse(app.alerts["welcome"].exists, "Welcome is covering the requested fixture")
        XCTAssertFalse(app.alerts["join.sheet"].exists, "Join is covering the requested fixture")
        return app
    }

    private func live() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.start"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 10))
        let ready = wait { notNow.isHittable }
        record(app, "live-startup")
        XCTAssertTrue(ready, "the isolated live Welcome is not ready for its Not Now action")
        XCTAssertFalse(app.alerts["join.sheet"].exists, "an isolated live launch must not connect an account")
        app.passWelcome()
        XCTAssertTrue(wait { !app.alerts["welcome"].exists })
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.closeField(), "the first run's New Tab field did not close by its ✕")
        return app
    }

    /// ‹ (or a finger from the edge) took the chat into its row on New
    /// Tab's Chats page; ✕ there folds the spaces back onto the page.
    private func backOnTheChatsPage(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(wait { app.canTouch(app.chatsPageNewChat) && !self.element(app, "chat.title").exists
            && !app.keyboards.firstMatch.exists }, "the chat did not go back to New Tab's Chats page")
        XCTAssertFalse(element(app, "chats.now").exists, "ordinary conversations return to Chats")
        record(app, name)
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
    }

    /// Chats reopened from a page, the spaces' Chats page (b3e8fe50): it
    /// lists the chats and never stands up the one kept in the sheet. ✕
    /// folds the spaces back.
    private func reopenChats(_ app: XCUIApplication, _ name: String) {
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(app.openChatsPage(), "the spaces' Chats page did not come")
        XCTAssertFalse(element(app, "chat.title").exists, "opening Chats selected a conversation")
        XCTAssertGreaterThan(app.chatsPageRows.count, 0, "the kept conversation is not on the Chats page")
        record(app, name)
        XCTAssertTrue(app.closeField(), "✕ did not fold the spaces back")
    }

    private func tapFinger(_ app: XCUIApplication, _ control: XCUIElement) {
        XCTAssertTrue(wait { control.exists && control.isHittable })
        let window = app.windows.firstMatch
        let frame = control.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)).tap()
    }

    private func liveConversationWithKeyboard(_ app: XCUIApplication) {
        openLiveNewChat(app)
        let field = app.textFields["chat.field"]
        XCTAssertTrue(wait { field.isHittable })
        // This owned live profile has no account. The local question can
        // create its real bubble while the unavailable Mac reports an error.
        field.typeText("A local chat exit test")
        tapFinger(app, element(app, "chat.send"))
        XCTAssertTrue(wait { self.element(app, "chat.history").isHittable })
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(element(app, "chat.question").label.contains("A local chat exit test"))
    }

    /// A new chat from a page: New Chat under the right button (15b7c3a0).
    private func openLiveNewChat(_ app: XCUIApplication) {
        XCTAssertTrue(wait { !app.keyboards.firstMatch.exists })
        XCTAssertTrue(app.newChatFromPlus(), "New Chat under the right button did not open a chat")
        XCTAssertEqual(element(app, "chat.title").label, "New Chat")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    private func pullHeader(_ app: XCUIApplication, y: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width / 2, dy: y))
        let end = start.withOffset(CGVector(dx: 0, dy: 240))
        start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// A finger from the left edge takes the chat back into its row.
    private func edgePop(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: window.frame.width * 0.7, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func pageReturned(_ app: XCUIApplication) {
        XCTAssertTrue(wait { !self.element(app, "chat.history").exists && !self.element(app, "chat.close").exists
            && !self.element(app, "chat.title").exists }, "the chat controls stayed on screen")
        let plate = element(app, "chrome.plate")
        let window = app.windows.firstMatch
        XCTAssertTrue(wait { plate.exists && plate.frame.width > 0 && plate.frame.height > 0
            && window.frame.contains(plate.frame) }, "the page's plate did not return to its visible frame")
        let retainedLabel = plate.label
        let page = app.webViews.firstMatch
        let firstWord = page.staticTexts.firstMatch
        let retainedWord = firstWord.exists ? firstWord.label : nil
        record(app, "page-after-exit-before-center-touch")
        XCTContext.runActivity(named: "Returned plate center: \(plate.frame), AX hittable: \(plate.isHittable)") { _ in
            let frame = plate.frame
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY)).tap()
        }
        let input = app.textFields["field.input"]
        let opened = input.waitForExistence(timeout: 5)
        record(app, "page-after-exit-after-center-touch")
        XCTAssertTrue(opened, "a real center touch on the returned plate cannot open its field")
        // The plate's field stands in the space's card, whose rows fill the
        // screen around it: a tap beside it would choose a tab (65619b17).
        XCTAssertTrue(app.closeField(), "the returned field did not close by its ✕")
        XCTAssertTrue(wait { !input.exists && plate.exists })
        XCTAssertEqual(plate.label, retainedLabel, "opening the returned field changed the selected page")
        if let retainedWord {
            XCTAssertTrue(page.staticTexts[retainedWord].exists, "the returned field replaced the actual page")
        }
    }

    func testFixtureConversationEdgeSwipeGoesToTheChatsPageThenReturnsToThePage() {
        let app = fixture("chat.3")
        record(app, "fixture-card-before-drag")
        edgePop(app)
        backOnTheChatsPage(app, "fixture-card-after-drag-to-chats-page")
        pageReturned(app)
    }

    func testLiveNewChatBackThenCloseReturnsToThePageWithTheKeyboard() {
        let app = live()
        openLiveNewChat(app)
        XCTAssertFalse(element(app, "chat.close").exists, "a chat has no ×: ‹ leaves it")
        record(app, "live-new-card-before-back")
        tapFinger(app, element(app, "chat.history"))
        backOnTheChatsPage(app, "live-new-card-after-back")
        pageReturned(app)
    }

    func testLiveNewChatEdgeSwipeGoesToTheChatsPageThenReturnsToThePageWithTheKeyboard() {
        let app = live()
        openLiveNewChat(app)
        record(app, "live-card-before-drag")
        edgePop(app)
        backOnTheChatsPage(app, "live-card-after-drag-to-chats-page")
        pageReturned(app)
    }

    func testFixtureConversationTitleDragNeverFoldsTheChat() {
        let app = fixture("chat.3")
        record(app, "fixture-title-before-drag")
        pullHeader(app, y: element(app, "chat.title").frame.midY)
        let back = element(app, "chat.history")
        XCTAssertTrue(wait { back.isHittable && abs(back.frame.minY - 58) < 2 }, "a pull down moved the chat page")
        XCTAssertFalse(element(app, "chats.now").exists)
        record(app, "fixture-title-after-drag")
        tapFinger(app, back)
        backOnTheChatsPage(app, "fixture-title-after-back")
        pageReturned(app)
    }

    func testFixtureShortEdgeSwipeSpringsBackToTheSameChat() {
        let app = fixture("chat.3")
        let title = element(app, "chat.title").label
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 80, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        let back = element(app, "chat.history")
        XCTAssertTrue(wait { back.isHittable && abs(back.frame.minX - 12) < 2 }, "a short pull did not spring back")
        XCTAssertEqual(element(app, "chat.title").label, title)
        record(app, "fixture-short-edge-swipe-returned")
        tapFinger(app, back)
        backOnTheChatsPage(app, "fixture-short-edge-swipe-after-back")
        pageReturned(app)
    }

    func testFixtureHistoryThenCloseNeverReopensTheRetainedChat() {
        let app = fixture("chat.3")
        record(app, "fixture-conversation-before-back")
        tapFinger(app, element(app, "chat.history"))
        backOnTheChatsPage(app, "fixture-history-before-close")
        XCTAssertTrue(wait { !self.element(app, "chat.title").exists })
        XCTAssertFalse(element(app, "chats.now").exists)
        reopenChats(app, "fixture-reopened-chats")
        pageReturned(app)
    }

    func testLiveKeyboardHistoryCloseAndRepeatedChatsStayThePage() {
        let app = live()
        liveConversationWithKeyboard(app)
        record(app, "live-conversation-keyboard-before-back")
        tapFinger(app, element(app, "chat.history"))
        backOnTheChatsPage(app, "live-history-before-close")
        XCTAssertTrue(wait { !self.element(app, "chat.title").exists })
        for index in 0..<2 {
            reopenChats(app, "live-reopened-chats-\(index)")
            XCTAssertTrue(wait { !self.element(app, "newtab.spaces").exists && !self.element(app, "chat.title").exists })
        }
        XCTAssertFalse(element(app, "chats.now").exists)
        pageReturned(app)
    }
}
