import QuartzCore
import SyncKit
import XCTest
@testable import YabPhone

/// Sync with a heavy account (PLAN-iphone.md 8.2): the `heavy` world's 12
/// spaces and 400-odd tabs on a Mac, and 2000 of its chats with their words,
/// joined by an iPhone. What the main thread pays: the longest stall while
/// the account comes in, a change made here, one coming from the Mac. The
/// journal is read and counted off the main thread; the numbers are printed
/// for the digest (sync-ios.md 11) and held to loose bounds here.
@MainActor
final class SyncHeavyTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-heavy-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func until(_ seconds: Double = 30, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    /// The longest the main thread didn't answer while `body` ran: a timer
    /// every 4 ms notes each gap.
    private final class Stalls {
        var longest: CFTimeInterval = 0
        private var last = CACurrentMediaTime()
        private var timer: Timer?
        func start() {
            last = CACurrentMediaTime()
            let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.longest = max(self.longest, now - self.last)
                self.last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        func stop() { timer?.invalidate() }
    }

    func testAHeavyAccountKeepsTheMainThreadFree() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal)
        // The heavy world as a Mac's records, in the Mac's encoding.
        let heavy = try World.load(named: "heavy")
        var ids = IDs()
        let records = SyncBridge.mirror(of: heavy.spaces, ids: &ids, keeping: SyncMirror())
        for space in records.spaces.values { try mac.journal.change(.init(collection: SyncCollection.space, id: space.id), space.fields) }
        for folder in records.folders.values { try mac.journal.change(.init(collection: SyncCollection.folder, id: folder.id), folder.fields) }
        for tab in records.tabs.values { try mac.journal.change(.init(collection: SyncCollection.tab, id: tab.id), tab.fields) }
        let now = Date().timeIntervalSince1970
        for i in 0..<2000 {
            let chat = "a:heavy\(i)"
            try mac.journal.change(.init(collection: SyncCollection.chat, id: chat), [
                "kind": "agent", "device": "mac-a", "title": .string("Chat \(i)"), "state": "done",
                "started": .number(now - Double(i) * 600), "updated": .number(now - Double(i) * 300), "cli": "claude",
            ])
            for n in 1...4 {
                try mac.journal.change(.init(collection: SyncCollection.chatItem, id: "\(chat)/i\(n)"), [
                    "chat": .string(chat), "n": .number(Double(n)), "kind": n % 2 == 1 ? "asked" : "message",
                    "text": .string(String(repeating: "Words of chat \(i), step \(n). ", count: 6)), "state": "done",
                ])
            }
        }
        let made = records.tabs.count + records.spaces.count + records.folders.count + 2000 * 5
        mac.client.start()
        let up = await until(60) { mac.client.state == .live && mac.pending == 0 }
        XCTAssertTrue(up, "the Mac's account is up: \(mac.pending) left")
        print("heavy account: \(records.spaces.count) spaces, \(records.tabs.count) tabs, \(records.folders.count) folders, 2000 chats, \(made) records")

        // The iPhone joins it (the key from iCloud Keychain).
        let keys = folder.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try seal.raw.write(to: keys.appendingPathComponent("key-shared"))
        let app = AppModel(world: World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))]))
        let stalls = Stalls()
        stalls.start()
        let joined = CACurrentMediaTime()
        app.sync.attach(app, setup: SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: .testing(folder: keys),
                                                     folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                                     deviceName: "Test iPhone", transport: server))
        let inStores = await until(60) { app.browser.spaces.count == 12 && app.chats.chats.count == 2000 }
        let catchUp = CACurrentMediaTime() - joined
        stalls.stop()
        XCTAssertTrue(inStores, "\(app.browser.spaces.count) spaces, \(app.chats.chats.count) chats")
        print(String(format: "heavy: join -> every space and chat in the stores %.0f ms; longest main-thread stall meanwhile %.0f ms",
                     catchUp * 1000, stalls.longest * 1000))

        // A relaunch: the journal read off the main thread. The old engine
        // goes first, as with an app that ended.
        weak var ended = app.sync.engine
        app.sync.end()
        _ = await until(5) { ended == nil }
        let again = AppModel(world: World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))]))
        let relaunch = Stalls()
        relaunch.start()
        let started = CACurrentMediaTime()
        again.sync.attach(again, setup: SyncBridge.Setup(base: URL(string: "https://sync.test")!, keys: .testing(folder: keys),
                                                         folder: folder.appendingPathComponent("journal"), seed: false, makesKey: false,
                                                         deviceName: "Test iPhone", transport: server))
        let attachTook = CACurrentMediaTime() - started
        let back = await until(30) { again.browser.spaces.count == 12 && again.chats.chats.count == 2000 }
        let shown = CACurrentMediaTime() - started
        relaunch.stop()
        XCTAssertTrue(back)
        print(String(format: "heavy relaunch: attach on the main thread %.1f ms; the journal's spaces and chats shown %.0f ms; longest stall %.0f ms",
                     attachTook * 1000, shown * 1000, relaunch.longest * 1000))
        let live = await until(10) { again.sync.line == .live }
        XCTAssertTrue(live)

        // A change made here: what the bridge writes, on the main thread.
        let space = try XCTUnwrap(again.browser.spaces.max { $0.today.count < $1.today.count })
        again.browser.showSpace(space.id)
        again.browser.open(Tab(id: UUID().uuidString, title: "Opened here", site: "Example", icon: "example", url: "example.com/heavy"))
        var t = CACurrentMediaTime()
        again.sync.flushLocal()
        let flush = CACurrentMediaTime() - t
        let reached = await until(10) { mac.journal.living(SyncCollection.tab).contains { $0["url"]?.string == "https://example.com/heavy" } }
        XCTAssertTrue(reached)
        print(String(format: "heavy: a tab opened in a space of %d -> written on the main thread in %.1f ms", space.today.count, flush * 1000))

        // Counting what waits: a count, off the main thread.
        t = CACurrentMediaTime()
        _ = try XCTUnwrap(again.sync.engine).pending
        print(String(format: "heavy: counting pending %.2f ms (off the main thread)", (CACurrentMediaTime() - t) * 1000))

        // One tab the Mac keeps in that space (kept: every device's, Today
        // being each device's own): the main thread's share.
        let arrive = Stalls()
        arrive.start()
        let id = "DDDDDDDD-0000-4000-8000-000000000001"
        let sent = CACurrentMediaTime()
        try mac.write(SyncCollection.tab, id, SyncTab(id: id, space: ids.sync(space.id), order: "0", url: "https://example.com/from-mac", title: "From the Mac",
                                                      kept: true).fields)
        let came = await until(10) { again.browser.tab(id) != nil }
        let took = CACurrentMediaTime() - sent
        try? await Task.sleep(for: .milliseconds(100))
        arrive.stop()
        XCTAssertTrue(came)
        print(String(format: "heavy: a Mac tab -> in the column %.0f ms (in memory); longest main-thread stall %.0f ms", took * 1000, arrive.longest * 1000))

        // Loose bounds: a regression shows, a busy Mac doesn't fail it.
        XCTAssertLessThan(attachTook, 0.25, "attach doesn't read the journal on the main thread")
        XCTAssertLessThan(flush, 0.1)
        XCTAssertLessThan(arrive.longest, 0.25)
    }
}
