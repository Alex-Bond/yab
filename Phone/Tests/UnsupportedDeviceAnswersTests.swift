import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class UnsupportedDeviceAnswersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var folder: URL!

    override func setUp() async throws {
        suite = "UnsupportedDeviceAnswersTests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    func testUnsupportedDeviceDefaultsToMacWithoutOverwritingAnExplicitLocalChoice() throws {
        let settings = SettingsStore(defaults: defaults, supportsOnDeviceAnswers: false)
        XCTAssertEqual(settings.pageAnswers, .mac, "an ineligible iPhone must not default to an unusable local model")
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.pageAnswers), "a default is not a saved choice")
        settings.pageAnswers = .iPhone
        XCTAssertEqual(SettingsStore(defaults: defaults, supportsOnDeviceAnswers: false).pageAnswers, .iPhone, "an explicit local choice must never export pages")
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testUnsupportedDeviceSendsPublicPageToConnectedClaudeAndKeepsPrivateLocal() async throws {
        let settings = SettingsStore(defaults: defaults, supportsOnDeviceAnswers: false)
        let world = World(name: "unsupported-device", space: "public", spaces: [
            Space(id: "public", name: "Public", emoji: "", tint: RGB(240, 240, 240)),
            Space(id: "private", name: "Private", emoji: "", tint: RGB(240, 240, 240), isPrivate: true)
        ])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        app.chatSheet.answerers.device = NoDeviceModel()
        app.chatSheet.answerers.pageAnswers = { settings.pageAnswers }
        app.chatSheet.answerers.macAgent = { settings.agent }
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, agentSelection: true)
        mac.client.start()
        defer { mac.client.stop(); app.sync.end() }
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                         folder: folder.appendingPathComponent("journal"), seed: false,
                                         makesKey: false, deviceName: "Unsupported iPhone", transport: server,
                                         ownWorld: true))
        let ready = await until { app.sync.ready && app.sync.line == .live && app.sync.engine?.canStartAgent(on: "mac-a") == true }
        XCTAssertTrue(ready)
        let page = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/unsupported-device-page")!)
        app.ask("summarize", page: page)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        let sent = await until { mac.journal.living(SyncCollection.send).count == 1 }
        XCTAssertTrue(sent, "the public page request must reach the connected Mac without Apple Intelligence")
        let request = try XCTUnwrap(mac.journal.living(SyncCollection.send).first)
        XCTAssertEqual(request["cli"]?.string, "claude")
        XCTAssertEqual(request["question"]?.string, "summarize")
        XCTAssertTrue(request["agentText"]?.string?.contains(try XCTUnwrap(page.url)) == true)
        let now = Date().timeIntervalSince1970
        try mac.write(SyncCollection.send, request.id, ["state": "taken", "chat": "a:unsupported", "took": .number(now)])
        try mac.write(SyncCollection.chat, "a:unsupported", ["kind": "agent", "device": "mac-a", "title": "Summary",
                                                          "state": "done", "cli": "claude", "started": .number(now), "updated": .number(now + 1)])
        try mac.write(SyncCollection.chatItem, "a:unsupported/1", ["chat": "a:unsupported", "n": 1, "kind": "asked", "text": "summarize", "began": .number(now)])
        try mac.write(SyncCollection.chatItem, "a:unsupported/2", ["chat": "a:unsupported", "n": 2, "kind": "message", "text": "Connected Claude summary", "began": .number(now + 1)])
        let answered = await until { app.chats.chat("a:unsupported")?.messages.contains { $0.role == .answer && $0.text == "Connected Claude summary" } == true }
        XCTAssertTrue(answered, "the connected provider's answer must return to the iPhone")
        XCTAssertFalse(app.chats.chat(id)?.messages.contains { $0.text == Answerers.LocalFailure.unavailable.localizedDescription } == true)
        app.hideSheet()
        app.browser.showSpace("private")
        app.ask("private summary", page: page)
        let privateID = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertEqual(app.chats.chat(privateID)?.by, .iphone)
        XCTAssertEqual(app.chats.chat(privateID)?.messages.last?.text, Answerers.LocalFailure.unavailable.localizedDescription)
        XCTAssertEqual(mac.journal.living(SyncCollection.send).count, 1, "private questions stay on this iPhone")
    }
}
