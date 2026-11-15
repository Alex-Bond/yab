import SyncKit
import UIKit
import XCTest
@testable import YabPhone

/// Real journals carry artwork access between a Mac and an owned iPhone
/// profile. Receiving a grant never asks UIKit to change the installed icon.
@MainActor
final class AppIconSyncTests: XCTestCase {
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
        folder = URL(fileURLWithPath: "/private/tmp/yab-app-icon-sync-\(UUID())", isDirectory: true)
        suite = "owned-app-icon-sync-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled; defaults?.removePersistentDomain(forName: suite) }
        bridges.forEach { $0.end() }
        apps.forEach { $0.sync.end() }
        macs.forEach { $0.client.stop() }
        bridges = []; macs = []; apps = []; settings = nil
        try? await Task.sleep(for: .milliseconds(200))
        try? FileManager.default.removeItem(at: folder)
    }

    func testInitialAndIncrementalAccountGrantsArriveAndLeaveWithoutChangingTheNativeIcon() async throws {
        let native = UIApplication.shared.alternateIconName
        let server = SyncMemoryServer(), seal = Seal.make()
        let writer = try await mac(server, seal)
        let receipt = String(repeating: "b", count: 64)
        try writer.write(SyncCollection.setting, AppIconCatalog.chrome.grantKey, ["value": .bool(true)])
        try writer.write(SyncCollection.setting, "gift.firstEdition.receipt", ["value": .string(receipt)])
        try await require({ writer.pending == 0 }, "the initial Mac grants never reached the account")
        let bridge = try await attach(server, seal)
        try await require({ self.settings.appIcons.imported == [.chrome, .firstEdition] },
                          "initial account artwork never reached the iPhone")
        XCTAssertTrue(settings.appIcons.unlocked(.chrome))
        XCTAssertTrue(settings.appIcons.unlocked(.firstEdition))
        XCTAssertFalse(settings.appIcons.unlocked(.ticket))
        XCTAssertEqual(UIApplication.shared.alternateIconName, native)

        try writer.write(SyncCollection.setting, AppIconCatalog.ticket.grantKey, ["value": .bool(true)])
        try writer.write(SyncCollection.setting, AppIconCatalog.chrome.grantKey, ["value": .bool(false)])
        try await require({ self.settings.appIcons.unlocked(.ticket) && !self.settings.appIcons.unlocked(.chrome) },
                          "incremental grants did not replace the previous account access")
        XCTAssertEqual(UIApplication.shared.alternateIconName, native)

        try writer.write(SyncCollection.setting, AppIconCatalog.charm.grantKey, ["value": .bool(true)])
        try writer.write(SyncCollection.setting, "invite.charm.left", ["value": .string("rose")])
        try writer.write(SyncCollection.setting, "invite.charm.right", ["value": .string("sky")])
        try await require({
            self.settings.appIcons.unlocked(.charm)
                && self.settings.appIcons.charmLeft == "rose" && self.settings.appIcons.charmRight == "sky"
        }, "Best Friends access and both colors never reached the iPhone")
        XCTAssertEqual(settings.appIcons.nativeName(for: .charm), AppIconCatalog.charmAlternateName(left: "rose", right: "sky"))
        try writer.write(SyncCollection.setting, "invite.charm.right", ["value": .string("lilac")])
        try await require({ self.settings.appIcons.charmRight == "lilac" }, "a friend's changed color did not reach the preview")
        XCTAssertEqual(UIApplication.shared.alternateIconName, native, "updated colors wait for an explicit native icon choice")

        try writer.journal.remove(.init(collection: SyncCollection.setting, id: "gift.firstEdition.receipt"))
        writer.client.kick()
        try await require({ !self.settings.appIcons.unlocked(.firstEdition) },
                          "a removed gift receipt left its artwork available")
        XCTAssertTrue(settings.appIcons.kept.isEmpty)
        XCTAssertNil(defaults.object(forKey: AppIconCatalog.ticket.grantKey), "account imports stay out of local defaults")
        XCTAssertNil(defaults.object(forKey: "gift.firstEdition.receipt"))

        let phone = bridge.ownDevice
        bridge.end()
        XCTAssertTrue(settings.appIcons.imported.isEmpty, "ending the account releases its imported artwork")
        XCTAssertFalse(settings.appIcons.unlocked(.ticket))
        XCTAssertFalse(settings.appIcons.unlocked(.charm))
        XCTAssertEqual(settings.appIcons.charmLeft, "mint")
        XCTAssertNil(settings.appIcons.charmRight)
        XCTAssertEqual(UIApplication.shared.alternateIconName, native)
        XCTAssertTrue(writer.journal.living(SyncCollection.setting).allSatisfy {
            $0.stamps.values.allSatisfy { $0.device != phone }
        }, "receiving artwork access never creates an ownership claim from the iPhone")
    }

    func testASeasonalIconWornOnThePhonePublishesItsOwnGrantAndSurvivesAccountEnd() async throws {
        let native = UIApplication.shared.alternateIconName
        let server = SyncMemoryServer(), seal = Seal.make()
        let writer = try await mac(server, seal)
        let bridge = try await attach(server, seal)
        let beforeEnd = AppIconCatalog.halloweenEnd().addingTimeInterval(-1)
        settings.appIcons.remember(.pumpkin, at: beforeEnd)
        let key = Record.Key(collection: SyncCollection.setting, id: AppIconCatalog.pumpkin.grantKey)
        try await require({ writer.journal.record(key).flatMap(SyncSetting.init)?.value.bool == true },
                          "the iPhone's worn seasonal icon never reached its Mac")
        XCTAssertNil(writer.journal.record(.init(collection: SyncCollection.setting, id: AppIconCatalog.ghost.grantKey)),
                     "unworn seasonal artwork earns no grant")
        XCTAssertEqual(UIApplication.shared.alternateIconName, native, "the receipt path has no native icon effect")

        bridge.end()
        let end = AppIconCatalog.halloweenEnd()
        XCTAssertTrue(settings.appIcons.imported.isEmpty)
        XCTAssertTrue(settings.appIcons.unlocked(.pumpkin, at: end))
        XCTAssertFalse(settings.appIcons.unlocked(.ghost, at: end))
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertTrue(reopened.appIcons.unlocked(.pumpkin, at: end), "the owned profile keeps the worn icon across relaunch")
        XCTAssertFalse(reopened.appIcons.unlocked(.ghost, at: end))
    }

    private func attach(_ server: SyncMemoryServer, _ seal: Seal) async throws -> SyncBridge {
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try seal.raw.write(to: folder.appendingPathComponent("keys/key-shared"))
        let world = World(name: "App icon sync", space: "public",
                          spaces: [Space(id: "public", name: "Public", emoji: "", tint: RGB(235, 235, 235))])
        let app = AppModel(world: world, fixturesEnabled: false, privateLockEnabled: { false })
        apps.append(app)
        let bridge = SyncBridge(settings: settings)
        bridges.append(bridge)
        bridge.attach(app, setup: .init(base: URL(string: "https://sync.test")!, keys: keys,
                                      folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                      deviceName: "App icons iPhone", transport: server, ownWorld: false))
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

    private func require(_ predicate: () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard predicate() else {
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "AppIconSync", code: 1)
        }
    }
}
