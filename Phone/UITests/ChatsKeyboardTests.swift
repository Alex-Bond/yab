import XCTest

/// The keyboard between New Tab's Chats page and a chat out of its card:
/// a tap on a card puts the keyboard away, and back on the page the list
/// stands as it did before the keyboard came, its field at the foot, cards
/// down to it, whichever keyboard was up (the page's search or the chat's).
/// Pictures go to the job's keyboard/ folder.
final class ChatsKeyboardTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String = "ch-chats.1") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        return app
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

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-AX"
        tree.lifetime = .keepAlways
        add(tree)
        let folder = Atlas.out.appendingPathComponent("keyboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// The moment a case starts or ends, for cutting it out of the run's movie.
    private func mark(_ name: String) {
        let line = String(format: "%@ %.3f\n", name, Date().timeIntervalSince1970)
        let file = Atlas.out.appendingPathComponent("marks.txt")
        try? FileManager.default.createDirectory(at: Atlas.out, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    private var keyboardUp: (XCUIApplication) -> Bool = { $0.keyboards.firstMatch.exists }

    /// The Chats page at rest: its field's foot and the list's, to come back to.
    private struct Rest { let fieldBottom: CGFloat; let listBottom: CGFloat }

    private func rest(_ app: XCUIApplication) -> Rest {
        Rest(fieldBottom: app.textFields["field.input"].frame.maxY, listBottom: node(app, "newtab.chats").frame.maxY)
    }

    private func onChatsPage(_ app: XCUIApplication) -> Bool {
        app.canTouch(app.chatsPageNewChat) && !node(app, "chat.title").exists
    }

    /// Back on the page, it stands as it did at rest: no keyboard, the field
    /// at the foot and the list down to it, not on a keyboard that went.
    private func assertAtRest(_ app: XCUIApplication, like before: Rest, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait { onChatsPage(app) && !keyboardUp(app) }, "\(what): not back on the Chats page without the keyboard", file: file, line: line)
        let field = app.textFields["field.input"]
        XCTAssertTrue(wait { abs(field.frame.maxY - before.fieldBottom) < 2 },
                      "\(what): the field stands at \(field.frame.maxY), not at the foot (\(before.fieldBottom))", file: file, line: line)
        XCTAssertTrue(wait { abs(node(app, "newtab.chats").frame.maxY - before.listBottom) < 2 },
                      "\(what): the list ends at \(node(app, "newtab.chats").frame.maxY), not at \(before.listBottom)", file: file, line: line)
    }

    /// Search's keyboard up, a card tapped: the chat opens with the keyboard
    /// away, and ‹ brings back the whole list.
    func testATappedCardPutsTheSearchKeyboardAwayAndTheListComesBackWhole() {
        let app = launch()
        XCTAssertTrue(wait({ onChatsPage(app) }, timeout: 20), "no Chats page")
        let field = app.textFields["field.input"]
        let before = rest(app)
        save(app, "1-chats-at-rest")
        mark("chat-tap-keyboard-start")
        field.tap()
        XCTAssertTrue(wait { keyboardUp(app) }, "search takes the keyboard")
        save(app, "2-chats-search-keyboard")

        let card = app.chatsPageRows.firstMatch
        XCTAssertTrue(wait { card.isHittable }, "no card")
        card.tap()
        XCTAssertTrue(wait { node(app, "chat.history").isHittable }, "the chat did not open")
        // At once: the keyboard goes as the chat zooms out of its card.
        let away = wait({ !keyboardUp(app) }, timeout: 1)
        save(app, "3-chat-from-card")
        XCTAssertTrue(away, "the keyboard stayed over the chat a card opened")
        XCTAssertTrue(wait { !keyboardUp(app) }, "the keyboard never went")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        node(app, "chat.history").tap()
        _ = wait({ onChatsPage(app) }, timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        save(app, "4-chats-after-back")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        mark("chat-tap-keyboard-end")
        assertAtRest(app, like: before, "back from a chat opened over search")
    }

    /// The chat's own keyboard up as ‹ takes it back into its card: the
    /// list comes back whole, even after search had the keyboard before.
    func testBackFromAChatWithItsKeyboardUpLeavesTheListWhole() {
        let app = launch()
        XCTAssertTrue(wait({ onChatsPage(app) }, timeout: 20), "no Chats page")
        let before = rest(app)
        app.textFields["field.input"].tap()
        XCTAssertTrue(wait { keyboardUp(app) }, "search takes the keyboard")

        app.chatsPageRows.firstMatch.tap()
        XCTAssertTrue(wait { node(app, "chat.history").isHittable }, "the chat did not open")
        let chatField = app.textFields["chat.field"]
        XCTAssertTrue(wait { chatField.isHittable })
        chatField.tap()
        XCTAssertTrue(wait { keyboardUp(app) }, "the chat's field takes the keyboard")
        save(app, "5-chat-keyboard-up")

        node(app, "chat.history").tap()
        _ = wait({ onChatsPage(app) }, timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        save(app, "6-chats-after-back-from-keyboard")
        assertAtRest(app, like: before, "back from a chat with its keyboard up")

        // And again from a chat that never had a keyboard.
        app.chatsPageRows.firstMatch.tap()
        XCTAssertTrue(wait { node(app, "chat.history").isHittable && !keyboardUp(app) })
        node(app, "chat.history").tap()
        assertAtRest(app, like: before, "back again")
        save(app, "7-chats-after-second-back")
    }

    // MARK: - putting the search's keyboard away, staying in the list

    /// Search pressed: the keyboard goes, the words and the cards they found
    /// stay, the field at the foot; a tap on the field brings the keyboard back.
    /// A tap between the cards and a drag down into the keyboard put it away too.
    func testTheSearchKeyboardGoesAwayAndTheListStays() {
        // Every step pictured, whichever fails.
        continueAfterFailure = true
        let app = launch()
        XCTAssertTrue(wait({ onChatsPage(app) }, timeout: 20), "no Chats page")
        let before = rest(app)
        let field = app.textFields["field.input"]
        let first = app.chatsPageRows.firstMatch
        let word = String(first.label.split(separator: " ").first ?? "a")
        mark("search-keyboard-down-start")
        field.tap()
        XCTAssertTrue(wait { keyboardUp(app) })
        field.typeText(word)
        XCTAssertTrue(wait { app.chatsPageRows.count > 0 }, "\(word) finds no card")
        let found = app.chatsPageRows.count
        save(app, "8-search-typed")
        field.typeText("\n")
        let searchAway = wait { !keyboardUp(app) }
        save(app, "9-search-keyboard-away")
        XCTAssertTrue(searchAway, "Search kept the keyboard up")
        XCTAssertEqual(field.value as? String, word, "the words stay")
        XCTAssertEqual(app.chatsPageRows.count, found, "what they found stays")
        XCTAssertTrue(wait { abs(field.frame.maxY - before.fieldBottom) < 2 }, "the field rests at \(field.frame.maxY), not at the foot (\(before.fieldBottom))")

        if !keyboardUp(app) { field.tap() }
        XCTAssertTrue(wait { keyboardUp(app) }, "a tap on the field brings the keyboard back")
        // Under the last card found, inside the list: empty space.
        let list = node(app, "newtab.chats").frame
        let last = app.chatsPageRows.element(boundBy: app.chatsPageRows.count - 1).frame
        let y = min(last.maxY + 30, list.maxY - 20)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: y)).tap()
        let tapAway = wait { !keyboardUp(app) }
        save(app, "10-tap-away")
        XCTAssertTrue(tapAway, "a tap between the cards kept the keyboard up")
        XCTAssertEqual(field.value as? String, word)

        // Without words: all the cards, dragged down into the keyboard.
        if !keyboardUp(app) { field.tap() }
        XCTAssertTrue(wait { keyboardUp(app) })
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: word.count))
        XCTAssertTrue(wait { (field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue })
        let start = app.chatsPageRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let window = app.windows.firstMatch.frame
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: window.maxY - 10)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        let dragAway = wait { !keyboardUp(app) }
        save(app, "11-drag-away")
        XCTAssertTrue(dragAway, "dragged down into it, the keyboard stayed")
        mark("search-keyboard-down-end")
        assertAtRest(app, like: before, "after the drag")
        XCTAssertTrue(app.chatsPageRows.element(boundBy: app.chatsPageRows.count - 1).exists)
    }

    /// The pages turned to Chats with the keyboard up: it goes, the search
    /// waits for a tap.
    func testSearchOnTheSheetsChatsShowsItsFieldOverTheKeyboard() {
        searchFromTheSheetsChats("search.chats", picture: "search-from-the-sheet")
    }

    /// From a page, with its address in the field: the case testers reported.
    func testSearchOnChatsFromAPageShowsItsFieldWithoutTheAddress() {
        let app = searchFromTheSheetsChats("search.chats.page", picture: "search-from-a-page")
        XCTAssertEqual(app.textFields["field.input"].value as? String, "Search chats", "the page's address stayed")
    }

    @discardableResult
    private func searchFromTheSheetsChats(_ state: String, picture: String) -> XCUIApplication {
        let app = launch(state)
        let search = node(app, "spaces.search")
        XCTAssertTrue(search.waitForExistence(timeout: 20), "no search button on Chats")
        search.tap()
        XCTAssertTrue(wait { keyboardUp(app) }, "no keyboard")
        let field = app.textFields["field.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the keyboard rose with no field")
        save(app, picture)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "the field is under the keyboard")
        return app
    }

    func testTurningToChatsPutsTheKeyboardAway() {
        let app = launch("newtab.1")
        let field = app.textFields["field.input"]
        XCTAssertTrue(wait({ field.exists && keyboardUp(app) }, timeout: 20), "New Tab without its keyboard")
        save(app, "12-newtab-keyboard")
        mark("chats-page-focus-start")
        XCTAssertTrue(app.openChatsPage(), "the pages did not turn to Chats")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app, "13-turned-to-chats")
        mark("chats-page-focus-end")
        XCTAssertTrue(wait { !keyboardUp(app) }, "Chats took the keyboard by itself")
        XCTAssertTrue(wait { field.frame.maxY > app.windows.firstMatch.frame.maxY - 80 }, "the field is not at the foot: \(field.frame.maxY)")
        field.tap()
        XCTAssertTrue(wait { keyboardUp(app) }, "a tap on search brings the keyboard")
    }

    /// To Private by the eyes, New Tab keeps its keyboard, as before.
    func testPrivateKeepsTheKeyboard() {
        let app = launch("newtab.1")
        XCTAssertTrue(wait({ app.textFields["field.input"].exists && keyboardUp(app) }, timeout: 20))
        let eyes = node(app, "field.eyes")
        XCTAssertTrue(wait { eyes.exists && eyes.isHittable }, "no eyes")
        eyes.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app, "14-private-keeps-keyboard")
        XCTAssertTrue(keyboardUp(app), "Private lost the keyboard")
    }

    /// Chats from All Tabs' left button: the list, the keyboard down.
    func testChatsFromAllTabsOpensWithoutTheKeyboard() {
        let app = launch("stack.gallery")
        let chats = node(app, "tabs.chats")
        XCTAssertTrue(wait({ chats.isHittable }, timeout: 20), "no Chats in All Tabs")
        chats.tap()
        XCTAssertTrue(wait({ onChatsPage(app) }, timeout: 8), "All Tabs' Chats did not open the Chats page")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app, "15-chats-from-all-tabs")
        XCTAssertFalse(keyboardUp(app), "Chats took the keyboard by itself")
    }
}
