import SyncKit
import XCTest
@testable import YabPhone

/// What the Mac link's tests share (SendToPhoneTests, PhonePresenceTests,
/// SyncDevicesTests, ScanJoinTests): a folder of their own, a Mac on the
/// server in memory, the iPhone's engine or the whole app in sync.
@MainActor
class PhoneLinkTestCase: XCTestCase {
    var folder: URL!
    let essay = URL(string: "https://paulgrahamcom.com")!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("send-to-phone-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    final func until(_ seconds: Double = 5, _ done: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    final func engine(_ server: any Transport, _ seal: Seal) throws -> PhoneSync {
        try PhoneSync(seal: seal, options: .init(base: URL(string: "https://sync.test")!, folder: folder.appendingPathComponent("engine"),
                                                  device: .init(id: "phone", name: "Test iPhone", model: "iPhone18,1"),
                                                  transport: server))
    }

    final func mac(_ server: SyncMemoryServer, _ seal: Seal) async throws -> TestMac {
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        mac.client.start()
        let live = await until { mac.client.state == .live }
        XCTAssertTrue(live)
        return mac
    }

    /// Mira's world with the bridge attached, as a named state has it: no
    /// server, a pretend Mac.
    final func miraApp() throws -> AppModel {
        let app = AppModel(world: try World.load(named: "mira"))
        app.sync.attach(app, setup: nil)
        return app
    }

    /// The iPhone in, with the key iCloud Keychain brought.
    final func joinedPhone(_ server: any Transport, _ seal: Seal) async throws -> AppModel {
        let keys = folder.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let app = AppModel(world: World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))]))
        app.sync.attach(app, setup: setup(server))
        let live = await until { app.sync.line == .live }
        XCTAssertTrue(live, "the iPhone's line: \(app.sync.line)")
        return app
    }

    final func setup(_ server: any Transport) -> SyncBridge.Setup {
        SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: .testing(folder: folder.appendingPathComponent("keys")),
                         folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false, deviceName: "Test iPhone",
                         transport: server, refreshEvery: 0.2)
    }
}
