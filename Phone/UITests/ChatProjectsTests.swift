import XCTest

/// Projects of chats with a finger (PLAN-chat-projects.md, iPhone): the
/// pinned circles and a project's card on the Chats page, a project open
/// with its rows, swiped (Project, Pin, Archive) and held (Move to
/// Project ›), its card, words in its field starting a chat there, and
/// nothing offered where there are no projects.
final class ChatProjectsTests: XCTestCase {
    private let lisbon = "prj-1a2b3c4d"

    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    func testPinnedCirclesAndACardOpenTheProjectAndItsCard() {
        let app = launch("projects.list")
        XCTAssertTrue(element(app, "newtab.projects").waitForExistence(timeout: 15), "the pinned circles")
        XCTAssertTrue(element(app, "newtab.project.prj-3a4b5c6d").exists, "a project not pinned is a card")
        XCTAssertTrue(element(app, "newtab.project.peek").exists, "news over a circle")
        XCTAssertFalse(element(app, "newtab.chat.cafe").exists, "a project's chat is in its project")
        XCTAssertTrue(element(app, "newtab.chat.grinder").exists, "a chat on its own stays")

        element(app, "newtab.project.\(lisbon)").tap()
        XCTAssertTrue(element(app, "project.page").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "project.chat.lisbon").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "project.field").exists, "New chat in Lisbon Trip")

        element(app, "project.title").tap()
        let instructions = element(app, "project.info.instructions")
        XCTAssertTrue(instructions.waitForExistence(timeout: 5), "the project's card")
        XCTAssertTrue(instructions.label.contains("Alfama"), instructions.label)
        XCTAssertTrue(element(app, "project.info.memory").exists)
        element(app, "project.info.back").tap()
        XCTAssertTrue(waitFor(!self.element(app, "project.info").exists && self.element(app, "project.chat.lisbon").isHittable))

        element(app, "project.back").tap()
        XCTAssertTrue(waitFor(!self.element(app, "project.page").exists), "back on the Chats page")
        XCTAssertTrue(element(app, "newtab.projects").waitForExistence(timeout: 3))
    }

    func testARowSwipedHasProjectPinArchiveAndProjectTakesItOut() {
        let app = launch("projects.page")
        let row = element(app, "project.chat.lisbon")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        for word in ["Archive", "Pin", "Project"] {
            XCTAssertTrue(app.buttons[word].waitForExistence(timeout: 3), "no \(word)")
        }
        app.buttons["Project"].tap()
        let out = app.buttons["Remove from Project"]
        XCTAssertTrue(out.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["\u{1F680} Tern Launch"].exists, "the other projects")
        out.tap()
        XCTAssertTrue(waitFor(!row.exists), "out of the project")
    }

    func testAHeldChatMovesIntoAProjectFromItsMenu() {
        let app = launch("projects.list")
        let grinder = element(app, "newtab.chat.grinder")
        XCTAssertTrue(grinder.waitForExistence(timeout: 15))
        grinder.press(forDuration: 1.0)
        let move = app.buttons["Move to Project"]
        XCTAssertTrue(move.waitForExistence(timeout: 3), "Move to Project in the held chat's menu")
        move.tap()
        // The submenu's row, not the pinned circle of the same name.
        let into = app.buttons.matching(NSPredicate(format: "label == 'Lisbon Trip' AND NOT (identifier BEGINSWITH 'newtab.')")).firstMatch
        XCTAssertTrue(into.waitForExistence(timeout: 3), "the projects in its submenu")
        into.tap()
        XCTAssertTrue(waitFor(!grinder.exists), "the chat left the cards")
        element(app, "newtab.project.\(lisbon)").tap()
        XCTAssertTrue(element(app, "project.chat.grinder").waitForExistence(timeout: 5), "and is in the project")
    }

    func testWordsInTheProjectsFieldAreANewChatInIt() {
        let app = launch("projects.page")
        let field = element(app, "project.field")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Is the 7:05 return worth it?")
        let send = element(app, "project.send")
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the new chat in its cover")
        XCTAssertTrue(element(app, "chat.projectBadge").waitForExistence(timeout: 3), "wearing the project")
        XCTAssertTrue(element(app, "chat.answer").waitForExistence(timeout: 10), "Claude answers it")
        element(app, "chat.history").tap()
        XCTAssertTrue(waitFor(!title.exists))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'project.chat.'"))
        XCTAssertTrue(waitFor(rows.count == 2), "the project has it: \(rows.count) rows")
    }

    func testANewChatBegunInAProjectWearsItsPill() {
        let app = launch("projects.new")
        XCTAssertTrue(element(app, "chat.projectPill").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "chat.projectBadge").exists)
    }

    func testWithoutProjectsNothingIsOffered() {
        let app = launch("projects.none")
        let grinder = element(app, "newtab.chat.grinder")
        XCTAssertTrue(grinder.waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "newtab.projects").exists)
        grinder.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Archive Chat"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Move to Project"].exists)
    }
}
