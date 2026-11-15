import AppKit
import Testing
import WebKit
@testable import Fast

/// A large document must not be reloaded just because switching through
/// other tabs displaced it from the last five used (request #446).
@Suite(.serialized)
struct HeavyPageSleepTests {
    @MainActor @Test func aHeavyPageGetsTheSameGraceAsMemoryRelief() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let document = browser.open(URL(string: "about:blank#large-document")!, foreground: true)
        let others = (0...Browser.keepRecent).map {
            browser.open(URL(string: "about:blank#other-\($0)")!, foreground: true)
        }
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for tab in [document] + others {
            for _ in 0..<100 where tab.loading { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!tab.loading)
        }
        #expect(!browser.recentlyUsed().contains(document.id))
        #expect(browser.awake(because: document) == nil)
        document.touch()
        #expect(!browser.mayLighten(document), "a document just left must retain its live page")
        document.touch(at: Date(timeIntervalSinceNow: -599))
        #expect(!browser.mayLighten(document))
        document.touch(at: Date(timeIntervalSinceNow: -601))
        #expect(browser.mayLighten(document), "an older unprotected page may still release memory")
        document.touch()
        #expect(!browser.mayLighten(document), "returning to the page renews its grace")
    }

    @MainActor @Test func olderHeavyPagesKeepTheirExistingProtections() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let document = browser.open(URL(string: "about:blank#large-document")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        defer {
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<100 where document.loading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!document.loading)
        document.touch(at: Date(timeIntervalSinceNow: -601))
        #expect(browser.mayLighten(document))
        document.pin = "Document"
        #expect(!browser.mayLighten(document))
        document.pin = nil
        document.noisy = true
        #expect(!browser.mayLighten(document))
        document.noisy = false
        document.agent = "memory-grace-test"
        #expect(!browser.mayLighten(document))
        document.agent = nil
        browser.activeID = document.id
        document.touch(at: Date(timeIntervalSinceNow: -601))
        #expect(!browser.mayLighten(document))
    }

    @MainActor @Test func aFreshPageProtectsTheOlderPageSharingItsProcess() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let old = browser.open(URL(string: "about:blank#old")!, foreground: true)
        let previous = Store.settings.object(forKey: "memory.heavy")
        defer {
            if let previous { Store.settings.set(previous, forKey: "memory.heavy") }
            else { Store.settings.removeObject(forKey: "memory.heavy") }
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        try #require(try await Loaded.until(20) { !old.loading && old.builtPage?.contentProcess != nil })
        let fresh: Tab
        if let page = old.builtPage as? ChromiumPage {
            // A native window.open keeps the opener's SiteInstance. Independent
            // about:blank tabs are not guaranteed to share a Chromium renderer.
            let opened = try await page.run("window.__sharedSleepChild = window.open('about:blank#fresh'); !!window.__sharedSleepChild", gesture: true)
            try #require(opened as? Bool == true, "the real opener must create its child")
            try #require(try await Loaded.until(20) { browser.tabs.contains { $0.opener == old.id } })
            fresh = try #require(browser.tabs.first { $0.opener == old.id })
            #expect(fresh.engineKind == .chromium)
        } else {
            let config = Web.configuration()
            SiteProcesses.relate(config, to: try #require(old.page.webKit))
            fresh = Tab(configuration: config, factory: .webKitOnly)
            browser.prepare(fresh)
            browser.showRow(browser.tabs + [fresh], active: browser.activeID)
            fresh.go(to: URL(string: "about:blank#fresh")!)
        }
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        for tab in [old, fresh] {
            for _ in 0..<100 where tab.loading || tab.builtPage?.contentProcess == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!tab.loading)
        }
        let pid = try #require(old.builtPage?.contentProcess)
        #expect(fresh.builtPage?.contentProcess == pid)
        browser.recent = []
        old.touch(at: Date(timeIntervalSinceNow: -601))
        fresh.touch()
        Store.settings.set(1, forKey: "memory.heavy")
        browser.lookForStuck()
        try await Task.sleep(for: .milliseconds(2000))
        #expect(!old.asleep && !fresh.asleep, "a fresh group member keeps the shared process alive")
        #expect(old.builtPage?.contentProcess == pid && fresh.builtPage?.contentProcess == pid)
    }
    @MainActor @Test func theLimitIsTheMacsQuarterWhileMemoryIsPlentiful() {
        let saved = (Store.settings.object(forKey: "memory.heavy"), Store.settings.object(forKey: "memory.roomy"))
        defer {
            for (key, value) in [("memory.heavy", saved.0), ("memory.roomy", saved.1)] {
                if let value { Store.settings.set(value, forKey: key) } else { Store.settings.removeObject(forKey: key) }
            }
        }
        Store.settings.removeObject(forKey: "memory.heavy")
        Store.settings.removeObject(forKey: "memory.roomy")
        let quarter = ProcessInfo.processInfo.physicalMemory / 4
        #expect(StuckWatch.heavy(at: 1) == max(StuckWatch.heavy, quarter))
        #expect(StuckWatch.heavy(at: 2) == StuckWatch.heavy)
        #expect(StuckWatch.heavy(at: 4) == StuckWatch.heavy)
        #expect(StuckWatch.heavy(at: nil) == StuckWatch.heavy, "a kernel that won't say counts as short")
    }

    /// The reporters' reload: a heavy page left ten minutes, put down on a
    /// Mac with memory to spare, loaded again when they came back (#446).
    @MainActor @Test func aHeavyPageSleepsOnlyWhenMemoryIsShort() async throws {
        let id = UUID(), browser = Browser(windowID: id)
        let document = browser.open(URL(string: "about:blank#large-document")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        let saved = (Store.settings.object(forKey: "memory.heavy"), Store.settings.object(forKey: "memory.roomy"))
        defer {
            Pressure.forced = nil
            for (key, value) in [("memory.heavy", saved.0), ("memory.roomy", saved.1)] {
                if let value { Store.settings.set(value, forKey: key) } else { Store.settings.removeObject(forKey: key) }
            }
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        for _ in 0..<100 where document.loading || Browser.process(of: document.built) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!document.loading)
        browser.recent = []
        document.touch(at: Date(timeIntervalSinceNow: -601))
        #expect(browser.mayLighten(document))
        // Every page past the short-memory limit, none past the roomy one.
        Store.settings.set(1, forKey: "memory.heavy")
        Store.settings.set(1 << 20, forKey: "memory.roomy")
        Pressure.forced = 1
        browser.lookForStuck()
        try await Task.sleep(for: .milliseconds(2000))
        #expect(!document.asleep, "memory to spare keeps a heavy page left ten minutes")
        Pressure.forced = 2
        browser.lookForStuck()
        for _ in 0..<300 where !document.asleep { try await Task.sleep(for: .milliseconds(20)) }
        #expect(document.asleep, "memory short still puts it down")
    }
}
