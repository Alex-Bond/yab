import AppKit
import Testing
import WebKit
@testable import Fast

// Page processes counted, and a page let go of gone within a second
// (PageProcesses, Lingering).
@MainActor
@Suite(.serialized)
struct PageProcessesTests {
    @Test func whatIsHeldIsSaidAndWhatGoesIsNot() async throws {
        #expect(Lingering.watching, "a test run watches")
        var held: NSObject? = NSObject()
        Lingering.expectGone(held!, "held on purpose", after: 0.05)
        do {
            let gone = NSObject()
            Lingering.expectGone(gone, "let go on purpose", after: 0.05)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Lingering.seen.contains("held on purpose"))
        #expect(!Lingering.seen.contains("let go on purpose"))
        held = nil
    }

    @Test func enginesCountTheirPageProcessesAndSayWhichViewIsWhose() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let tab = browser.open(URL(string: "about:blank#census")!, foreground: true)
        let page = tab.page
        page.navigate(html: "<p>counted</p>", base: nil)
        for _ in 0..<100 where tab.loading || page.contentProcess == nil {
            try await Task.sleep(for: .milliseconds(30))
        }
        let pid = try #require(page.contentProcess)
        let all = try #require(PageProcesses.census(), "The engine no longer lists its page processes")
        let mine = try #require(all.first { $0.pid == pid })
        #expect(mine.views?.contains { $0 === page } == true)
        #expect((mine.footprint ?? 0) > 0)
        let shares = try #require(PageProcesses.shares())
        #expect(shares[ObjectIdentifier(page)] != nil)
    }

    // The leak the check is for: a tab closed, or put to sleep, leaves
    // nothing of its page behind a second later.
    @Test func aClosedTabAndASleepingPageAreGoneInASecond() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        _ = browser.open(URL(string: "about:blank#stays")!, foreground: true)
        let before = Lingering.seen.count
        weak var sleeperView: NSView?
        weak var closedTab: Tab?
        do {
            let sleeper = browser.open(URL(string: "data:text/html,<title>Sleep%20census</title><p>sleep</p>")!, foreground: false)
            let closer = browser.open(URL(string: "about:blank#closes")!, foreground: false)
            _ = sleeper.page
            _ = closer.page
            for _ in 0..<100 where sleeper.loading || closer.loading || sleeper.builtPage?.contentProcess == nil { try await Task.sleep(for: .milliseconds(20)) }
            sleeperView = sleeper.builtPage
            closedTab = closer
            let slept = await withCheckedContinuation { reply in
                sleeper.sleep(picture: nil) { reply.resume(returning: $0) }
            }
            #expect(slept && sleeper.asleep && sleeper.builtPage == nil)
            browser.close(closer)
        }
        try await Task.sleep(for: .milliseconds(1300))
        if ForcedEngine.chromium {
            #expect((sleeperView as? ChromiumPage)?.contentProcess == nil, "discarded page has no live renderer")
            #expect((sleeperView as? ChromiumPage)?.sleepState.discarded == true, "native discard acknowledged")
        } else {
            #expect(sleeperView == nil, "the sleeping tab's view is still held")
        }
        #expect(closedTab == nil, "the closed tab is still held")
        #expect(Lingering.seen.count == before, "\(Lingering.seen)")
    }
}
