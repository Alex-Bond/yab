import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Delayed UI callbacks use the conversation which rendered them. These model
/// assertions do not launch a provider or load the owned loopback URLs.
@MainActor
final class ChatMarkdownOwnerTests: XCTestCase {
    private var window: UIWindow?
    private var previousKey: UIWindow?

    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
    }

    private func live() -> AppModel {
        let world = World(name: "owned-markdown-links", space: "public", spaces: [
            Space(id: "public", name: "Owned Public", emoji: "", tint: RGB(238, 233, 226)),
            Space(id: "private", name: "Owned Private", emoji: "", tint: RGB(44, 42, 52), isPrivate: true)
        ], mac: World.Mac(joined: false))
        return AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
    }

    private func publicChat(_ app: AppModel, id: Chat.ID = "owned-public-chat") -> Chat.ID {
        app.chats.add(Chat(id: id, title: "Owned public conversation", day: .today, time: "Now",
                          messages: [Message(role: .answer, text: "[Owned source](http://127.0.0.1/public-source)", by: .iphone)]))
        app.openChat(id)
        return id
    }

    private func privateChat(_ app: AppModel) throws -> Chat.ID {
        app.browser.showSpace("private")
        XCTAssertTrue(app.browser.space.isPrivate)
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.chats.update(id) { chat in
            chat.ephemeral = false
            chat.messages = [Message(role: .answer, text: "[Owned private source](http://127.0.0.1/private-source)", by: .iphone)]
        }
        XCTAssertTrue(app.chats.isPrivate(id))
        return id
    }

    func testOldPrivateRenderedLinkCannotBorrowTheNewPublicConversation() throws {
        let app = live()
        let old = try privateChat(app)
        app.hideSheet(); app.browser.showSpace("public")
        let current = publicChat(app)
        let tabs = app.browser.allTabs
        _ = ChatMarkdown.open(try XCTUnwrap(URL(string: "http://127.0.0.1/private-source")), from: old, app: app)
        XCTAssertEqual(app.browser.allTabs, tabs)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertEqual(app.chatSheet.chatID, current)
        XCTAssertTrue(app.chatSheet.shown)
        XCTAssertEqual(app.chats.visibleChats.map(\.id), [current])
        XCTAssertNil(app.sync.engine)
    }

    func testRetainedLinkIsRefusedOnHistoryInfoClosingAndAChangedOwner() throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let id = publicChat(app)
        // Each callback below keeps one actual owner's captured URL and ID.
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1/source"))
        let tabs = app.browser.allTabs
        app.openHistory()
        XCTAssertNil(app.chatSheet.chatID, "‹ left the chat for New Tab's Chats page")
        _ = ChatMarkdown.open(url, from: id, app: app)
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.browser.allTabs, tabs)
        app.openChat(id); app.openChatInfo()
        _ = ChatMarkdown.open(url, from: id, app: app)
        XCTAssertTrue(app.chatSheet.info)
        XCTAssertEqual(app.browser.allTabs, tabs)
        app.openChat(id)
        app.chatSheet.pose.e = 1
        _ = ChatMarkdown.open(url, from: id, app: app)
        XCTAssertEqual(app.browser.allTabs, tabs)
        app.openChat(id)
        _ = publicChat(app, id: "owned-other-chat")
        _ = ChatMarkdown.open(url, from: id, app: app)
        XCTAssertEqual(app.chatSheet.chatID, "owned-other-chat")
        XCTAssertEqual(app.browser.allTabs, tabs)
        app.chats.remove("owned-other-chat")
        _ = ChatMarkdown.open(url, from: "owned-other-chat", app: app)
        XCTAssertTrue(app.chatSheet.shown)
        XCTAssertEqual(app.browser.allTabs, tabs)
        app.hideSheet()
        _ = ChatMarkdown.open(url, from: "owned-other-chat", app: app)
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.browser.allTabs, tabs)
    }

    func testOnlyTheActualVisibleOwnerCanOpenAWebsiteInItsOwnPrivacyContext() throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let id = publicChat(app)
        for value in ["file:///owned", "yab://run", "javascript:alert(1)"] {
            _ = ChatMarkdown.open(try XCTUnwrap(URL(string: value)), from: id, app: app)
            XCTAssertTrue(app.browser.allTabs.isEmpty)
            XCTAssertTrue(app.chatSheet.shown)
        }
        let publicURL = "http://127.0.0.1/owned-public-source"
        _ = ChatMarkdown.open(try XCTUnwrap(URL(string: publicURL)), from: id, app: app)
        XCTAssertEqual(app.browser.tab?.url, publicURL)
        XCTAssertEqual(app.browser.tab?.isPrivate, false)
        XCTAssertFalse(app.chatSheet.shown)
        let secret = try privateChat(app)
        let privateURL = "http://127.0.0.1/owned-private-source"
        _ = ChatMarkdown.open(try XCTUnwrap(URL(string: privateURL)), from: secret, app: app)
        XCTAssertEqual(app.browser.tab?.url, privateURL)
        XCTAssertEqual(app.browser.tab?.isPrivate, true)
        XCTAssertTrue(app.browser.space.isPrivate)
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.browser.space("public")?.allTabs.compactMap(\.url), [publicURL])
        XCTAssertNil(app.sync.engine)
    }

    func testRetainedSameIDMenuActionsCannotPinOrArchiveOnTheChatsPageOrInfoPage() throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let id = publicChat(app)
        let menu = ChatNativeMenu.menu(chat: id, app: app)
        let pin = try XCTUnwrap(menu.children.first { $0.title == "Pin Chat" } as? UIAction)
        let archive = try XCTUnwrap(menu.children.first { $0.title == "Archive Chat" } as? UIAction)
        let button = UIButton(type: .system)
        app.openHistory()
        XCTAssertNil(app.chatSheet.chatID, "‹ left the chat for New Tab's Chats page")
        button.sendAction(pin); button.sendAction(archive)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat(id)).pinned)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat(id)).archived)
        XCTAssertFalse(app.chatSheet.shown)
        app.openChat(id); app.openChatInfo()
        button.sendAction(pin); button.sendAction(archive)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat(id)).pinned)
        XCTAssertFalse(try XCTUnwrap(app.chats.chat(id)).archived)
        XCTAssertTrue(app.chatSheet.info)
        app.openChat(id); button.sendAction(pin)
        XCTAssertTrue(try XCTUnwrap(app.chats.chat(id)).pinned)
    }

    func testAnActualControlsCapturedPresentationCallbackCannotReopenMoreOnHistory() async throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = live()
        let id = publicChat(app)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: ChatsLayer().environment(app))
        owned.rootViewController = host; window = owned
        owned.makeKeyAndVisible(); host.view.layoutIfNeeded()
        let ready = await until { self.controls(owned).contains { $0.owner == id } }
        XCTAssertTrue(ready)
        let button = try XCTUnwrap(controls(owned).first { $0.owner == id })
        let callback = try XCTUnwrap(button.onPresented)
        let eligibility = try XCTUnwrap(button.isCurrent)
        XCTAssertTrue(eligibility())
        app.openHistory()
        XCTAssertNil(app.chatSheet.chatID, "‹ left the chat for New Tab's Chats page")
        callback(true)
        XCTAssertFalse(eligibility())
        XCTAssertFalse(app.chatSheet.moreMenu)
        XCTAssertFalse(app.chatSheet.shown)
        app.openChat(id); app.openChatInfo()
        callback(true)
        XCTAssertFalse(eligibility())
        XCTAssertFalse(app.chatSheet.moreMenu)
        XCTAssertTrue(app.chatSheet.info)
    }

    private func controls(_ root: UIView) -> [ChatMenuControl] {
        let own = (root as? ChatMenuControl).map { [$0] } ?? []
        return own + root.subviews.flatMap(controls)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
