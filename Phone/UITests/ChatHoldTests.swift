import XCTest

/// A held message, as in Messages: it lifts with its menu. A question offers
/// Copy, Translate, Edit and Share; an answer Copy, Select Text, Translate
/// and Share. Edit puts the question back in the field; Select Text opens the
/// answer's words in a sheet. Pictures of each go to the job's hold/ folder.
final class ChatHoldTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String, textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        return app
    }

    private func first(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let out = ProcessInfo.processInfo.environment["YAB_OUT"] else { return }
        let folder = URL(fileURLWithPath: out).appendingPathComponent("hold")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func menu(_ app: XCUIApplication, has titles: [String], lacks other: [String], file: StaticString = #filePath, line: UInt = #line) {
        for title in titles {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "the menu has \(title)", file: file, line: line)
        }
        for title in other {
            XCTAssertFalse(app.buttons[title].exists, "the menu has no \(title)", file: file, line: line)
        }
    }

    func testAHeldQuestionLiftsWithItsMenuAndEditPutsItBackInTheField() {
        let app = launch("chat.3")
        let question = first(app, "chat.question")
        XCTAssertTrue(question.waitForExistence(timeout: 15), "no question")
        let words = question.label
        question.press(forDuration: 0.8)
        menu(app, has: ["Copy", "Translate", "Edit", "Share"], lacks: ["Select Text"])
        save(app, "question-held")

        app.buttons["Edit"].tap()
        let field = app.textFields["chat.field"]
        _ = waitFor((field.value as? String) == words)
        save(app, "question-edit")
        XCTAssertTrue(waitFor((field.value as? String) == words), "the field holds \(String(describing: field.value)), not \(words)")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up to change it")
    }

    func testAHeldAnswerLiftsWithItsMenuCopiesAndSelectsText() {
        let app = launch("chat.3")
        let answer = first(app, "chat.answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "no answer")
        answer.press(forDuration: 0.8)
        menu(app, has: ["Copy", "Select Text", "Translate", "Share"], lacks: ["Edit"])
        save(app, "answer-held")

        app.buttons["Copy"].tap()
        let toast = first(app, "chrome.toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 3) && waitFor(toast.label.contains("Copied")), "Copied is said")

        XCTAssertTrue(waitFor(!app.buttons["Select Text"].exists), "the menu went")
        answer.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 3))
        app.buttons["Select Text"].tap()
        let sheet = first(app, "chat.selectText")
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the words open in a sheet")
        XCTAssertFalse((sheet.value as? String ?? "").isEmpty, "the sheet holds the answer's words")
        save(app, "answer-select")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(waitFor(!sheet.exists), "Done closes it")
    }

    // MARK: - every menu's glyphs, beside the system's

    /// Each native menu of chats, held or tapped, pictured into menus/: their
    /// glyphs stand where SF Symbols stand in a menu, as large and as heavy.
    func testChatMenusInPictures() {
        var app = launch("chat.3")
        let question = first(app, "chat.question")
        XCTAssertTrue(question.waitForExistence(timeout: 15), "no question")
        question.press(forDuration: 0.8)
        menu(app, has: ["Copy", "Translate", "Edit", "Share"], lacks: [])
        menuShot(app, "message-question")
        app.terminate()

        app = launch("chat.3")
        let answer = first(app, "chat.answer")
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "no answer")
        answer.press(forDuration: 0.8)
        menu(app, has: ["Copy", "Select Text"], lacks: [])
        menuShot(app, "message-answer")
        app.terminate()

        app = launch("chat.3")
        let more = first(app, "chat.more")
        XCTAssertTrue(more.waitForExistence(timeout: 15) && waitFor(more.isHittable), "no ⋯")
        more.tap()
        XCTAssertTrue(app.collectionViews.buttons["Chat Info"].waitForExistence(timeout: 5), "⋯ has no menu")
        menuShot(app, "chat-more")
        app.terminate()

        app = launch("chat.16")
        let mark = first(app, "chat.tryAgain")
        XCTAssertTrue(mark.waitForExistence(timeout: 15) && waitFor(mark.isHittable), "no Not Sent mark")
        mark.tap()
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5), "no Try Again")
        menuShot(app, "not-sent")
        app.terminate()
    }

    /// The Chats page's card held, a space's tab held, the right button held.
    func testNewTabAndChromeMenusInPictures() {
        var app = launch("ch-chats.1")
        let card = app.chatsPageRows.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20) && waitFor(card.isHittable), "no card")
        card.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Open Chat"].waitForExistence(timeout: 5), "the card has no menu")
        menuShot(app, "chats-card")
        app.terminate()

        app = launch("page.1")
        XCTAssertTrue(first(app, "chrome.plate").waitForExistence(timeout: 20))
        // Up from the plate: the spaces, each tab a row.
        SpacesGesture.open(in: app)
        let row = first(app, "newtab.tab.work-hn")
        XCTAssertTrue(row.waitForExistence(timeout: 8) && waitFor(row.isHittable), "no tab row")
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Close Tab"].waitForExistence(timeout: 5), "the tab has no menu")
        menuShot(app, "spaces-tab")
        app.terminate()

        app = launch("page.1")
        let plus = app.buttons["chrome.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 20) && waitFor(plus.isHittable), "no right button")
        plus.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["chrome.menu.newchat"].waitForExistence(timeout: 5), "the right button has no menu")
        menuShot(app, "chrome-plus")
        app.terminate()
    }

    /// A held question at the largest text sizes: the glyphs grow with the words.
    func testAHeldQuestionAtLargerTextInPictures() {
        for (size, name) in [("UICTContentSizeCategoryXXXL", "xxxl"), ("UICTContentSizeCategoryAccessibilityL", "ax-l")] {
            let app = launch("chat.3", textSize: size)
            let question = first(app, "chat.question")
            XCTAssertTrue(question.waitForExistence(timeout: 15), "no question")
            question.press(forDuration: 0.8)
            XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
            menuShot(app, "message-question-\(name)")
            app.terminate()
        }
    }

    // MARK: - a new chat's empty field

    /// A new chat with no ideas to offer (a fresh profile, no page open)
    /// shows nothing over its field: the field's placeholder says what it is for.
    func testANewChatWithoutIdeasShowsNothingOverItsField() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-chat-hint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 20), "no welcome")
        app.passWelcome()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.closeField(), "the first run's field did not close")
        XCTAssertTrue(app.newChatFromPlus(), "New Chat under the right button did not open a chat")
        XCTAssertTrue(app.textFields["chat.field"].waitForExistence(timeout: 8), "no new chat")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app, "newchat-no-ideas")
        XCTAssertFalse(first(app, "chat.hint").exists, "no words over the field")
        app.terminate()
    }

    /// With a page that has ideas, they stand over the field as before.
    func testANewChatAboutAPageKeepsItsIdeas() {
        let app = launch("chat.6")
        XCTAssertTrue(first(app, "chat.idea").waitForExistence(timeout: 15), "the page's ideas are gone")
        save(app, "newchat-ideas")
        XCTAssertFalse(first(app, "chat.hint").exists)
    }
}
