import Foundation
import Testing
@testable import Fast

// Request #415: Arc's middle button on a pinned tab closes its page, and on
// the pinned tab already closed takes it out of the sidebar. Yab did the
// first and nothing on the second.
@MainActor
struct MiddleShutTests {
    private func url(_ name: String) -> URL { URL(string: "https://nest.test/\(name)")! }

    @Test func onlyAKeptTabPutDownLeavesTheKept() {
        #expect(Browser.middleUnkeeps(kept: true, asleep: true))
        #expect(!Browser.middleUnkeeps(kept: true, asleep: false))
        #expect(!Browser.middleUnkeeps(kept: false, asleep: true))
        #expect(!Browser.middleUnkeeps(kept: false, asleep: false))
    }

    @Test func secondPressRemovesAKeptTabAndUndoPutsItBack() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let browser = world.browser
        let gsc = world.tabs["gsc"]!
        _ = gsc.wake()
        browser.select(gsc)
        #expect(!gsc.asleep)

        // The first press puts it down: its row stays, in its folder.
        browser.middleShut(gsc)
        #expect(browser.tabs.contains { $0 === gsc })
        #expect(gsc.kept && gsc.asleep && gsc.nest === world.seo)
        #expect(browser.ghosts.isEmpty)

        // The second takes it out, as its cross does.
        browser.middleShut(gsc)
        #expect(!browser.tabs.contains { $0 === gsc })
        #expect(browser.ghosts.last?.kept == true)
        #expect(browser.ghosts.last?.nest === world.seo)

        browser.reopen()
        let back = browser.tabs.first { $0.address == url("gsc") }
        #expect(back?.kept == true)
        #expect(back?.nest === world.seo)
    }

    @Test func todaysTabClosesAtOnce() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let hn = world.tabs["hn"]!
        world.browser.middleShut(hn)
        #expect(!world.browser.tabs.contains { $0 === hn })
        #expect(world.browser.ghosts.last?.kept == false)
    }
}
