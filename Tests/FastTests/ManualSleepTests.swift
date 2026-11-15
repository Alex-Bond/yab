import AppKit
import Testing
import WebKit
@testable import Fast

/// The existing search-menu action, using real page probes and teardown.
/// Each case owns its browser and document; no user tabs or network are used.
@MainActor @Suite(.serialized)
struct ManualSleepTests {
    private func evaluate(_ script: String, in web: PageView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: Web.world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fixture() async throws -> (Browser, Tab, () -> Void) {
        _ = NSApplication.shared
        let window = UUID(), browser = Browser(windowID: window)
        let html = "<title>Manual sleep</title><p>Same saved tab</p>"
        let encoded = try #require(html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        let tab = browser.open(URL(string: "data:text/html,\(encoded)")!, foreground: true)
        let cleanup = {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
        }
        do {
            for _ in 0..<250 where tab.loading { try await Task.sleep(for: .milliseconds(20)) }
            try #require(!tab.loading)
            let web = try #require(tab.built)
            _ = try await evaluate("window.__manualSleepProbes = 0; window.__yabForms = {unsaved(){ window.__manualSleepProbes++; return false; }}; true", in: web)
            return (browser, tab, cleanup)
        } catch {
            cleanup()
            throw error
        }
    }

    private func waitForSleep(_ tab: Tab) async throws {
        for _ in 0..<200 where !tab.asleep { try await Task.sleep(for: .milliseconds(20)) }
        #expect(tab.asleep && tab.built == nil)
    }

    @Test(arguments: ["regular", "kept", "pinned"])
    func theCurrentTabSleepsByHandAndKeepsItsRow(kind: String) async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        tab.kept = kind == "kept"
        if kind == "pinned" { tab.pin = "Manual sleep" }
        let order = browser.tabs.map(\.id), address = tab.address, pin = tab.pin
        #expect(!browser.canSleep([tab]))
        #expect(browser.canSleep([tab], byHand: true), "MANUAL_SLEEP_CURRENT_TAB")

        browser.sleep([tab], byHand: true)
        try await waitForSleep(tab)
        #expect(browser.activeID == nil)
        #expect(browser.tabs.map(\.id) == order && browser.tabs.contains { $0 === tab })
        #expect(tab.address == address && tab.pending == address)
        #expect(tab.kept == (kind == "kept") && tab.pin == pin)
        #expect(browser.ghosts.isEmpty, "sleep must not close the tab")

        browser.select(tab)
        #expect(!tab.asleep && browser.activeID == tab.id && tab.address == address)
        #expect(tab.kept == (kind == "kept") && tab.pin == pin)
    }

    @Test(arguments: ["regular", "kept", "pinned"])
    func aBackgroundTabSleepsWithoutChangingTheCurrentTab(kind: String) async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        tab.kept = kind == "kept"
        if kind == "pinned" { tab.pin = "Manual sleep" }
        let front = browser.open(URL(string: "about:blank#manual-front")!, foreground: true)
        let order = browser.tabs.map(\.id)
        #expect(browser.canSleep([tab], byHand: true))
        browser.sleep([tab], byHand: true)
        try await waitForSleep(tab)
        #expect(browser.activeID == front.id && !front.asleep)
        #expect(browser.tabs.map(\.id) == order)
    }

    @Test(arguments: ["sound", "recent sound", "floating video", "picture in picture"])
    func loadingDoesNotHideMediaProtection(protection: String) async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        browser.activeID = nil
        tab.pretendLoading(true)
        let reason: String
        switch protection {
        case "sound": tab.noisy = true; reason = "playing sound"
        case "recent sound": tab.heardAt = Date(); reason = "played sound a moment ago"
        case "floating video": tab.floating = true; reason = "its video is out"
        default: tab.pictureInPicture = true; reason = "its video is in picture in picture"
        }
        let web = try #require(tab.built)
        #expect(!browser.canSleep([tab], byHand: true), "MANUAL_SLEEP_LOADING_MEDIA")
        var refused: String?
        browser.sleep(tab, waiving: Browser.byHand) { refused = $0 }
        #expect(refused == reason)
        #expect(tab.built === web && !tab.asleep)
    }

    @Test func aDraftKeepsTheCurrentTabAndSelectionIntact() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let web = try #require(tab.built)
        _ = try await evaluate("window.__yabForms.unsaved = function(){ window.__manualSleepProbes++; return true; }; true", in: web)
        browser.sleep([tab], byHand: true)
        var probes = 0
        for _ in 0..<100 where probes == 0 {
            try await Task.sleep(for: .milliseconds(20))
            probes = (try await evaluate("window.__manualSleepProbes", in: web) as? Int) ?? 0
        }
        #expect(probes > 0, "manual sleep must check the current page's draft")
        #expect(browser.activeID == tab.id && tab.built === web && !tab.asleep)
    }

    @Test func selectingABackgroundTabWhileItsProbeRunsCancelsSleep() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        _ = browser.open(URL(string: "about:blank#manual-front")!, foreground: true)
        let web = try #require(tab.built)
        browser.sleep([tab], byHand: true)
        browser.activeID = tab.id
        try await Task.sleep(for: .milliseconds(250))
        #expect(browser.activeID == tab.id && tab.built === web && !tab.asleep)
    }

    @Test func leavingAndReturningToTheCurrentTabCancelsItsPendingSleep() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let front = browser.open(URL(string: "about:blank#manual-front")!, foreground: true)
        browser.activeID = tab.id
        let web = try #require(tab.built)
        browser.sleep([tab], byHand: true)
        browser.activeID = front.id
        browser.activeID = tab.id
        try await Task.sleep(for: .milliseconds(250))
        #expect(browser.activeID == tab.id && tab.built === web && !tab.asleep)
    }

    @Test func sleepingAGroupNeverWakesOneOfItsOtherTabs() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let other = browser.open(URL(string: "about:blank#manual-group")!, foreground: true)
        for _ in 0..<100 where other.loading { try await Task.sleep(for: .milliseconds(20)) }
        let order = browser.tabs.map(\.id)
        browser.sleep([tab, other], byHand: true)
        try await waitForSleep(tab)
        try await waitForSleep(other)
        #expect(browser.activeID == nil && browser.tabs.map(\.id) == order)
    }

    @Test func theCurrentTabReturnsToTheLastAwakeTabWithoutWakingAnother() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let back = browser.open(URL(string: "about:blank#manual-back")!, foreground: true)
        let sleeping = browser.open(URL(string: "about:blank#manual-sleeping")!, foreground: true)
        for _ in 0..<100 where sleeping.loading { try await Task.sleep(for: .milliseconds(20)) }
        browser.activeID = back.id
        sleeping.sleep(picture: nil)
        browser.activeID = tab.id
        browser.sleep([tab], byHand: true)
        try await waitForSleep(tab)
        #expect(browser.activeID == back.id && !back.asleep)
        #expect(sleeping.asleep && sleeping.built == nil)
    }

    @Test func visibleSplitHalvesRemainProtected() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let other = browser.open(URL(string: "about:blank#manual-split")!, foreground: true)
        browser.pairs = [Pair(first: tab.id, second: other.id)]
        browser.restage()
        try #require(browser.stagePair != nil)
        let firstPage = tab.built, secondPage = other.built, active = browser.activeID
        #expect(!browser.canSleep([tab, other], byHand: true))
        browser.sleep([tab, other], byHand: true)
        #expect(tab.built === firstPage && other.built === secondPage)
        #expect(!tab.asleep && !other.asleep && browser.activeID == active)
    }

    @Test func automaticSleepStillLeavesTheCurrentTabAlone() async throws {
        let (browser, tab, cleanup) = try await fixture()
        defer { cleanup() }
        let web = try #require(tab.built)
        var refused: String?
        browser.sleep(tab) { refused = $0 }
        #expect(refused == "on screen")
        #expect(tab.built === web && !tab.asleep && browser.activeID == tab.id)
    }
}
