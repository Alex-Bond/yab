import Darwin
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// All Tabs' and the stack's pictures: the store (TabPictures: cut to a
/// card, written, read back after a launch, let go past its memory, pruned
/// as tabs close, cleared, a private tab's never on disk), what takes them
/// (TabStack: a page left, a page drawn and settled, Yab going away) and the
/// warm-up (TabWarmup: bounded, nearest first, stopped with All Tabs), with
/// its time and memory measured on the fixture world's real pages
/// (`tab-pictures.measure` lines in the log).
@MainActor
final class TabPicturesTests: XCTestCase {
    private var folders: [URL] = []
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false

    /// iPhone 17 Pro: the page down to the chrome's row (874 - 28 - 48), the
    /// widest card (0.78 of 402) at 3x.
    private let shape = TabPictures.Shape(width: 402, height: 798, pixels: 941)

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }

    override func tearDown() {
        Motion.disabled = oldDisabled
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        previousKey?.makeKey()
    }

    private func folder() -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("tab-pictures-\(UUID().uuidString)", isDirectory: true)
        folders.append(made)
        return made
    }

    private func files(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jpg") }
    }

    /// A whole page's picture as the pool takes it: 402 x 874 points at 3x,
    /// `color` down to the chrome's row, black below it (to see it cut).
    private func page(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 402, height: 874)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 798, width: size.width, height: size.height - 798))
        }
    }

    private func keep(_ store: TabPictures, _ image: UIImage, _ id: String, isPrivate: Bool = false) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            store.keep(image, for: id, isPrivate: isPrivate) { done.resume() }
        }
        await store.settled()
    }

    private func until(_ predicate: () -> Bool, _ message: String, timeout: TimeInterval = 25,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), message, file: file, line: line)
    }

    /// The red, green and blue of one pixel of a picture, 0 to 255.
    private func pixel(_ image: UIImage, x: Int, y: Int) -> (Int, Int, Int) {
        guard let cg = image.cgImage else { return (-1, -1, -1) }
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    // MARK: - the store

    func testAPictureIsCutToACardAndReadBackAfterALaunch() async throws {
        let folder = folder()
        let store = TabPictures(folder: folder, shape: shape)
        await keep(store, page(.red), "work-hn")
        let kept = try XCTUnwrap(store.image(for: "work-hn"))
        // The page in points from the screen's top down to the chrome's row,
        // in a card's pixels.
        XCTAssertEqual(kept.size.width, 402, accuracy: 0.5)
        XCTAssertEqual(kept.size.height, 798, accuracy: 1)
        XCTAssertEqual(kept.cgImage?.width, 941)
        XCTAssertEqual(kept.cgImage?.height, 1868)
        XCTAssertEqual(files(folder), [store.name("work-hn")])
        let bytes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(store.name("work-hn")).path)[.size] as? Int
        print("tab-pictures.measure file bytes=\(bytes ?? -1) pixels=941x1868")

        // The next launch: on disk, read as it is first asked for.
        let next = TabPictures(folder: folder, shape: shape)
        XCTAssertTrue(next.has("work-hn"))
        XCTAssertFalse(next.isInMemory("work-hn"))
        var changed = 0
        next.onChange = { changed += 1 }
        XCTAssertNil(next.image(for: "work-hn"), "never read on the main thread as it is drawn")
        await until({ changed > 0 }, "the picture wasn't read back")
        let read = try XCTUnwrap(next.image(for: "work-hn"))
        XCTAssertEqual(read.size.width, 402, accuracy: 0.5)
        XCTAssertEqual(read.size.height, 798, accuracy: 1)
        let bottom = pixel(read, x: 470, y: 1860)
        XCTAssertGreaterThan(bottom.0, 200, "the page down to the chrome's row, nothing under it: \(bottom)")
        XCTAssertLessThan(bottom.1, 60)
        XCTAssertFalse(next.has("work-gh-pr"))
    }

    func testPastItsMemoryTheLeastRecentlyDrawnGoAndComeBackFromTheDisk() async throws {
        let folder = folder()
        let one = 941 * 4 * 1868
        let store = TabPictures(folder: folder, shape: shape, memoryLimit: one * 2 + one / 2)
        await keep(store, page(.red), "a")
        await keep(store, page(.green), "b")
        _ = store.image(for: "a")
        await keep(store, page(.blue), "c")
        // Drawn just now, all three stay (the cards on screen keep theirs).
        XCTAssertTrue(store.isInMemory("a") && store.isInMemory("b") && store.isInMemory("c"))
        store.trim(now: TabPictures.now + 1)
        XCTAssertLessThanOrEqual(store.memoryCost, store.memoryLimit)
        XCTAssertFalse(store.isInMemory("b"), "the least recently drawn goes first")
        XCTAssertTrue(store.isInMemory("a"))
        XCTAssertTrue(store.isInMemory("c"))
        XCTAssertTrue(store.has("b"), "still on disk")
        var changed = 0
        store.onChange = { changed += 1 }
        XCTAssertNil(store.image(for: "b"))
        await until({ changed > 0 }, "b wasn't read back")
        XCTAssertNotNil(store.image(for: "b"))
    }

    func testAPrivateTabsPictureNeverTouchesTheDiskAndGoesAsPrivateLocks() async {
        let folder = folder()
        let store = TabPictures(folder: folder, shape: shape)
        await keep(store, page(.red), "private-work-hn", isPrivate: true)
        await keep(store, page(.green), "work-hn")
        XCTAssertTrue(store.isInMemory("private-work-hn"))
        XCTAssertFalse(store.isOnDisk("private-work-hn"))
        XCTAssertEqual(files(folder), [store.name("work-hn")], "only the ordinary tab's file")
        store.dropPrivate()
        XCTAssertFalse(store.has("private-work-hn"))
        XCTAssertTrue(store.has("work-hn"))
    }

    func testClearTakesEveryOrdinaryPictureFromMemoryAndDisk() async {
        let folder = folder()
        let store = TabPictures(folder: folder, shape: shape)
        await keep(store, page(.red), "work-hn")
        await keep(store, page(.green), "work-gh-pr")
        await keep(store, page(.blue), "private-x", isPrivate: true)
        XCTAssertEqual(files(folder).count, 2)
        store.clear()
        await store.settled()
        XCTAssertFalse(store.has("work-hn"))
        XCTAssertFalse(store.has("work-gh-pr"))
        XCTAssertEqual(files(folder), [])
        XCTAssertTrue(store.isInMemory("private-x"), "Private's pages aren't touched by Clear History")
        XCTAssertFalse(TabPictures(folder: folder, shape: shape).has("work-hn"), "gone for the next launch too")
    }

    func testAClosedTabsPictureLeavesTheDiskAtOnceAndComesBackWithUndo() async {
        let folder = folder()
        let store = TabPictures(folder: folder, shape: shape)
        await keep(store, page(.red), "a")
        await keep(store, page(.green), "b")
        let now = TabPictures.now
        XCTAssertTrue(store.prune(keeping: ["a"], now: now), "b's picture waits for Undo")
        await store.settled()
        XCTAssertEqual(files(folder), [store.name("a")])
        XCTAssertTrue(store.isInMemory("b"))
        // Undo brought b back: on disk again.
        XCTAssertFalse(store.prune(keeping: ["a", "b"], now: now + 1))
        await store.settled()
        XCTAssertEqual(Set(files(folder)), [store.name("a"), store.name("b")])
        // Closed for good: after Undo's time it leaves memory too.
        XCTAssertTrue(store.prune(keeping: ["a"], now: now + 2))
        XCTAssertFalse(store.prune(keeping: ["a"], now: now + 2 + TabPictures.closedFor))
        XCTAssertFalse(store.has("b"))
        XCTAssertTrue(store.has("a"))
    }

    func testTheFolderFollowsTheProfileAndAFixtureWorldKeepsPicturesInMemory() throws {
        let fixture = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let test = LaunchOptions(arguments: ["-YabWorld", "mira"])
        XCTAssertNil(TabPictures.folder(for: fixture, options: test, environment: [:]))
        XCTAssertEqual(TabPictures.folder(for: fixture, options: test, environment: ["YAB_TAB_PICTURES": "/tmp/pictures"])?.path,
                       "/tmp/pictures")
        let person = LaunchOptions(arguments: [])
        XCTAssertNil(TabPictures.folder(for: fixture, options: person, environment: ["YAB_TAB_PICTURES": "/tmp/pictures"]),
                     "the person's own launch never reads it")
    }

    // MARK: - what takes them

    private func mira() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
    }

    private func host() throws -> UIView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let made = UIWindow(windowScene: scene)
        made.frame = CGRect(origin: .zero, size: Metrics.screen)
        made.rootViewController = UIViewController()
        made.makeKeyAndVisible()
        window = made
        return made.rootViewController!.view
    }

    /// A tab's page in front, on the window, drawn.
    private func show(_ app: AppModel, _ id: Tab.ID, on host: UIView) async throws -> WKWebView {
        let tab = try XCTUnwrap(app.browser.tab(id))
        app.browser.select(id)
        let view = app.pages.activate(tab)
        host.subviews.filter { $0 is WKWebView }.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        host.addSubview(view)
        await until({ app.pages.painted.contains(id) }, "\(id) never drew")
        return view
    }

    func testAPageIsPicturedAsItIsLeftOnceItHasSettledAndAsYabGoesAway() async throws {
        let app = try mira()
        let store = TabPictures(folder: nil, shape: TabStack.shape(Metrics.screen))
        let stack = TabStack.attach(app, store: store, warmsUp: false)
        let host = try host()
        _ = try await show(app, "work-hn", on: host)
        // Left before it settled: the pool's picture as it went, kept small.
        XCTAssertFalse(store.has("work-hn"))
        let hn = try XCTUnwrap(app.browser.tab("work-hn"))
        _ = hn
        let gh = try XCTUnwrap(app.browser.tab("work-gh-pr"))
        app.browser.select(gh.id)
        _ = app.pages.activate(gh)
        await until({ store.isInMemory("work-hn") }, "leaving HN didn't keep its picture")
        let left = try XCTUnwrap(store.image(for: "work-hn"))
        XCTAssertEqual(left.size.width, Metrics.screen.width, accuracy: 0.5)
        XCTAssertEqual(left.size.height, TabGalleryLayout(screen: Metrics.screen, count: 0).page.height, accuracy: 1)
        XCTAssertTrue(stack.hasPicture(hn))

        // GitHub drawn in front and left alone: pictured once it settled.
        _ = try await show(app, "work-gh-pr", on: host)
        await until({ store.isInMemory("work-gh-pr") }, "a settled page in front wasn't pictured", timeout: 10)
        let settled = try XCTUnwrap(store.image(for: "work-gh-pr"))
        XCTAssertEqual(settled.size.width, Metrics.screen.width, accuracy: 0.5)
        XCTAssertEqual(CGFloat(settled.cgImage?.width ?? 0), store.shape.pixels, accuracy: 1,
                       "a WebKit capture within one pixel keeps its original pixels")

        // Yab going away pictures the page in front as it is.
        store.remove("work-gh-pr")
        stack.resigning()
        await until({ store.isInMemory("work-gh-pr") }, "going away didn't picture the page in front", timeout: 10)
        let calls = stack.captureCalls.sorted()
        print("tab-pictures.measure capture main-thread ms: \(calls.map { String(format: "%.2f", $0) }.joined(separator: " "))")
    }

    func testATabClosedAnywhereLosesItsPictureAndClearHistoryLosesThemAll() async throws {
        let app = try mira()
        let folder = folder()
        let store = TabPictures(folder: folder, shape: TabStack.shape(Metrics.screen))
        let stack = TabStack.attach(app, store: store, warmsUp: false)
        await turn()
        await keep(store, page(.red), "work-hn")
        await keep(store, page(.green), "work-gh-pr")
        XCTAssertEqual(files(folder).count, 2)
        // Closed (here by the spaces' ×, as by Clear or the Mac): its file goes soon after.
        app.browser.close("work-hn")
        await until({ !store.isOnDisk("work-hn") }, "a closed tab's picture stayed on disk", timeout: 8)
        await store.settled()
        XCTAssertEqual(files(folder), [store.name("work-gh-pr")])
        // Clear History and Website Data: every picture goes.
        await app.clearHistoryAndWebsiteData(stores: [])
        await store.settled()
        XCTAssertEqual(files(folder), [])
        XCTAssertFalse(stack.hasPicture(try XCTUnwrap(app.browser.tab("work-gh-pr"))))
    }

    func testWhatACaptureCostsOnTheMainThread() async throws {
        let app = try mira()
        let store = TabPictures(folder: nil, shape: TabStack.shape(Metrics.screen))
        let stack = TabStack.attach(app, store: store, warmsUp: false)
        let host = try host()
        _ = try await show(app, "work-gh-pr", on: host)
        var card: [Double] = [], whole: [Double] = [], after: [Double] = []
        for _ in 0..<12 {
            var begun = CACurrentMediaTime()
            _ = await stack.cardPicture("work-gh-pr", afterScreenUpdates: false)
            card.append((CACurrentMediaTime() - begun) * 1000)
            begun = CACurrentMediaTime()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                app.pages.picture("work-gh-pr") { _ in done.resume() }
                whole.append((CACurrentMediaTime() - begun) * 1000)
            }
            begun = CACurrentMediaTime()
            _ = await stack.cardPicture("work-gh-pr", afterScreenUpdates: true)
            after.append((CACurrentMediaTime() - begun) * 1000)
        }
        func median(_ list: [Double]) -> Double { list.sorted()[list.count / 2] }
        let calls = stack.captureCalls
        print(String(format: "tab-pictures.measure capture card(now) call+wait median=%.2fms, whole page (pool) call median=%.2fms, card(after screen updates) wait median=%.2fms, card calls on main median=%.2fms max=%.2fms",
                     median(card), median(whole), median(after), median(calls), calls.max() ?? 0))
        XCTAssertLessThan(median(card), 250, "a card's picture is a few milliseconds, not a stall")
    }

    // MARK: - the warm-up's queue

    /// A stand-in warm-up: each tab's warming waits until the test ends it.
    private final class StandIn {
        var ends: [Tab.ID: CheckedContinuation<TabWarmup.Outcome, Never>] = [:]
        var letGo: [(Tab.ID, Bool)] = []

        @MainActor
        func end(_ id: Tab.ID, _ outcome: TabWarmup.Outcome = .pictured) {
            ends.removeValue(forKey: id)?.resume(returning: outcome)
        }

        /// What still waits ends, as the test does.
        @MainActor
        func endAll() {
            for id in Array(ends.keys) { end(id, .failed) }
        }
    }

    private func tabs(_ count: Int) -> [Tab] {
        (1...count).map { Tab(id: "t\($0)", title: "T\($0)", site: "t\($0)", icon: "globe", url: "http://127.0.0.1/\($0)") }
    }

    private func turn() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func warmup(_ standIn: StandIn, width: Int = 2) -> TabWarmup {
        TabWarmup(width: width, warm: { tab in
            await withCheckedContinuation { standIn.ends[tab.id] = $0 }
        }, letGo: { id, keep in standIn.letGo.append((id, keep)) })
    }

    func testTheWarmUpLoadsTwoAtATimeNearestFirstAndWaitsForAFinger() async {
        let standIn = StandIn()
        let warmup = warmup(standIn)
        warmup.start(tabs(6))
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2"], "two at once, in the order asked")
        XCTAssertEqual(warmup.runningCount, 2)
        standIn.end("t1")
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2", "t3"])
        // A finger on the cards: nothing new starts until it leaves.
        var finger = true
        warmup.mayStart = { !finger }
        standIn.end("t2")
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2", "t3"])
        finger = false
        try? await Task.sleep(for: TabWarmup.pause + .milliseconds(100))
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2", "t3", "t4"])
        // A scroll asks again in another order: what is new comes first, nothing twice.
        warmup.start(Array(tabs(6).reversed()))
        standIn.end("t3")
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2", "t3", "t4", "t6"])
        XCTAssertEqual(warmup.mostAtOnce, 2)
        warmup.stop()
        standIn.endAll()
    }

    func testClosingAllTabsStopsTheWarmUpAndLetsItsPagesGoAtOnce() async {
        let standIn = StandIn()
        let warmup = warmup(standIn)
        warmup.start(tabs(5))
        await turn()
        warmup.stop(keeping: "t2")
        XCTAssertFalse(warmup.isOn)
        XCTAssertEqual(warmup.runningCount, 0)
        XCTAssertEqual(Set(standIn.letGo.map(\.0)), ["t1", "t2"])
        XCTAssertEqual(standIn.letGo.first { $0.0 == "t2" }?.1, true, "the card tapped keeps its page")
        XCTAssertEqual(standIn.letGo.first { $0.0 == "t1" }?.1, false)
        // Their loads end later: nothing more starts.
        standIn.end("t1")
        standIn.end("t2")
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2"])
        XCTAssertTrue(warmup.waitingIDs.isEmpty)
        standIn.endAll()
    }

    func testATabWithNoRoomWaitsForAnotherToEndAndAFailedOneIsntTriedAgain() async {
        let standIn = StandIn()
        let warmup = warmup(standIn)
        warmup.start(tabs(3))
        await turn()
        standIn.end("t2", .noRoom)
        await turn()
        XCTAssertEqual(warmup.waitingIDs, ["t2", "t3"], "back at the front of the line")
        standIn.end("t1", .failed)
        await turn()
        XCTAssertEqual(warmup.started, ["t1", "t2", "t2", "t3"])
        warmup.start(tabs(3))
        await turn()
        XCTAssertEqual(warmup.started.filter { $0 == "t1" }.count, 1, "tried once while All Tabs is up")
        warmup.stop()
        // Opened again, every card is tried again.
        warmup.start(tabs(1))
        await turn()
        XCTAssertEqual(warmup.started.filter { $0 == "t1" }.count, 2)
        warmup.stop()
        standIn.endAll()
    }

    // MARK: - the warm-up, real pages

    /// The process's footprint, as jetsam counts it.
    private func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testAllTabsRightAfterALaunchWarmsEveryCardUnderTheGroundBoundedByTheLiveLimit() async throws {
        let app = try mira()
        let store = TabPictures(folder: folder(), shape: TabStack.shape(Metrics.screen))
        let stack = TabStack.attach(app, store: store)
        let host = try host()
        let stage = TabWarmupStage(frame: host.bounds)
        host.addSubview(stage)
        stack.stage = stage
        // Figma in front, drawn; nothing else ever loaded in this run.
        let figma = try await show(app, "work-figma-onb", on: host)
        host.bringSubviewToFront(figma)
        await turn()
        let before = footprint()
        let begun = CACurrentMediaTime()
        stack.openGallery()
        await until({ stack.gallery?.phase == .open }, "All Tabs didn't open")
        let shown = try XCTUnwrap(stack.gallery)
        let needed = stack.needingPictures(shown).map(\.id)
        XCTAssertEqual(Set(needed), ["work-hn", "work-gh-pr", "work-tern-local", "work-lumen", "work-linear-method"])
        XCTAssertEqual(needed.first, "work-hn", "the card at the focus first")
        var most = app.pages.liveCount, peak = before
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            most = max(most, app.pages.liveCount)
            peak = max(peak, footprint())
            if let shown = stack.gallery, stack.needingPictures(shown).isEmpty, stack.warmup.runningCount == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = CACurrentMediaTime() - begun
        let after = footprint()
        for id in needed { XCTAssertTrue(store.has(id), "\(id) has no picture") }
        await store.settled()
        let sizes = needed.compactMap { id -> Int? in
            guard let folder = store.folder else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(store.name(id)).path))?[.size] as? Int
        }
        print("tab-pictures.measure real pages on disk kb: \(sizes.map { String($0 / 1024) }.joined(separator: " "))")
        XCTAssertLessThanOrEqual(most, WebPool.liveLimit, "the warm-up keeps the pool's live limit")
        XCTAssertLessThanOrEqual(stack.warmup.mostAtOnce, 2)
        XCTAssertTrue(stage.subviews.isEmpty, "every warmed page let go")
        XCTAssertEqual(app.pages.liveCount, 1, "only the page in front stays alive")
        XCTAssertTrue(app.pages.isLive("work-figma-onb"))
        let times = stack.warmTimes.map { String(format: "%.2f", $0) }.joined(separator: " ")
        print(String(format: "tab-pictures.measure warm-up cards=%d total=%.2fs per-card-s=[%@] at-once=%d live-max=%d footprint-mb before=%.1f peak=%.1f after=%.1f memory-pictures-mb=%.1f",
                     needed.count, elapsed, times, stack.warmup.mostAtOnce, most, before, peak, after,
                     Double(store.memoryCost) / 1_048_576))
        // Closing All Tabs stops it: nothing more is loaded.
        stack.dismissGallery()
        XCTAssertFalse(stack.warmup.isOn)
    }

    func testClosingAllTabsWhileItWarmsUpLetsThePagesGoAndATappedCardKeepsItsPage() async throws {
        let app = try mira()
        let store = TabPictures(folder: nil, shape: TabStack.shape(Metrics.screen))
        let stack = TabStack.attach(app, store: store)
        let host = try host()
        let stage = TabWarmupStage(frame: host.bounds)
        host.addSubview(stage)
        stack.stage = stage
        let figma = try await show(app, "work-figma-onb", on: host)
        host.bringSubviewToFront(figma)
        stack.openGallery()
        // Both pages made and loading under the cards (a fixture page draws in about half a second).
        await until({ stage.subviews.count == 2 }, "the warm-up didn't start two pages")
        let warming = stack.warmup.started
        XCTAssertEqual(warming, ["work-hn", "work-gh-pr"])
        XCTAssertTrue(warming.allSatisfy { app.pages.isBorrowed($0) && app.pages.isLive($0) })
        XCTAssertEqual(stage.subviews.count, 2)
        // HN's card tapped while it loads: its page comes in front, GitHub's goes.
        stack.choose("work-hn")
        XCTAssertFalse(stack.warmup.isOn)
        XCTAssertFalse(app.pages.isBorrowed("work-hn"))
        XCTAssertTrue(app.pages.isLive("work-hn"), "the card tapped keeps the page it loaded")
        XCTAssertFalse(app.pages.isLive("work-gh-pr"), "the other page warming went at once")
        XCTAssertEqual(stage.subviews.count, 1)
        XCTAssertEqual(app.browser.tab?.id, "work-hn")
        stack.dismissGallery()
    }
}
