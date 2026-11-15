import XCTest
@testable import YabPhone

@MainActor
final class ChatPresentationTests: XCTestCase {
    func testChatInfoRetainsTheConversationDraftAndRestoresItsKeyboardFocus() throws {
        let motion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = motion }
        let app = AppModel(world: try World.load(named: "mira"))
        app.openChat("cafe")
        app.chatSheet.draft = "Unsent draft"
        app.chatSheet.focused = true
        let chat = app.chats.chat("cafe")
        let route = app.sheetRoute
        app.openChatInfo()
        XCTAssertTrue(app.chatSheet.info)
        XCTAssertFalse(app.chatSheet.focused)
        XCTAssertEqual(app.chats.chat("cafe"), chat)
        XCTAssertEqual(app.sheetRoute, route)
        app.escapeSheet()
        XCTAssertFalse(app.chatSheet.info)
        XCTAssertTrue(app.chatSheet.focused)
        XCTAssertEqual(app.chatSheet.draft, "Unsent draft")
        XCTAssertEqual(app.chatSheet.chatID, "cafe")
        app.openChatInfo()
        app.closeSheet()
        XCTAssertFalse(app.chatSheet.info)
        XCTAssertNil(app.surfaces.chat)
        XCTAssertFalse(app.chatSheet.shown)
    }

    func testInfoArchiveKeepsTheChatSearchableAndReturnsToChats() throws {
        let motion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = motion }
        let app = AppModel(world: try World.load(named: "mira"))
        let page = app.browser.tab
        app.openChat("cafe")
        let title = try XCTUnwrap(app.chats.chat("cafe")).title
        app.openChatInfo()
        app.archiveOpenChat()
        XCTAssertTrue(try XCTUnwrap(app.chats.chat("cafe")).archived)
        XCTAssertTrue(app.chats.search(title).contains { $0.id == "cafe" })
        XCTAssertFalse(app.chatSheet.shown, "the chat goes back to New Tab's Chats page")
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertEqual(NewTabPager.shared.startAt, NewTabPager.chatsPage)
        XCTAssertFalse(app.chatSheet.info)
        XCTAssertEqual(app.browser.tab, page)
        app.unarchive("cafe")
        XCTAssertFalse(try XCTUnwrap(app.chats.chat("cafe")).archived)
        XCTAssertTrue(app.chats.listed.contains { $0.id == "cafe" })
    }
}
