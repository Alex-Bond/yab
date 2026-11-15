import AppKit
import Testing
import WebKit
@testable import Fast

/// Controlled loading notifications through the real Tab teardown. No external
/// request is made; Farewell may load its existing about:blank document. The
/// loading state comes from the existing lifecycle test seam, not a server.
@MainActor
@Suite(.serialized)
struct SleepLoadingTests {
    private func tab() -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, configuration: configuration)
        tab.setAddressOptimistically(URL(string: "about:blank#sleep-loading")!)
        let page = tab.page
        #expect(page.engine == (ForcedEngine.chromium ? .chromium : .webKit),
                "loading teardown must exercise the selected engine")
        return tab
    }

    private func ring(_ tab: Tab) async throws {
        tab.pretendLoading(true)
        for _ in 0..<50 where !tab.loadingShown {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.loading && tab.loadingShown && tab.spinning,
                     "the existing delayed ring must be visible before teardown")
    }

    @Test func sleepingAPageClearsItsVisibleLoadingState() async throws {
        let tab = tab()
        defer { tab.close() }
        let url = tab.address, id = tab.id
        try await ring(tab)
        // This is Tab's accepted teardown, not Browser's eligibility check.
        var accepted: Bool?
        tab.sleep(picture: nil) { accepted = $0 }
        try #require(try await Loaded.until(10) { accepted != nil }, "native discard must complete")
        #expect(accepted == true, "accepted teardown is required on both engines; no native activity guard is bypassed")
        #expect(tab.asleep && tab.builtPage == nil)
        #expect(tab.id == id && tab.address == url && tab.pending == url)
        #expect(!tab.loading && !tab.loadingShown && !tab.spinning)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!tab.loadingShown && !tab.spinning && tab.builtPage == nil)
    }

    @Test func restingBeforeTheRingDelayCancelsItsAppearance() async throws {
        let tab = tab()
        defer { tab.close() }
        tab.pretendLoading(true)
        // The same MainActor turn ends the page before the queued ring runs.
        tab.rest()
        #expect(tab.asleep && tab.builtPage == nil)
        #expect(!tab.loading && !tab.loadingShown && !tab.spinning)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!tab.loadingShown && !tab.spinning)
    }

    /// Put Tab to Sleep on a page that takes long to load: a hand puts it
    /// down, its load stopped and its ring gone; the clock still leaves it.
    @Test func putToSleepByHandWhileLoadingPutsItDown() async throws {
        let window = UUID(), browser = Browser(windowID: window), tab = tab()
        defer {
            tab.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        browser.lay([tab])
        browser.activeID = nil
        let url = tab.address
        try await ring(tab)
        #expect(browser.awake(because: tab) == "still loading")
        #expect(!browser.canSleep([tab]))
        #expect(browser.canSleep([tab], byHand: true))
        // The menu's own call.
        browser.sleep([tab], byHand: true)
        for _ in 0..<250 where !tab.asleep { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tab.asleep && tab.builtPage == nil && tab.pending == url)
        #expect(!tab.loading && !tab.loadingShown && !tab.spinning)
    }

    @Test func theClockLeavesALoadingPageAwake() async throws {
        let window = UUID(), browser = Browser(windowID: window), tab = tab()
        defer {
            tab.close()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        browser.lay([tab])
        browser.activeID = nil
        let web = try #require(tab.builtPage)
        try await ring(tab)
        var reason: String?
        browser.sleep(tab) { reason = $0 }
        #expect(reason == "still loading")
        #expect(tab.builtPage === web && !tab.asleep && tab.spinning)
    }
}
