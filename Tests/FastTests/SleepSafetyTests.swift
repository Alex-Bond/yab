import AppKit
import Testing
@testable import Fast

struct SleepSafetyTests {
    @MainActor @Test func heavyAgentPagesKeepMediaAndDrafts() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        let tab = browser.benchOpen(URL(string: "about:blank#agent")!)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!tab.loading)
        #expect(!browser.mayReloadForMemory(tab))
        tab.agent = "memory-test-agent"
        #expect(browser.mayReloadForMemory(tab))
        #expect(!browser.mayPutDown(tab))
        tab.noisy = true
        #expect(!browser.mayReloadForMemory(tab))
        tab.noisy = false
        tab.floating = true
        #expect(!browser.mayReloadForMemory(tab))
        tab.floating = false
        tab.draft = true
        #expect(!browser.mayReloadForMemory(tab))
    }

    @MainActor @Test func pinnedMediaSurvivesMemoryReliefAndAgentReload() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let tab = browser.open(URL(string: "about:blank#background")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!tab.loading)
        let web = try #require(tab.builtPage)
        tab.pin = "Background"
        #expect(browser.awake(because: tab) == "pinned")
        #expect(browser.mayPutDown(tab))

        tab.noisy = true
        #expect(browser.awake(because: tab) == "playing sound")
        #expect(!browser.mayPutDown(tab))
        #expect(!browser.mayReloadForMemory(tab))
        var reason: String?
        browser.sleep(tab, waiving: Browser.byHand) { reason = $0 }
        #expect(reason == "playing sound")
        #expect(tab.builtPage === web && !tab.asleep)

        tab.noisy = false
        tab.floating = true
        #expect(browser.awake(because: tab) == "its video is out")
        #expect(!browser.mayPutDown(tab))
        #expect(!browser.mayReloadForMemory(tab))
        reason = nil
        browser.sleep(tab, waiving: Browser.byHand) { reason = $0 }
        #expect(reason == "its video is out")
        #expect(tab.builtPage === web && !tab.asleep)

        tab.floating = false
        tab.pictureInPicture = true
        #expect(browser.awake(because: tab) == "its video is in picture in picture")
        #expect(!browser.mayPutDown(tab))
        #expect(!browser.mayReloadForMemory(tab))
        reason = nil
        browser.sleep(tab, waiving: Browser.byHand) { reason = $0 }
        #expect(reason == "its video is in picture in picture")
        #expect(tab.builtPage === web && !tab.asleep)

        tab.pictureInPicture = false
        tab.guest = "memory-test-agent"
        #expect(!browser.mayPutDown(tab))
        #expect(browser.mayReloadForMemory(tab))
        tab.draft = true
        #expect(!browser.mayReloadForMemory(tab))
        tab.draft = false
        tab.noisy = true
        #expect(!browser.mayReloadForMemory(tab))
        tab.noisy = false
        browser.select(tab)
        #expect(!browser.mayPutDown(tab))
        #expect(!browser.mayReloadForMemory(tab))
    }

    /// Put Tab to Sleep in a tab's menu: a pin or a kept tab goes by hand,
    /// though never on the clock. The current tab goes only by hand;
    /// a page playing sound never does.
    @MainActor @Test func pinsAndKeptTabsSleepByHand() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let tab = browser.open(URL(string: "about:blank#background")!, foreground: true)
        let front = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        defer {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(browser.canSleep([tab]) && browser.canSleep([tab], byHand: true))

        tab.pin = "Background"
        #expect(!browser.canSleep([tab]))
        #expect(browser.canSleep([tab], byHand: true))
        tab.pin = nil
        tab.kept = true
        #expect(!browser.canSleep([tab]))
        #expect(browser.canSleep([tab], byHand: true))
        #expect(browser.idleTabs(within: 0, now: AwakeClock.now + 24 * 3600).isEmpty)

        tab.noisy = true
        #expect(!browser.canSleep([tab], byHand: true))
        tab.noisy = false
        #expect(!browser.canSleep([front]))
        #expect(browser.canSleep([front], byHand: true))
    }
}
