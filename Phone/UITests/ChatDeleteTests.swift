import XCTest

/// Delete Chat, as a person finds it: in a chat's ⋯ and on a card of the
/// Chats page held, asked first, and the chat gone after. Pictures of each
/// step go to the job's delete/ folder.
final class ChatDeleteTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        app.launchEnvironment["YAB_HAPTICS_SILENT"] = "1"
        app.launch()
        return app
    }

    private func first(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let out = ProcessInfo.processInfo.environment["YAB_OUT"] else { return }
        let folder = URL(fileURLWithPath: out).appendingPathComponent("delete")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

    func testDeleteFromTheChatsMoreMenu() {
        let app = launch("chat.3")
        let more = first(app, "chat.more")
        XCTAssertTrue(more.waitForExistence(timeout: 15), "no ⋯")
        more.tap()
        let delete = app.buttons["Delete Chat\u{2026}"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "⋯ has Delete Chat…")
        save(app, "1-more-menu")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete this chat?"].waitForExistence(timeout: 3), "asked first")
        save(app, "2-more-question")
        app.buttons["Delete Chat"].tap()
        XCTAssertTrue(first(app, "newtab.chats").waitForExistence(timeout: 5), "the Chats page in its place")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.staticTexts["Anna\u{2019}s hours picker"].exists, "its card is gone")
        save(app, "3-more-gone")
    }

    func testDeleteFromAHeldCardOnTheChatsPage() {
        let app = launch("ch-chats.1")
        let card = first(app, "newtab.chat.grinder")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "no card")
        card.press(forDuration: 0.8)
        let delete = app.buttons["Delete Chat\u{2026}"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "the held card has Delete Chat…")
        save(app, "4-card-menu")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete this chat?"].waitForExistence(timeout: 3), "asked first")
        save(app, "5-card-question")
        app.buttons["Delete Chat"].tap()
        let end = Date().addingTimeInterval(3)
        while card.exists, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(card.exists, "its card is gone")
        save(app, "6-card-gone")
    }
}
