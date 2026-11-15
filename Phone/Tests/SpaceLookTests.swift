import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class SpaceLookTests: XCTestCase {
    private let work = "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10"
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceLookTests-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func importedLook() throws -> SpaceLook {
        try XCTUnwrap(SpaceLook(.object(["swatch": "custom", "color": "#A8C3A0", "colors": .array(["#8DB6E6", "#EEA2C4"]),
            "grain": true, "grainAmount": 0.35, "transparency": 0.2, "shift": true, "site": true,
            "drawings": "flowers", "drawingsStrength": 0.62, "futureEffect": .object(["version": 3, "enabled": true]) ])))
    }
    private func world(look: SpaceLook? = nil) -> World {
        let tab = PageFixtures.liveTab(for: URL(string: "http://127.0.0.1/work?q=Original#section")!, id: "tab")
        return World(name: "test", space: work, spaces: [Space(id: work, name: "Work", emoji: "💼", tint: RGB(226, 233, 244),
                     pins: [tab], current: tab.id, look: look, ownSignIns: true)])
    }

    func testEditingMetadataAndLookSurvivesProfileReloadWithoutChangingPageIdentity() async throws {
        let profile = BrowserProfile(folder: directory)
        let browser = BrowserStore(world: world(look: try importedLook()), fixturesEnabled: false)
        let before = try XCTUnwrap(browser.space(work))
        var look = try XCTUnwrap(before.look)
        look.setPalette(LookColor(RGB(242, 131, 124)), following: [LookColor(RGB(141, 182, 230))])
        look.setGrain(0.72); look.setTransparency(0.48)
        browser.setSpace(work, name: "Research", emoji: "🔭", look: look)
        profile.capture(browser)
        await profile.flush()
        let restored = BrowserProfile(folder: directory)
        let space = try XCTUnwrap(restored.snapshot.spaces.first)
        XCTAssertEqual(space.id, before.id)
        XCTAssertEqual(space.name, "Research"); XCTAssertEqual(space.emoji, "🔭")
        XCTAssertEqual(space.pins, before.pins); XCTAssertEqual(space.current, before.current)
        XCTAssertEqual(space.look, look)
        XCTAssertTrue(space.ownSignIns)
        XCTAssertEqual(space.look?.raw.object?["futureEffect"], before.look?.raw.object?["futureEffect"])
        XCTAssertEqual(space.look?.raw.object?["drawings"], "flowers")
        XCTAssertEqual(space.tint, look.wash, "the look's wash is the tint, as sync makes it from the Mac's look")
    }

    func testLegacyProfileKeepsItsExactWashUntilAnActualLookEdit() throws {
        let before = try XCTUnwrap(world().spaces.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        object.removeValue(forKey: "look"); object.removeValue(forKey: "ownSignIns")
        let legacy = try JSONDecoder().decode(Space.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.look); XCTAssertFalse(legacy.ownSignIns)
        XCTAssertEqual(legacy.pins, before.pins); XCTAssertEqual(legacy.tint, before.tint)
        let app = AppModel(world: World(name: "legacy", space: legacy.id, spaces: [legacy]))
        let draft = SpaceTrayModel()
        draft.start(.color, space: legacy)
        draft.commit(in: app.browser)
        XCTAssertNil(app.browser.space.look, "opening or closing the editor alone is not an edit")
    }

    func testRemotePaintAndEmojiChangesWhileEditingKeepUntouchedFields() throws {
        let original = try importedLook()
        let browser = BrowserStore(world: world(look: original))
        let draft = SpaceTrayModel(); draft.start(.color, space: browser.space)
        var picked = original
        picked.setPalette(LookColor(RGB(238, 162, 196)), following: [])
        draft.changeLook(picked); draft.rename("Research")
        var remote = original
        remote.setGrain(0.88); remote.setTransparency(0.67)
        var fields = try XCTUnwrap(remote.raw.object)
        fields["futureEffect"] = .object(["version": 4, "enabled": false])
        remote = try XCTUnwrap(SpaceLook(.object(fields)))
        browser.setSpace(work, emoji: "📚", look: remote)
        draft.commit(in: browser)
        let saved = try XCTUnwrap(browser.space.look)
        XCTAssertEqual(browser.space.name, "Research"); XCTAssertEqual(browser.space.emoji, "📚")
        XCTAssertEqual(saved.primary, picked.primary)
        XCTAssertEqual(saved.grain, 0.88); XCTAssertEqual(saved.transparency, 0.67)
        XCTAssertEqual(saved.raw.object?["futureEffect"], remote.raw.object?["futureEffect"])
        XCTAssertTrue(browser.space.ownSignIns)
    }

    func testPrivateMetadataCannotBeEditedOrSerializedAndCancelDoesNotCreateASpace() async throws {
        let browser = BrowserStore(world: world(), fixturesEnabled: false)
        let privateSpace = try XCTUnwrap(browser.spaces.first(where: \.isPrivate))
        browser.setSpace(privateSpace.id, name: "Secret", emoji: "🔒", look: try importedLook())
        XCTAssertEqual(browser.space(privateSpace.id), privateSpace)
        let draft = SpaceTrayModel(); draft.start(.name, space: browser.space, creating: true)
        draft.rename("Not created"); draft.pickEmoji("📚"); draft.commit(in: browser)
        XCTAssertEqual(browser.spaces.count, 2)
        let profile = BrowserProfile(folder: directory); profile.capture(browser); await profile.flush()
        let saved = try String(contentsOf: directory.appendingPathComponent("profile.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains(privateSpace.id)); XCTAssertFalse(saved.contains("Not created")); XCTAssertFalse(saved.contains("Secret"))
    }

    func testCreateUsesOneStablePublicUUIDAndAnEmptyRealSpaceAcrossLaunches() async throws {
        let browser = BrowserStore(world: world(), fixturesEnabled: false)
        let id = browser.createSpace(name: "  Reading  ", emoji: "📚", look: try importedLook())
        XCTAssertNotNil(UUID(uuidString: id)); XCTAssertEqual(browser.spaceID, id)
        XCTAssertTrue(browser.space.allTabs.isEmpty); XCTAssertFalse(browser.space.isPrivate)
        let profile = BrowserProfile(folder: directory); profile.capture(browser); await profile.flush()
        let restored = BrowserStore(world: BrowserProfile(folder: directory).world, fixturesEnabled: false)
        XCTAssertEqual(restored.spaceID, id); XCTAssertEqual(restored.space.name, "Reading")
        XCTAssertEqual(restored.space.look, browser.space.look)
        XCTAssertEqual(restored.spaces.filter { $0.id == id }.count, 1)
        XCTAssertTrue(restored.space.allTabs.isEmpty)
    }

    func testPhoneEditsAndCreationReachTheOtherClientWithoutLosingUnknownPaintOrSignIns() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        defer { mac.client.stop() }
        let look = try importedLook()
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", ownSignIns: true,
                            paint: SyncPaint(look.raw), origin: "Arc:original", order: "V").fields)
        try mac.write(SyncCollection.tab, "AAAAAAAA-0000-4000-8000-000000000001", SyncTab(id: "AAAAAAAA-0000-4000-8000-000000000001", space: work,
                            order: "A", url: "http://127.0.0.1/preserved", title: "Preserved page", kept: true).fields)
        mac.client.start()
        let macReady = await until { mac.client.state == .live && mac.pending == 0 }; XCTAssertTrue(macReady)
        let keys = directory.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let app = AppModel(world: world())
        app.sync.attach(app, setup: SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: .testing(folder: keys),
            folder: directory.appendingPathComponent("journal"), seed: false, makesKey: false, deviceName: "Test iPhone", transport: server))
        defer { app.sync.end() }
        let arrived = await until { app.sync.line == .live && app.browser.space(self.work)?.look == look }; XCTAssertTrue(arrived)
        var edited = look; edited.setGrain(0.71); edited.setTransparency(0.44)
        app.browser.setSpace(work, name: "Research", emoji: "🔭", look: edited)
        let created = app.browser.createSpace(name: "Reading", emoji: "📚", look: edited)
        app.sync.flushLocal()
        let delivered = await until {
            mac.journal.record(.init(collection: SyncCollection.space, id: self.work))?["name"]?.string == "Research"
                && mac.journal.record(.init(collection: SyncCollection.space, id: created))?["name"]?.string == "Reading"
                && mac.journal.record(.init(collection: SyncCollection.space, id: self.work))?["paint"] == edited.raw
        }
        XCTAssertTrue(delivered)
        let record = try XCTUnwrap(mac.journal.record(.init(collection: SyncCollection.space, id: work)))
        XCTAssertEqual(record["ownSignIns"], true); XCTAssertEqual(record["origin"], "Arc:original")
        XCTAssertEqual(record["paint"]?.object?["futureEffect"], look.raw.object?["futureEffect"])
        XCTAssertEqual(mac.row(work).kept.first?.url, "http://127.0.0.1/preserved")
        let settled = await until { app.sync.engine?.client.state == .live && app.sync.engine?.journal.pending(limit: 100).isEmpty == true }
        XCTAssertTrue(settled)
        let phoneRecord = try XCTUnwrap(app.sync.engine?.journal.record(.init(collection: SyncCollection.space, id: work)))
        let stamps = phoneRecord.stamps
        app.sync.flushLocal()
        XCTAssertEqual(app.sync.engine?.journal.record(.init(collection: SyncCollection.space, id: work))?.stamps, stamps, "the remote echo does not write another edit")
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
