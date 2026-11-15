import AppKit
import Testing
@testable import Fast

/// Sites kept awake, Chrome's "Always keep these sites active", and pins
/// that never sleep in any space (feedback #78: WhatsApp Web loaded again
/// every time it was come back to after a while).
struct AwakeSitesTests {
    /// A window with one hidden page behind the one on screen, not among
    /// the last few used.
    @MainActor private func world() async throws -> (Browser, Tab, () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let tab = browser.open(URL(string: "about:blank#hidden")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!tab.loading)
        #expect(browser.awake(because: tab) == nil)
        browser.recent = []
        let done = {
            for page in browser.tabs + browser.parkedTabs { page.close() }
            browser.parked = [:]
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        return (browser, tab, done)
    }

    @Test func aSiteKeepsItselfAndThePagesUnderIt() {
        let sites = ["web.whatsapp.com", "discord.com"]
        #expect(AwakeSites.match("web.whatsapp.com", in: sites))
        #expect(AwakeSites.match("www.discord.com", in: sites))
        #expect(AwakeSites.match("ptb.discord.com", in: sites))
        #expect(!AwakeSites.match("whatsapp.com", in: sites))
        #expect(!AwakeSites.match("notdiscord.com", in: sites))
        #expect(AwakeSites.defaults.contains("web.whatsapp.com"))
    }

    @Test func aTypedSiteIsItsHost() {
        #expect(AwakeSites.site(from: " https://www.Web.WhatsApp.com/ ") == "web.whatsapp.com")
        #expect(AwakeSites.site(from: "app.slack.com/client/T1") == "app.slack.com")
        #expect(AwakeSites.site(from: "slack") == nil)
        #expect(AwakeSites.site(from: "") == nil)
    }

    /// A tab at a site kept awake: never on the timer, never for memory,
    /// short or out, nor for a page grown heavy; by hand or stuck, yes.
    @MainActor @Test func aSiteKeptAwakeNeverSleepsOnTheTimer() async throws {
        let (browser, tab, done) = try await world()
        defer { done() }
        tab.setAddressOptimistically(URL(string: "https://web.whatsapp.com/")!)
        #expect(AwakeSites.shared.keeps(tab.address))
        #expect(browser.awake(because: tab) == "a site kept awake")
        tab.touch()
        let late = AwakeClock.now + 24 * 3600
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: late).isEmpty)
        #expect(!browser.mayLighten(tab))
        #expect(browser.mayPutDown(tab))
        #expect(browser.canSleep([tab], byHand: true))
        #expect(!browser.canSleep([tab]))
        // Memory out and nothing else left: still not, a site on the
        // person's own list is left alone.
        #expect(browser.relief(now: late) == nil)
    }

    /// Its menu's Always Keep … Awake, and Let … Sleep again.
    @MainActor @Test func theTabMenuKeepsItsSiteAndLetsItGo() async throws {
        let (browser, tab, done) = try await world()
        defer { done() }
        let url = URL(string: "https://www.example-awake-test.com/page")!
        tab.setAddressOptimistically(url)
        #expect(browser.awake(because: tab) == nil)
        AwakeSites.shared.toggle(url)
        defer { AwakeSites.shared.remove("example-awake-test.com") }
        #expect(AwakeSites.shared.sites.contains("example-awake-test.com"))
        #expect(browser.awake(because: tab) == "a site kept awake")
        AwakeSites.shared.toggle(url)
        #expect(!AwakeSites.shared.sites.contains("example-awake-test.com"))
        #expect(browser.awake(because: tab) == nil)
    }

    /// A pin in a space not on screen stays awake, as one on screen does.
    @MainActor @Test func aPinInAnotherSpaceStaysAwake() async throws {
        let (browser, tab, done) = try await world()
        defer { done() }
        tab.pin = "Chat"
        // Its row parked as a space switch parks it, the tab in front kept.
        browser.showRow(browser.tabs.filter { $0 !== tab }, active: browser.activeID)
        browser.parked[UUID()] = Parked(tabs: [tab], active: nil)
        #expect(browser.parkedTabs.contains { $0 === tab })
        #expect(browser.awake(because: tab) == "pinned")
        tab.touch()
        let late = AwakeClock.now + 24 * 3600
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: late).isEmpty)
        #expect(browser.relief(now: late) == nil)
        tab.pin = nil
        tab.kept = true
        #expect(browser.awake(because: tab) == "kept")
        tab.kept = false
        #expect(browser.awake(because: tab) == nil)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: late).map(\.id) == [tab.id])
    }

    /// Grown heavy, a pin stays: only a page nothing keeps awake is put
    /// down for its size; pinned tabs are spared.
    @MainActor @Test func aHeavyPinIsNotPutDown() async throws {
        let (browser, tab, done) = try await world()
        defer { done() }
        tab.touch(at: Date(timeIntervalSinceNow: -11 * 60))
        #expect(browser.mayLighten(tab))
        tab.pin = "Chat"
        #expect(!browser.mayLighten(tab))
        #expect(browser.mayPutDown(tab))
        tab.pin = nil
        tab.kept = true
        #expect(!browser.mayLighten(tab))
    }
}
