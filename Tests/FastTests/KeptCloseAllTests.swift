import Foundation
import Testing
@testable import Fast

// Register #388 (alpha group): closing every tab never came down to the
// field; ⌘W walked through a folder's tabs instead, waking them one by one.
// Closing retained pages may now return to another live retained page.
// Previously put-down folder pages must still never be woken by closing.
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
    @Test func closingLivePagesOneByOneEndsOnTheField() {
        let (world, today) = world()
        defer { world.done() }
        let browser = world.browser
        today[1].from = world.tabs["gsc"]!.id
        today[2].from = world.tabs["ywm"]!.id
        let awake = Set(folderTabs(world).filter { !$0.asleep }.map(\.id))
        browser.select(world.tabs["gsc"]!)
        browser.select(today[3])
        var landed: [Tab.ID] = []
        for _ in 0..<12 {
            guard let active = browser.active else { break }
            browser.close(active)
            if let id = browser.activeID { landed.append(id) }
        }
        #expect(browser.activeID == nil && browser.fieldShowing)
        // A live held page reached on the way may return to another live
        // one; each is put down once. Nothing asleep before is reopened.
        let kept = Set(folderTabs(world).map(\.id))
        let heldLandings = landed.filter { kept.contains($0) }
        #expect(heldLandings.allSatisfy { awake.contains($0) })
        #expect(Set(heldLandings).count == heldLandings.count)
        #expect(!landed.contains(world.tabs["ywm"]!.id))
        // No folder tab woken: each awake now was awake before.
        let now = Set(folderTabs(world).filter { !$0.asleep }.map(\.id))
        #expect(now.isSubset(of: awake))
        #expect(folderTabs(world).count == 7)
        // The live Today's page closed. The other Today's rows were never
        // loaded, so putting down retained pages leaves them asleep.
        let remainingToday = browser.tabs.filter { !$0.kept }
        #expect(Set(remainingToday.map(\.id)) == Set(today.dropLast().map(\.id)))
        #expect(remainingToday.allSatisfy { $0.asleep })
    }

    @Test func puttingAFolderTabDownReturnsToTheLiveFolderPageViewedBefore() {
        let (world, today) = world(awake: ["sem", "sim", "ga", "amp"])
        defer { world.done() }
        let browser = world.browser
        browser.close(today)
        browser.select(world.tabs["sim"]!)
        browser.select(world.tabs["sem"]!)
        browser.close(world.tabs["sem"]!)
        #expect(browser.active === world.tabs["sim"] && !browser.fieldShowing)
        #expect(world.tabs["sem"]!.asleep)
        #expect(!world.tabs["sim"]!.asleep && !world.tabs["ga"]!.asleep && !world.tabs["amp"]!.asleep)
        #expect(world.tabs["gsc"]!.asleep && world.tabs["ywm"]!.asleep)
    }

    @Test func puttingAFolderTabDownLandsOnTodays() {
        let (world, today) = world(awake: ["sem", "sim"])
        defer { world.done() }
        let browser = world.browser
        browser.select(world.tabs["sem"]!)
        _ = today[2].wake()
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

    @Test func oneOfTodaysFromAFolderTabPutDownReturnsToThePreviousLiveToday() {
        let (world, today) = world(awake: [])
        defer { world.done() }
        let browser = world.browser
        today[1].from = world.tabs["ga"]!.id
        browser.select(today[2])
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
        browser.select(world.tabs["amp"]!)
        browser.select(today[1])
        browser.close(today[1])
        #expect(browser.activeID == world.tabs["amp"]!.id)
    }

    /// The row out of its order (a kept folder's tab among today's): the
    /// neighbor is still one of today's.
    @Test func repeatedCloseUsesTodaysNeighborEvenWithAFolderTabBesideIt() {
        let (world, today) = world(awake: ["sem"])
        defer { world.done() }
        let browser = world.browser
        var row = browser.tabs.filter { $0 !== world.tabs["sem"] }
        row.insert(world.tabs["sem"]!, at: row.firstIndex { $0 === today[1] }!)
        browser.lay(row)
        browser.select(today[1])
        browser.select(today[3])
        browser.close(today[3])
        #expect(browser.activeID == today[1].id)
        browser.close(today[1])
        #expect(browser.active?.kept == false)
        #expect(browser.activeID == today[0].id)
    }
}
