import Foundation
import Testing
@testable import Fast

// Register #388 (alpha group): closing every tab never came down to the
// field; ⌘W walked through a folder's tabs instead, waking them one by one.
// As in Arc: closing one of today's lands on a neighbor among today's, the
// last of them on the ⌘T field, and a folder's tabs, awake or put down, are
// never landed on or woken for it.
@MainActor
struct KeptCloseAllTests {
    /// The nested world (brex; Analitycs { SEO { gsc, ywm, Competitors
    /// { sem, sim } }, ga, amp }; hn today's) with three more of today's,
    /// some of the folders' tabs open.
    private func world(awake: [String] = ["gsc", "sem", "ga"]) -> (NestedFoldersBrowserTests.World, [Tab]) {
        let world = NestedFoldersBrowserTests.world()
        let more = (1...3).map { index -> Tab in
            let tab = Tab()
            tab.restore(url: URL(string: "https://nest.test/today\(index)")!, title: "today \(index)")
            world.browser.prepare(tab)
            return tab
        }
        world.browser.lay(world.browser.tabs + more)
        for name in awake { _ = world.tabs[name]!.wake() }
        return (world, [world.tabs["hn"]!] + more)
    }

    private func folderTabs(_ world: NestedFoldersBrowserTests.World) -> [Tab] {
        world.browser.tabs.filter(\.kept)
    }

    /// ⌘W after ⌘W from the last of today's: links opened from a folder tab
    /// awake (gsc) and one put down (ywm) among them.
    @Test func closingTodaysOneByOneEndsOnTheField() {
        let (world, today) = world()
        defer { world.done() }
        let browser = world.browser
        today[1].from = world.tabs["gsc"]!.id
        today[2].from = world.tabs["ywm"]!.id
        let awake = Set(folderTabs(world).filter { !$0.asleep }.map(\.id))
        browser.select(today[3])
        var landed: [Tab.ID] = []
        for _ in 0..<12 {
            guard let active = browser.active else { break }
            browser.close(active)
            if let id = browser.activeID { landed.append(id) }
        }
        #expect(browser.activeID == nil && browser.fieldShowing)
        // Every landing one of today's, but the awake source of a link (gsc),
        // as Arc goes back to the Favorite a link came from.
        let kept = Set(folderTabs(world).map(\.id))
        #expect(landed.filter { kept.contains($0) }.allSatisfy { $0 == world.tabs["gsc"]!.id })
        #expect(!landed.contains(world.tabs["ywm"]!.id))
        // No folder tab woken: each awake now was awake before.
        let now = Set(folderTabs(world).filter { !$0.asleep }.map(\.id))
        #expect(now.isSubset(of: awake))
        #expect(folderTabs(world).count == 7)
        #expect(!browser.tabs.contains { !$0.kept })
    }

    @Test func puttingAFolderTabDownWithNoneOfTodaysLeftEndsOnTheField() {
        let (world, today) = world(awake: ["sem", "sim", "ga", "amp"])
        defer { world.done() }
        let browser = world.browser
        browser.close(today)
        browser.select(world.tabs["sem"]!)
        browser.close(world.tabs["sem"]!)
        #expect(browser.activeID == nil && browser.fieldShowing)
        #expect(world.tabs["sem"]!.asleep)
        #expect(!world.tabs["sim"]!.asleep && !world.tabs["ga"]!.asleep && !world.tabs["amp"]!.asleep)
        #expect(world.tabs["gsc"]!.asleep && world.tabs["ywm"]!.asleep)
    }

    @Test func puttingAFolderTabDownLandsOnTodays() {
        let (world, today) = world(awake: ["sem", "sim"])
        defer { world.done() }
        let browser = world.browser
        browser.select(world.tabs["sem"]!)
        today[2].touch(at: Date(timeIntervalSinceNow: 60))
        browser.close(world.tabs["sem"]!)
        #expect(browser.activeID == today[2].id)
        #expect(!world.tabs["sim"]!.asleep)
    }

    @Test func theLastOfTodaysFromAFolderTabPutDownDoesNotWakeIt() {
        let (world, today) = world(awake: [])
        defer { world.done() }
        let browser = world.browser
        let link = today[3]
        browser.select(link)
        browser.close(Array(today.dropLast()))
        link.from = world.tabs["sim"]!.id
        browser.close(link)
        #expect(browser.activeID == nil && browser.fieldShowing)
        #expect(folderTabs(world).allSatisfy { $0.asleep })
    }

    @Test func oneOfTodaysFromAFolderTabPutDownLandsOnItsNeighbor() {
        let (world, today) = world(awake: [])
        defer { world.done() }
        let browser = world.browser
        today[1].from = world.tabs["ga"]!.id
        browser.select(today[1])
        browser.close(today[1])
        #expect(browser.activeID == today[2].id)
        #expect(world.tabs["ga"]!.asleep)
    }

    @Test func oneOfTodaysFromAnAwakeFolderTabGoesBackToIt() {
        let (world, today) = world(awake: ["amp"])
        defer { world.done() }
        let browser = world.browser
        today[1].from = world.tabs["amp"]!.id
        browser.select(today[1])
        browser.close(today[1])
        #expect(browser.activeID == world.tabs["amp"]!.id)
    }

    /// The row out of its order (a kept folder's tab among today's): the
    /// neighbor is still one of today's.
    @Test func theNeighborIsTodaysEvenWithAFolderTabBesideIt() {
        let (world, today) = world(awake: ["sem"])
        defer { world.done() }
        let browser = world.browser
        var row = browser.tabs.filter { $0 !== world.tabs["sem"] }
        row.insert(world.tabs["sem"]!, at: row.firstIndex { $0 === today[2] }!)
        browser.lay(row)
        browser.select(today[1])
        browser.close(today[1])
        #expect(browser.active?.kept == false)
        #expect(browser.activeID == today[2].id)
    }
}
