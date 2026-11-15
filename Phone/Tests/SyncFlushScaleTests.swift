import QuartzCore
import SyncKit
import XCTest
@testable import YabPhone

/// #547 (iPad, scene-create watchdog): the sync of the iPhone's tabs
/// (SyncBridge.flushLocal, on the main thread whenever a store changes)
/// asked which folder holds each tab with KeptTree.path, a walk and copy of
/// the folder tree for every tab, kept, pinned or today's.
@MainActor
final class SyncFlushScaleTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-flush-scale-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tab(_ id: String) -> Tab {
        Tab(id: id, title: "Page \(id)", site: "Example", icon: "globe", url: "https://example.test/\(id)")
    }

    func testHoldersAnswerAsPathDoesForEveryTab() {
        let inner = Folder(id: "inner", name: "Inner", open: true, items: [.tab(tab("deep-1")), .tab(tab("deep-2"))])
        let outer = Folder(id: "outer", name: "Outer", open: false,
                           items: [.tab(tab("outer-1")), .folder(inner), .tab(tab("outer-2"))])
        let items: [KeptItem] = [
            .tab(tab("root-1")), .folder(outer),
            .folder(Folder(id: "empty", name: "Empty", tabs: [])),
            .folder(Folder(id: "plain", name: "Plain", tabs: [tab("plain-1")])), .tab(tab("root-2")),
        ]
        let holders = KeptTree.holders(items)
        for tab in KeptTree.tabs(items) {
            XCTAssertEqual(holders[tab.id], KeptTree.path(to: tab.id, in: items).last?.id, tab.id)
        }
        XCTAssertEqual(holders, ["outer-1": "outer", "outer-2": "outer", "deep-1": "inner", "deep-2": "inner", "plain-1": "plain"])
        XCTAssertNil(holders["root-1"])
    }

    private func until(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// An iPhone in sync with a Mac's space of `count` kept tabs in folders
    /// of ten; then how long a flush with nothing changed takes.
    private func unchangedFlush(_ count: Int) async throws -> Double {
        let home = folder.appendingPathComponent("\(count)")
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        defer { mac.client.stop() }
        let work = "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10"
        try mac.write(SyncCollection.space, SyncCollection.firstSpace,
                      SyncSpace(id: SyncCollection.firstSpace, name: "Personal", icon: "🏠", order: "V").fields)
        try mac.write(SyncCollection.space, work, SyncSpace(id: work, name: "Work", icon: "💼", order: "X").fields)
        for start in stride(from: 0, to: count, by: 10) {
            let fid = String(format: "F0000000-0000-4000-8000-%012d", start)
            try mac.write(SyncCollection.folder, fid,
                          SyncFolder(id: fid, space: work, order: String(format: "F%06d", start), name: "Folder \(start)", open: true).fields)
            for index in start..<min(start + 10, count) {
                let tid = String(format: "AAAAAAAA-0000-4000-8000-%012d", index)
                try mac.write(SyncCollection.tab, tid, SyncTab(id: tid, space: work, order: String(format: "T%06d", index),
                                                              url: "https://example.test/\(index)", title: "Page \(index)",
                                                              kept: true, folder: fid).fields)
            }
        }
        mac.client.start()
        let up = await until(30) { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac made the account")

        let keys = home.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let app = AppModel(world: World(name: "test", space: "home", spaces: [
            Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226)),
        ]))
        app.sync.attach(app, setup: SyncBridge.Setup(
            base: URL(string: "https://sync.test")!, keys: .testing(folder: keys), folder: home.appendingPathComponent("journal"),
            seed: false, makesKey: false, deviceName: "Test iPhone", transport: server,
            onlineFor: PhoneSync.onlineFor, refreshEvery: 60, ownWorld: true))
        let loaded = await until(30) { app.browser.space(app.sync.localID(work))?.keptTabs.count == count }
        XCTAssertTrue(loaded, "the iPhone has the Mac's \(count) kept tabs")
        app.sync.flushLocal()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            app.sync.flushLocal()
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        XCTAssertGreaterThan(samples.max() ?? 0, 0.1, "the flush ran (the iPhone writes)")
        return samples.sorted()[2]
    }

    /// Four times the kept tabs: about four times the work, not sixteen.
    func testUnchangedFlushScalesLinearlyWithKeptTabs() async throws {
        let small = try await unchangedFlush(250), large = try await unchangedFlush(1000)
        let ratio = large / max(small, 0.001)
        print("SYNC_FLUSH unchanged_ms 250=\(small) 1000=\(large) ratio=\(ratio)")
        let data = try JSONSerialization.data(withJSONObject: ["flush_250_ms": small, "flush_1000_ms": large, "ratio": ratio],
                                              options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "sync-flush-scale.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(ratio, 8, "a flush must not walk the folder tree once for every tab")
    }
}
