import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// A tab every window has, picked in one window while another has its page
/// awake: that same page, one tab and one web view, comes over with what it
/// holds, never a second copy loading (feedback #667: a Meet call started
/// twice, a half-written Slack reply lost). BrowserWindows.handOff.
@MainActor
@Suite(.serialized)
struct SharedTabHandOffTests {
    private static let html = """
    <!doctype html><title>live</title><script>window.count = 0;</script>
    """

    /// Two windows, the page awake in `a` with a count it was given, and
    /// `b`'s own tab for it asleep. `made` builds both.
    private func world(_ made: (Browser, Browser, Tab) throws -> Tab, _ body: (Browser, Browser, Tab, Tab) async throws -> Void) async throws {
        _ = NSApplication.shared
        let one = UUID(), two = UUID()
        let a = Browser(windowID: one), b = Browser(windowID: two)
        let was = Browser.pretendHand
        defer {
            Browser.pretendHand = was
            BrowserWindows.shared.handOffWindows = nil
            KeptEverywhere.known = [:]
            a.letGo(); b.letGo()
            for id in [one, two] { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        let url = URL(string: "http://127.0.0.1:9/live")!
        let live = Tab(configuration: Web.configuration(store: Spaces.store(for: a.spaceID)))
        a.prepare(live)
        live.page.navigate(html:Self.html, base: url)
        let loaded = try await Loaded.until(10) {
            guard live.address == url, !live.loading else { return false }
            let ready = try? await live.page.run("document.readyState === 'complete' && window.count === 0")
            return ready as? Bool == true
        }
        try #require(loaded)
        _ = try await live.page.run("window.count = 5; true")
        let mine = try made(a, b, live)
        try #require(mine !== live && mine.asleep && !live.asleep)
        BrowserWindows.shared.handOffWindows = [a, b]
        Browser.pretendHand = true
        try await body(a, b, live, mine)
    }

    private func same(_ live: Tab, view: any PageHandle, origin: Double) async throws {
        #expect(live.page === view)
        #expect(!live.asleep)
        // No new document: the count it was given and the time it began.
        let count = try await live.page.run("window.count")
        let began = try await live.page.run("performance.timeOrigin")
        #expect(count as? Int == 5)
        #expect(began as? Double == origin)
    }

    @Test func aKeptTabPickedInAnotherWindowBringsTheSamePage() async throws {
        try await world({ a, b, live in
            a.lay([live])
            a.keepTabs([live])
            a.select(live)
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            return try #require(b.tabs.first { KeptEverywhere.key($0) == KeptEverywhere.key(live) })
        }) { a, b, live, mine in
            let view = live.page
            let began = try await live.page.run("performance.timeOrigin")
            let origin = try #require(began as? Double)
            b.select(mine)
            #expect(b.active === live)
            #expect(b.tabs.contains { $0 === live } && !b.tabs.contains { $0 === mine })
            // The first window keeps the kept tab in its list, asleep.
            #expect(!a.tabs.contains { $0 === live })
            let left = try #require(a.tabs.first { KeptEverywhere.key($0) == KeptEverywhere.key(live) })
            #expect(left.asleep && left.kept)
            #expect(live.kept)
            try await same(live, view: view, origin: origin)
        }
    }

    @Test func aSharedPinPickedInAnotherWindowBringsTheSamePage() async throws {
        let key = UUID()
        try await world({ a, b, live in
            live.pin = "L"
            live.everywhere = key
            a.lay([live])
            a.select(live)
            let entry = try #require(a.sessionEntry(live, id: key))
            let mine = try #require(b.madePin(entry, key: key))
            b.lay([mine])
            return mine
        }) { a, b, live, mine in
            let view = live.page
            let began = try await live.page.run("performance.timeOrigin")
            let origin = try #require(began as? Double)
            b.select(mine)
            #expect(b.active === live)
            #expect(b.tabs.contains { $0 === live } && !b.tabs.contains { $0 === mine })
            let left = try #require(a.tabs.first { $0.everywhere == key })
            #expect(left !== live && left.asleep && left.pin != nil)
            try await same(live, view: view, origin: origin)
        }
    }

    /// A muted pin's page goes over muted, and the tab it leaves in its
    /// place is muted too: picked there later, its own page comes up silent
    /// (feedback #2018).
    @Test func aMutedSharedPinLeavesAMutedTabBehind() async throws {
        try #require(AudioWatch.canMute)
        let key = UUID()
        try await world({ a, b, live in
            live.pin = "L"
            live.everywhere = key
            a.lay([live])
            a.select(live)
            live.mute(true)
            // The windows as the app has them, before the copy is made.
            BrowserWindows.shared.handOffWindows = [a, b]
            let entry = try #require(a.sessionEntry(live, id: key))
            let mine = try #require(b.madePin(entry, key: key))
            b.lay([mine])
            return mine
        }) { a, b, live, mine in
            #expect(mine.muted)
            b.select(mine)
            #expect(b.active === live && live.muted)
            let left = try #require(a.tabs.first { $0.everywhere == key })
            #expect(left !== live && left.muted, "the tab left behind for a muted pin must be muted")
        }
    }

    /// An agent's pick, or none awake elsewhere, wakes this window's own.
    @Test func notByHandItWakesItsOwn() async throws {
        try await world({ a, b, live in
            a.lay([live])
            a.keepTabs([live])
            a.select(live)
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            return try #require(b.tabs.first { KeptEverywhere.key($0) == KeptEverywhere.key(live) })
        }) { a, b, live, mine in
            Browser.pretendHand = false
            b.select(mine)
            #expect(b.active === mine && !mine.asleep)
            #expect(a.tabs.contains { $0 === live })
        }
    }
}
