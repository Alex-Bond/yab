import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class ChatPreferencesTests: XCTestCase {
    private final class Device: ChatBackend {
        let who = Chat.Answerer.iphone
        var isAvailable = true
        var calls: [AskContext] = []
        func answer(_ context: AskContext) async throws -> String {
            calls.append(context)
            return "Owned local answer"
        }
    }

    private var folder: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatPreferencesTests-\(UUID())")
        suite = "ChatPreferencesTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        settings = SettingsStore(defaults: defaults, supportsOnDeviceAnswers: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func app() -> AppModel {
        let world = World(name: "owned-preferences", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(240, 240, 240)),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(240, 240, 240), isPrivate: true)
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        let store = settings!
        app.chatSheet.answerers.pageAnswers = { store.pageAnswers }
        app.chatSheet.answerers.macAgent = { store.agent }
        return app
    }

    private func until(_ test: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            if test() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return test()
    }

    private func join(_ app: AppModel, oldMac: Bool = false) async throws -> TestMac {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, agentSelection: !oldMac)
        mac.client.start()
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                         folder: folder.appendingPathComponent("journal"), seed: false,
                                         makesKey: false, deviceName: "Owned Preferences iPhone", transport: server,
                                         ownWorld: true))
        let ready = await until { app.sync.ready && !app.sync.macs.isEmpty && app.sync.line == .live }
        XCTAssertTrue(ready)
        if !oldMac {
            let capable = await until { app.sync.engine?.canStartAgent(on: "mac-a") == true }
            XCTAssertTrue(capable)
        }
        return mac
    }

    func testActualPersistedSettingsControlPublicPageRoutingAndPrivateStaysLocal() throws {
        let app = app(), device = Device()
        app.chatSheet.answerers.device = device
        let chat = Chat(id: "local", title: "Local")
        let router = app.chatSheet.answerers
        XCTAssertEqual(router.who(for: "page", in: chat, aboutPage: true, fixturesEnabled: false), .iphone)
        settings.pageAnswers = .mac
        settings.agent = .chatGPT
        XCTAssertEqual(router.who(for: "page", in: chat, aboutPage: true, fixturesEnabled: false), .claude)
        XCTAssertEqual(router.preferredMacAgent, .codex)
        let reopened = SettingsStore(defaults: defaults)
        router.pageAnswers = { reopened.pageAnswers }
        router.macAgent = { reopened.agent }
        XCTAssertEqual(router.who(for: "page", in: chat, aboutPage: true, fixturesEnabled: false), .claude)
        XCTAssertEqual(router.preferredMacAgent, .codex)
        XCTAssertEqual(router.who(for: "private", in: chat, aboutPage: false, fixturesEnabled: false, privateContext: true), .iphone)
        settings.pageAnswers = .iPhone
        router.pageAnswers = { self.settings.pageAnswers }
        XCTAssertEqual(router.who(for: "remote", in: chat, aboutPage: true, fixturesEnabled: false, remoteChat: true), .claude)
    }

    func testUnavailableLocalModelAndNewPrivateConversationDoNotExportOrFakeAnswers() throws {
        let app = app()
        app.chatSheet.answerers.device = NoDeviceModel()
        let page = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/owned-page")!)
        app.ask("Owned public question", page: page)
        let publicChat = try XCTUnwrap(app.chats.chat(try XCTUnwrap(app.chatSheet.chatID)))
        XCTAssertEqual(publicChat.by, .iphone)
        XCTAssertEqual(publicChat.messages.map(\.role), [.you, .note])
        XCTAssertEqual(publicChat.messages.last?.text, Answerers.LocalFailure.unavailable.localizedDescription)
        XCTAssertNil(app.sync.engine)
        app.hideSheet()
        app.browser.showSpace("private")
        settings.pageAnswers = .mac
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertTrue(app.chats.isPrivate(id))
        XCTAssertEqual(app.chats.chat(id)?.by, .iphone)
        app.send("Owned private question")
        XCTAssertEqual(app.chats.chat(id)?.messages.map(\.role), [.you, .note])
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.text, Answerers.LocalFailure.unavailable.localizedDescription)
        XCTAssertFalse(app.chatSheet.sendingToMac.contains(id))
        XCTAssertTrue(app.chats.localEntries.allSatisfy { $0.chat.id != id })
    }

    func testMacPagePreferenceSendsTheChosenAgentWithoutCallingAvailableLocalModel() async throws {
        let app = app(), device = Device()
        app.chatSheet.answerers.device = device
        settings.pageAnswers = .mac
        settings.agent = .chatGPT
        let mac = try await join(app)
        defer { mac.client.stop(); app.sync.end() }
        let page = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/owned-page#source")!)
        app.ask("Owned Mac page question", page: page)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        let arrived = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertTrue(device.calls.isEmpty)
        let record = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertEqual(record["cli"]?.string, "codex")
        XCTAssertEqual(record["clientChat"]?.string, id)
        XCTAssertEqual(record["question"]?.string, "Owned Mac page question")
        let pageURL = try XCTUnwrap(page.url)
        XCTAssertTrue(record["agentText"]?.string?.contains(pageURL) == true)
        XCTAssertNil(record["text"])
        XCTAssertEqual(app.chats.chat(id)?.macCLI, "codex")
        XCTAssertEqual(ChatWords.line(try XCTUnwrap(app.chats.chat(id)), app: app), "Thinking")
        try mac.write(SyncCollection.send, record.id, ["state": "failed", "reason": "Owned unavailable account"])
        let failed = await until { app.chats.chat(id)?.messages.last?.role == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(app.chats.chat(id)?.macAgentName, "ChatGPT")
        XCTAssertEqual(ChatWords.line(try XCTUnwrap(app.chats.chat(id)), app: app), "ChatGPT · on your Mac")
    }

    func testAnOlderMacFailsBeforeAnyQuestionIsJournaledAndHasNoInventedProviderLabel() async throws {
        let app = app()
        settings.agent = .chatGPT
        let mac = try await join(app, oldMac: true)
        defer { mac.client.stop(); app.sync.end() }
        app.ask("Owned unsupported agent request", page: nil)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        let refused = await until { app.chats.chat(id)?.messages.last?.role == .failed }
        XCTAssertTrue(refused)
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.text, ChatAgent.unsupported)
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty)
        XCTAssertNil(app.chats.chat(id)?.macCLI)
        XCTAssertEqual(ChatWords.line(try XCTUnwrap(app.chats.chat(id)), app: app), "On your Mac")
    }

    func testContinuationKeepsTheActualHeadProviderAndRevokedMacCannotStartANewChat() async throws {
        let app = app()
        settings.agent = .chatGPT
        let mac = try await join(app)
        defer { mac.client.stop(); app.sync.end() }
        let now = Date().timeIntervalSince1970
        try mac.write(SyncCollection.chat, "a:owned", ["kind": "agent", "device": "mac-a", "title": "Owned remote", "state": "done",
                                                      "cli": "claude", "started": .number(now), "updated": .number(now)])
        let adopted = await until { app.chats.chat("a:owned") != nil }
        XCTAssertTrue(adopted)
        app.openChat("a:owned")
        app.send("Owned continuation")
        let sent = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(sent)
        let record = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertEqual(record["chat"]?.string, "a:owned")
        XCTAssertNil(record["cli"], "changing Settings cannot rebind an existing chat")
        XCTAssertEqual(app.chats.chat("a:owned")?.macCLI, "claude")
        let engine = try XCTUnwrap(app.sync.engine)
        try mac.journal.remove(.init(collection: OpenOnMac.capability, id: "mac-a"))
        mac.client.kick()
        let revoked = await until { !engine.canStartAgent(on: "mac-a") }
        XCTAssertTrue(revoked)
        XCTAssertThrowsError(try engine.startChat("Owned new question", on: "mac-a", agent: .codex))
        XCTAssertEqual(engine.sends().count, 1)
    }

    func testAcceptedMetadataSurvivesLocalEncodingAndUnknownAgentIsNotInvented() throws {
        let chat = Chat(id: "local", title: "Owned", by: .claude, macCLI: "codex")
        let decoded = try JSONDecoder().decode(Chat.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(decoded.macAgentName, "ChatGPT")
        let legacy = try JSONDecoder().decode(Chat.self, from: Data("{\"id\":\"old\",\"title\":\"Old\"}".utf8))
        XCTAssertNil(legacy.macCLI)
        let unknown = Chat(id: "unknown", title: "Owned", macCLI: "invented")
        XCTAssertNil(unknown.macAgentName)
    }

    func testRestoredRemoteIdentityWithoutItsHeadCannotStartAnotherProviderChat() async throws {
        let profile = BrowserProfile(folder: folder.appendingPathComponent("profile"))
        let local = LocalChatProfile(folder: profile.folder)
        let own = Chat(id: "old-local", title: "Owned previous conversation", by: .claude, macCLI: "claude",
                       messages: [Message(role: .you, text: "Owned earlier local question")])
        local.capture([.init(chat: own, draft: "Owned continuation draft", remoteChat: "a:restored")])
        await local.flush()
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        let store = settings!
        app.chatSheet.answerers.pageAnswers = { store.pageAnswers }
        app.chatSheet.answerers.macAgent = { store.agent }
        settings.agent = .chatGPT
        let mac = try await join(app)
        defer { mac.client.stop(); app.sync.end() }
        XCTAssertNotNil(app.chats.chat("a:restored"))
        XCTAssertNil(app.sync.engine?.chat("a:restored"))
        app.openChat("a:restored")
        XCTAssertEqual(app.chatSheet.draft, "Owned continuation draft")
        app.send(app.chatSheet.draft)
        let refused = await until { app.chats.chat("a:restored")?.messages.last?.role == .failed }
        XCTAssertTrue(refused)
        XCTAssertEqual(app.chats.chat("a:restored")?.messages.last?.text, SyncBridge.QuestionFailure.chatNotReady.localizedDescription)
        XCTAssertEqual(app.chats.chat("a:restored")?.messages.filter { $0.role == .you }.map(\.text),
                       ["Owned earlier local question", "Owned continuation draft"])
        XCTAssertEqual(app.chats.chat("a:restored")?.macCLI, "claude")
        XCTAssertTrue(app.sync.engine?.sends().isEmpty == true)
        XCTAssertTrue(mac.journal.living(SyncCollection.send).isEmpty)
    }
    func testActualProviderMetadataControlsAnswerHeadTypingAndTaskLabelsWithoutGuessing() throws {
        let app = app()
        settings.agent = .claude
        var chat = Chat(id: "accepted", title: "Owned", by: .claude, macCLI: "codex",
                        messages: [Message(role: .typing, by: .claude)])
        XCTAssertEqual(ChatWords.providerName(chat, app: app), "ChatGPT")
        XCTAssertEqual(ChatWords.status(chat, app: app).text, "ChatGPT is answering")
        chat.macCLI = "claude"
        settings.agent = .chatGPT
        XCTAssertEqual(ChatWords.providerName(chat, app: app), "Claude", "Settings cannot relabel an accepted provider")
        XCTAssertEqual(ChatWords.status(chat, app: app).text, "Claude is answering")
        chat.macCLI = nil
        XCTAssertEqual(ChatWords.providerName(chat, app: app), "Your Mac")
        XCTAssertEqual(ChatWords.status(chat, app: app).text, "Your Mac is answering")
        chat.macCLI = "unknown"
        XCTAssertEqual(ChatWords.providerName(chat, app: app), "Your Mac")
        chat.by = .iphone
        chat.messages = [Message(role: .typing, by: .iphone)]
        XCTAssertEqual(ChatWords.providerName(chat, app: app), "Apple Intelligence")
        XCTAssertEqual(ChatWords.status(chat, app: app).text, "Apple Intelligence is answering")
        chat.by = .claude
        chat.task = "owned-task"
        chat.messages = []
        XCTAssertEqual(ChatWords.line(chat, app: app), "On your Mac")
        chat.macCLI = "codex"
        XCTAssertEqual(ChatWords.line(chat, app: app), "On your Mac · ChatGPT")
        XCTAssertEqual(TaskChatSheet.line(.done, fixturesEnabled: false), "On your Mac")
        XCTAssertEqual(TaskChatSheet.line(.done, provider: "ChatGPT", fixturesEnabled: false), "On your Mac · ChatGPT")
        XCTAssertEqual(TaskChatSheet.line(.running, provider: "ChatGPT", fixturesEnabled: false), "Working · on your Mac")
        let fixture = AppModel(world: app.world)
        XCTAssertEqual(ChatWords.providerName(chat, app: fixture), "Claude")
        XCTAssertEqual(ChatWords.status(Chat(id: "fixture", title: "Owned", messages: [Message(role: .typing, by: .claude)]), app: fixture).text,
                       "Claude is answering")
        XCTAssertEqual(TaskChatSheet.line(.done), "On your Mac · Claude")
    }

}
