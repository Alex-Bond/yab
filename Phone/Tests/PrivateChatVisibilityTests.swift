import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class PrivateChatVisibilityTests: XCTestCase {
    private final class Authentication: PrivateAuthenticating {
        var completions: [@MainActor (PrivateAuthenticationResult) -> Void] = []
        func authenticate(_ completion: @escaping @MainActor (PrivateAuthenticationResult) -> Void) {
            completions.append(completion)
        }
        func invalidate() {}
        func finish(_ result: PrivateAuthenticationResult) { completions.last?(result) }
    }

    private final class FailingDevice: ChatBackend {
        let who = Chat.Answerer.iphone
        var isAvailable: Bool { true }
        var calls = 0
        func answer(_ context: AskContext) async throws -> String {
            calls += 1
            throw CancellationError()
        }
    }

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateChatVisibilityTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: folder) }

    private func world() -> World {
        let secret = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/private-secret")!,
                                         id: "private-page", isPrivate: true, title: "Private source title")
        return World(name: "private-chat-test", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(238, 233, 226)),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(44, 42, 52), today: [secret], current: secret.id, isPrivate: true),
        ], mac: World.Mac(joined: false))
    }

    private func live(_ authentication: Authentication) -> AppModel {
        AppModel(world: world(), fixturesEnabled: false, privateAuthentication: authentication, privateLockEnabled: { true })
    }

    private func makePrivateConversation(_ app: AppModel, _ auth: Authentication) throws -> Chat.ID {
        app.browser.showSpace("private")
        XCTAssertEqual(auth.completions.count, 1)
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.chats.update(id) { chat in
            chat.ephemeral = false
            chat.title = "Private conversation title"
            chat.unread = true
            chat.messages = [Message(role: .you, text: "private-question"),
                             Message(role: .answer, text: "private-answer", by: .iphone)]
        }
        app.chatSheet.draft = "private-draft"
        XCTAssertTrue(app.chats.isPrivate(id))
        return id
    }

    private func makePublicConversation(_ app: AppModel) -> Chat.ID {
        let chat = Chat(id: "local-public-chat", title: "Public conversation", unread: true,
                        messages: [Message(role: .answer, text: "Public answer", by: .iphone)])
        app.chats.add(chat)
        return chat.id
    }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    func testPublicListsSearchArchiveCountAndNowExcludePrivateOriginsAfterLeaving() throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        let publicID = makePublicConversation(app)
        app.chats.parked = .init(chat: secret, mode: .chat)
        XCTAssertNotNil(app.chats.parkedItem)
        app.hideSheet()
        app.browser.showSpace("public")
        XCTAssertTrue(app.chats.isPrivate(secret), "the origin does not change with the selected space")
        XCTAssertEqual(app.chats.visibleChats.map(\.id), [publicID])
        XCTAssertEqual(app.chats.listed.map(\.id), [publicID])
        XCTAssertEqual(app.chats.unreadCount, 1)
        XCTAssertTrue(app.chats.search("private").isEmpty)
        XCTAssertNil(app.chats.parkedItem)
        XCTAssertNil(app.nowItem)
        XCTAssertFalse(app.privateContentBlocked, "a closed conversation may retain its ID without trapping Public")
        app.openChats()
        XCTAssertFalse(app.privateContentBlocked)
        XCTAssertEqual(ChatSectioning.listed(app.chats.visibleChats, sheet: app.chatSheet).map(\.id), [publicID])
        XCTAssertTrue(ChatSectioning.search("private", in: app.chats.chats, sheet: app.chatSheet, app: app).isEmpty,
                      "even an old raw search caller cannot return private words")
        app.chats.setArchived(secret, true)
        NewTabPager.shared.showsArchive = true
        defer { NewTabPager.shared.showsArchive = false }
        XCTAssertTrue(app.chats.archived.isEmpty)
        XCTAssertTrue(ChatSectioning.search("private", in: app.chats.chats, sheet: app.chatSheet, app: app).isEmpty)
        XCTAssertFalse(app.tabCandidates.contains { $0.id == "private-page" })
        XCTAssertTrue(NewTabContent.make(for: app).recent.isEmpty)
        app.chats.parked = .init(chat: secret, mode: .answer)
        XCTAssertNil(app.chats.parkedItem, "the parked answer's question is private too")
    }

    func testPrivateRowsRequireBothThePrivateContextAndItsCurrentForegroundGrant() throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        app.hideSheet()
        app.privateLock.didEnterBackground()
        app.privateLock.didBecomeActive()
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertFalse(app.chats.isVisible(secret))
        app.privateLock.unlock()
        auth.finish(.unlocked)
        XCTAssertTrue(app.chats.isVisible(secret))
        XCTAssertEqual(app.chats.visibleChats.map(\.id), [secret])
        app.browser.showSpace("public")
        XCTAssertFalse(app.chats.isVisible(secret))
    }

    func testDirectOpenWaitsForTheGateAndCannotReopenOverPublicAfterCancel() throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        let publicID = makePublicConversation(app)
        app.hideSheet()
        app.browser.showSpace("public")
        app.openChat(publicID)
        app.openChat(secret)
        XCTAssertEqual(app.chatSheet.chatID, publicID)
        XCTAssertEqual(app.browser.spaceID, "public")
        XCTAssertTrue(app.privateLock.presentsPrompt)
        auth.finish(.cancelled)
        XCTAssertEqual(app.chatSheet.chatID, publicID)
        app.leaveLockedPrivate()
        app.openChat(secret)
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertEqual(app.chatSheet.chatID, secret)
        XCTAssertTrue(app.chatSheet.shown)
        XCTAssertEqual(app.chatSheet.draft, "private-draft")
        app.browser.showSpace("public")
        XCTAssertTrue(app.privateContentBlocked, "a still rendered private chat cannot stand over Public")
        app.leaveLockedPrivate()
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertFalse(app.privateContentBlocked)
    }

    func testParkedPrivateRestoreAuthenticatesWithoutPublishingItsTitleOnPublic() throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        app.chats.parked = .init(chat: secret, mode: .answer)
        app.hideSheet()
        app.browser.showSpace("public")
        app.restoreParked()
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertNil(app.nowItem)
        auth.finish(.cancelled)
        XCTAssertFalse(app.chatSheet.shown)
        app.restoreParked()
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertTrue(app.chatSheet.shown)
        XCTAssertEqual(app.chatSheet.chatID, secret)
    }

    func testPrivateSendFromPublicKeepsItsDraftUntilAuthenticationAndNeverFallsBackToMac() async throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        app.chatSheet.answerers.device = NoDeviceModel()
        app.browser.showSpace("public")
        let before = try XCTUnwrap(app.chats.chat(secret)).messages
        app.send("private-draft")
        XCTAssertEqual(app.chatSheet.draft, "private-draft")
        XCTAssertEqual(app.chats.chat(secret)?.messages, before)
        auth.finish(.cancelled)
        XCTAssertEqual(app.chatSheet.draft, "private-draft")
        app.send("private-draft")
        auth.finish(.unlocked)
        XCTAssertEqual(app.browser.spaceID, "private")
        XCTAssertEqual(app.chats.chat(secret)?.messages.filter { $0.role == .you && $0.text == "private-draft" }.count, 1)
        XCTAssertEqual(app.chats.chat(secret)?.messages.last?.text, Answerers.LocalFailure.unavailable.localizedDescription)
        XCTAssertFalse(app.chats.chat(secret)?.messages.contains { $0.role == .typing || $0.role == .wait } == true)
        XCTAssertNil(app.sync.engine)
        let profile = LocalChatProfile(folder: folder)
        profile.capture(app.chats.localEntries)
        await profile.flush()
        XCTAssertTrue(profile.entries.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: profile.file), as: UTF8.self).contains("private-"))
    }

    func testPrivateQuestionAndRetainedPrivatePageCannotWriteToAReadySyncJournal() async throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        let publicID = makePublicConversation(app)
        app.hideSheet()
        app.browser.showSpace("public")
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        mac.client.start()
        defer { mac.client.stop(); app.sync.end() }
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                         folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                         deviceName: "Private Chat Test iPhone", transport: server, ownWorld: true))
        let ready = await until { app.sync.line == .live && app.sync.ready && !app.sync.macs.isEmpty }
        XCTAssertTrue(ready)
        let engine = try XCTUnwrap(app.sync.engine)
        let question = AskContext(question: "private-journal-secret", page: nil, history: [])
        XCTAssertThrowsError(try app.sync.sendQuestion(question, in: secret)) { error in
            guard let failure = error as? SyncBridge.QuestionFailure, case .privateConversation = failure else { return XCTFail("wrong rejection: \(error)") }
        }
        app.chatSheet.pageSources[publicID] = try XCTUnwrap(app.browser.tab("private-page"))
        app.browser.close("private-page")
        XCTAssertThrowsError(try app.sync.sendQuestion(question, in: publicID), "retained private page context is still private")
        XCTAssertTrue(engine.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(mac.journal.all(SyncCollection.send).isEmpty)
        XCTAssertTrue(app.chats.localEntries.allSatisfy { !$0.chat.messages.contains { $0.text == question.question } })
    }

    func testFailedOnDevicePrivateAnswerLeavesAnHonestLocalNoteWithoutMacReplay() async throws {
        let auth = Authentication(), app = live(auth)
        let secret = try makePrivateConversation(app, auth)
        let device = FailingDevice()
        app.chatSheet.answerers.device = device
        app.respond(to: "private-question", in: secret, by: .iphone)
        let released = await until { device.calls == 1 && !app.chatSheet.answeringHere.contains(secret) }
        XCTAssertTrue(released)
        XCTAssertEqual(app.chats.chat(secret)?.messages.last?.text, Answerers.LocalFailure.interrupted.localizedDescription)
        XCTAssertFalse(app.chatSheet.sendingToMac.contains(secret))
        XCTAssertNil(app.sync.engine)
        XCTAssertTrue(app.chats.localEntries.isEmpty)
    }
}
