import SyncKit
import XCTest
@testable import YabPhone

/// History and sync against a Mac on a server in memory: the Mac's places
/// come into History with its name, the iPhone's visits go into the Mac's
/// visit records (the last two weeks, sent again on joining), never a private
/// tab's or a sign-in step's, and none at all with History in Sync off.
@MainActor
final class HistorySyncTests: XCTestCase {
    private var folder: URL!
    private let first = SyncCollection.firstSpace

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-sync-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        SettingsStore.shared.syncHistory = true
        try? FileManager.default.removeItem(at: folder)
    }

    private func until(_ seconds: Double = 6, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func macVisit(_ mac: TestMac, url: String) -> Record? {
        mac.journal.living(SyncCollection.visit).first { $0["url"]?.string == url }
    }

    func testTheIPhonesVisitsGoToTheMacAndTheMacsComeHere() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
        let macPage = SyncVisit(url: "https://lumen.events/e/design-systems-night", title: "Design Systems Night",
                                last: Date().timeIntervalSince1970.rounded(.down) - 600)
        try mac.write(SyncCollection.visit, macPage.id, macPage.fields)
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account")

        // A visit from before joining, and the iPhone's profile.
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let before = PageFixtures.liveTab(for: URL(string: "https://example.org/before")!, title: "Read before joining")
        profile.recordVisit(before)
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: keys,
                                                     folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                                     deviceName: "Test iPhone", transport: server, ownWorld: false))
        let live = await until { app.sync.line == .live }
        XCTAssertTrue(live, "the iPhone's line: \(app.sync.line)")

        // The Mac's page is in History, saying the Mac.
        let arrived = await until { app.history.entries.contains { $0.isSynced && $0.device == "MacBook Pro" } }
        XCTAssertTrue(arrived, "\(app.history.entries.map { ($0.title, $0.device) })")
        XCTAssertEqual(app.history.entries.first { $0.isSynced }?.title, "Design Systems Night")

        // What this iPhone read before joining went up as it joined.
        let sentBefore = await until { self.macVisit(mac, url: "https://example.org/before") != nil }
        XCTAssertTrue(sentBefore, "the last two weeks go when sync starts writing")

        // A page opened now: the profile records it, and it goes to the Mac.
        let page = PageFixtures.liveTab(for: URL(string: "https://example.org/now?ref=phone")!, title: "Read on the iPhone")
        app.browser.open(page)
        profile.recordVisit(page)
        app.history.recorded(page)
        let sent = await until { self.macVisit(mac, url: "https://example.org/now?ref=phone") != nil }
        XCTAssertTrue(sent, "the visit reached the Mac")
        let record = try XCTUnwrap(macVisit(mac, url: "https://example.org/now?ref=phone"))
        XCTAssertEqual(record.id, "example.org/now", "the Mac's key: no query")
        XCTAssertEqual(record["title"]?.string, "Read on the iPhone")
        XCTAssertEqual(record.stamps["last"]?.device, app.sync.engine?.options.device.id, "stamped as this iPhone's")
        // This iPhone's own record is never the Mac's page here.
        XCTAssertFalse(app.history.entries.contains { $0.isSynced && $0.url.contains("example.org") })
        XCTAssertEqual(app.history.entries.filter { $0.url == "https://example.org/now?ref=phone" }.count, 1)

        // Never a private tab's, nor a sign-in step's.
        let secret = PageFixtures.liveTab(for: URL(string: "https://example.org/secret")!, isPrivate: true, title: "Secret")
        app.history.recorded(secret)
        app.sync.sendVisit(URL(string: "https://accounts.example.org/auth?client_id=a&redirect_uri=b")!, title: "Sign in", at: Date())
        // With History in Sync off, nothing more goes.
        SettingsStore.shared.syncHistory = false
        let quiet = PageFixtures.liveTab(for: URL(string: "https://example.org/quiet")!, title: "Not sent")
        app.browser.open(quiet)
        profile.recordVisit(quiet)
        app.history.recorded(quiet)
        // On again: what the Mac missed goes now.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(macVisit(mac, url: "https://example.org/quiet"), "off: not sent")
        SettingsStore.shared.syncHistory = true
        let caughtUp = await until { self.macVisit(mac, url: "https://example.org/quiet") != nil }
        XCTAssertTrue(caughtUp, "turned on again, the last two weeks go")
        let urls = mac.journal.living(SyncCollection.visit).compactMap { $0["url"]?.string }
        XCTAssertFalse(urls.contains { $0.contains("secret") || $0.contains("client_id") }, "\(urls)")

        // A place the Mac goes to later comes in as it happens.
        let later = SyncVisit(url: "https://example.org/now?ref=mac", title: "Read on the Mac too", last: Date().timeIntervalSince1970.rounded(.down) + 120)
        try mac.write(SyncCollection.visit, later.id, later.fields)
        let moved = await until { app.history.entries.first?.isSynced == true && app.history.entries.first?.title == "Read on the Mac too" }
        XCTAssertTrue(moved, "\(app.history.entries.prefix(3).map(\.title))")
        app.sync.end()
    }

    /// A newly joined iPhone hears the Mac's two weeks as one catch-up:
    /// hundreds of places, read from the journal at once, each saying the Mac.
    func testAMacsTwoWeeksArriveInOneRead() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        try mac.write(SyncCollection.space, first, SyncSpace(id: first, name: "Personal", icon: "🏠", order: "V").fields)
        mac.client.start()
        let up = await until { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account")
        let profile = BrowserProfile(folder: folder.appendingPathComponent("browser"))
        let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
        let keys = SyncKeychain.testing(folder: folder.appendingPathComponent("keys"))
        keys.keep(seal, share: false)
        app.sync.attach(app, setup: SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: keys,
                                                     folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                                     deviceName: "Test iPhone", transport: server, ownWorld: false))
        let live = await until { app.sync.line == .live }
        XCTAssertTrue(live, "the iPhone's line: \(app.sync.line)")
        let now = Date().timeIntervalSince1970.rounded(.down)
        let count = SyncBridge.visitsReadOneByOne * 3
        for n in 0..<count {
            let visit = SyncVisit(url: "https://mac.test/page/\(n)", title: "Page \(n)", last: now - Double(n * 60))
            try mac.journal.change(.init(collection: SyncCollection.visit, id: visit.id), visit.fields)
        }
        mac.client.kick()
        let arrived = await until(10) { app.history.entries.filter(\.isSynced).count == count }
        XCTAssertTrue(arrived, "\(app.history.entries.filter(\.isSynced).count) of \(count)")
        let named = await until { app.history.entries.allSatisfy { $0.device == "MacBook Pro" } }
        XCTAssertTrue(named, "\(Set(app.history.entries.map(\.device)))")
        XCTAssertEqual(app.history.entries.first?.title, "Page 0")
        app.sync.end()
    }
}
