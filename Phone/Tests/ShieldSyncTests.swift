import SyncKit
import XCTest
@testable import YabPhone

/// The Mac's ad blocker reaches the iPhone through sync, read only: its
/// switch ("shield") and the sites it is off for ("shield.paused") are
/// settings the Mac already syncs (SyncShapes.settingKeys/settingPrefixes).
/// The iPhone follows them until told otherwise here, and writes nothing.
@MainActor
final class ShieldSyncTests: XCTestCase {
    private var folder: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var bridges: [SyncBridge] = []
    private var apps: [AppModel] = []
    private var macs: [TestMac] = []
    private var oldDisabled = false

    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        folder = URL(fileURLWithPath: "/private/tmp/yab-shield-sync-\(UUID())", isDirectory: true)
        suite = "owned-shield-sync-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled; defaults?.removePersistentDomain(forName: suite) }
        for app in apps { app.sync.end() }
        bridges.forEach { $0.end() }
        macs.forEach { $0.client.stop() }
        bridges = []; macs = []; apps = []; settings = nil
        try? await Task.sleep(for: .milliseconds(200))
        try? FileManager.default.removeItem(at: folder)
    }

    private func until(_ predicate: () -> Bool, seconds: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }

    private func require(_ predicate: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await until(predicate) else { XCTFail(message, file: file, line: line); throw NSError(domain: "ShieldSync", code: 1) }
    }

    private func app() -> AppModel {
        let world = World(name: "Shield sync", space: "public", spaces: [Space(id: "public", name: "Public", emoji: "", tint: RGB(235, 235, 235))])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        return app
    }

    private func attach(_ app: AppModel, _ server: SyncMemoryServer, _ seal: Seal) async throws -> SyncBridge {
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try seal.raw.write(to: folder.appendingPathComponent("keys/key-shared"))
        let bridge = SyncBridge(settings: settings)
        bridges.append(bridge)
        bridge.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                      folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                      deviceName: "Shield iPhone", transport: server, ownWorld: false))
        try await require({ bridge.line == .live }, "the iPhone's sync never went live")
        return bridge
    }

    private func mac(_ server: SyncMemoryServer, _ seal: Seal) async throws -> TestMac {
        let mac = try TestMac(server: server, seal: seal)
        macs.append(mac)
        mac.client.start()
        try await require({ mac.client.state == .live }, "the Mac's sync never went live")
        return mac
    }

    func testTheMacsSwitchAndSitesArriveAndLeaveWithTheAccount() async throws {
        let server = SyncMemoryServer(), seal = Seal.make(), made = app()
        let writer = try await mac(server, seal)
        // As the Mac's SyncShapes.settings writes them from its defaults.
        try writer.write(SyncCollection.setting, "shield", ["value": .bool(false)])
        try writer.write(SyncCollection.setting, "shield.paused", ["value": .array([.string("checkout.example"), .string("www.video.example")])])
        let bridge = try await attach(made, server, seal)
        try await require({ !self.settings.blocksAds }, "the Mac's switch off reached the iPhone")
        XCTAssertTrue(settings.macPausesAds(on: "checkout.example"))
        XCTAssertTrue(settings.macPausesAds(on: "video.example"))
        XCTAssertFalse(made.blocksAds(on: "news.example", isPrivate: false, settings: settings))

        try writer.write(SyncCollection.setting, "shield", ["value": .bool(true)])
        try await require({ self.settings.blocksAds }, "the Mac's switch on again reached the iPhone")
        XCTAssertTrue(made.blocksAds(on: "news.example", isPrivate: false, settings: settings))
        XCTAssertFalse(made.blocksAds(on: "checkout.example", isPrivate: false, settings: settings), "off where the Mac has it off")

        try writer.journal.remove(.init(collection: SyncCollection.setting, id: "shield.paused")); writer.client.kick()
        try await require({ !self.settings.macPausesAds(on: "checkout.example") }, "a removed list of sites went")
        XCTAssertNil(defaults.object(forKey: SettingsStore.Key.blocksAds), "the import stays read-only")

        try writer.write(SyncCollection.setting, "shield.paused", ["value": .array([.string("checkout.example")])])
        try await require({ self.settings.macPausesAds(on: "checkout.example") }, "the sites came back")
        bridge.end()
        XCTAssertFalse(settings.macPausesAds(on: "checkout.example"), "the account ended, its sites go")
        XCTAssertTrue(settings.blocksAds)
        let ours = bridge.setup?.keys.deviceID
        XCTAssertTrue(writer.journal.living(SyncCollection.setting).allSatisfy { $0.stamps.values.allSatisfy { $0.device != ours } },
                      "no settings record is written by the iPhone")
    }
}
