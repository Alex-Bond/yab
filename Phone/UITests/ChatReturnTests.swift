import XCTest

/// Return keeps a multiline draft until the separate Send button is tapped.
final class ChatReturnTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func node(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        app.launch()
        return app
    }

    private func record(_ app: XCUIApplication, _ name: String) throws {
        let folder = Atlas.out.appendingPathComponent("chat-return", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func compose(_ app: XCUIApplication, field id: String, shot: String) throws -> String {
        let field = app.textFields[id].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("First line")
        let before = field.frame.height
        try record(app, "\(shot)-before-return")
        let key = app.keyboards.buttons["Return"]
        XCTAssertTrue(key.waitForExistence(timeout: 5), "the keyboard offers Return")
        key.tap()
        key.tap()
        field.typeText("Second line")
        let draft = "First line\n\nSecond line"
        XCTAssertEqual(field.value as? String, draft, "Return preserves the draft and blank lines")
        XCTAssertGreaterThan(field.frame.height, before, "the composer grows for multiple lines")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        try record(app, "\(shot)-multiline-draft")
        return draft
    }

    func testReturnInANewChatKeepsTheDraftUntilSend() throws {
        let app = launch("chat.6")
        let draft = try compose(app, field: "chat.field", shot: "new-chat")
        XCTAssertFalse(node(app, "chat.question").exists, "Return never creates a message")
        node(app, "chat.send").tap()
        let question = node(app, "chat.question")
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(question.label, draft)
        try record(app, "new-chat-sent")
    }

    func testReturnInAnExistingChatKeepsTheDraft() throws {
        let app = launch("chat.3")
        _ = try compose(app, field: "chat.field", shot: "existing-chat")
        XCTAssertTrue(node(app, "chat.send").isHittable)
    }

    func testReturnInAProjectKeepsTheDraftUntilSend() throws {
        let app = launch("projects.page")
        let draft = try compose(app, field: "project.field", shot: "project")
        XCTAssertTrue(node(app, "project.page").exists, "Return stays in the project")
        XCTAssertFalse(node(app, "chat.title").exists, "Return never starts a chat")
        node(app, "project.send").tap()
        let question = node(app, "chat.question")
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(question.label, draft)
        try record(app, "project-sent")
    }
}
