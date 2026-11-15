import Foundation
import Testing
@testable import Fast

// A tab in a folder of yours, closed as Arc closes a pinned tab: ⌘W and
// the cross put it down and its row stays (Close and Keep), Remove from
// Folder takes it out for good, and ⌘Z puts it back kept, in its folder
// (feedback #76).
@MainActor
struct KeptCloseTests {
    private func url(_ name: String) -> URL { URL(string: "https://nest.test/\(name)")! }

    @Test func closeKeepsAFolderTabInItsFolder() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let gsc = world.tabs["gsc"]!
        world.browser.close(gsc)
        #expect(world.browser.tabs.contains { $0 === gsc })
        #expect(gsc.kept && gsc.nest === world.seo)
        #expect(world.browser.ghosts.isEmpty)
    }

    @Test func removeFromFolderTakesItOutAndUndoPutsItBack() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let gsc = world.tabs["gsc"]!
        world.browser.discard([gsc], rekept: true)
        #expect(!world.browser.tabs.contains { $0 === gsc })
        #expect(!world.browser.tabs.contains { $0.address == url("gsc") })
        #expect(world.browser.ghosts.last?.kept == true)
        #expect(world.browser.ghosts.last?.nest === world.seo)
        #expect(world.browser.unkept.isEmpty)

        world.browser.reopen()
        let back = world.browser.tabs.first { $0.address == url("gsc") }
        #expect(back?.kept == true)
        #expect(back?.nest === world.seo)
        // Among the kept, in the run of the folder it left.
        let row = world.browser.tabs
        if let back, let at = row.firstIndex(where: { $0 === back }), let ga = row.firstIndex(where: { $0 === world.tabs["ga"] }) {
            #expect(at < ga)
            #expect(at < world.browser.keptEnd)
        } else {
            Issue.record("gsc did not come back")
        }
    }

    @Test func removingAFoldersLastTabsAndUndoingBringsTheFolderBack() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        world.browser.discard([world.tabs["sem"]!, world.tabs["sim"]!], rekept: true)
        #expect(!world.browser.tabs.contains { $0.nest === world.comp })

        world.browser.reopen()
        let back = world.browser.tabs.filter { $0.address == url("sem") || $0.address == url("sim") }
        #expect(back.count == 2)
        #expect(back.allSatisfy { $0.kept && $0.nest === world.comp })
        #expect(world.browser.nests.contains { $0 === world.comp })
    }

    @Test func closeAndDontKeepComesBackKeptOutOfAnyFolder() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        world.browser.discard([world.tabs["brex"]!], rekept: true)
        #expect(world.browser.ghosts.last?.kept == true)
        #expect(world.browser.ghosts.last?.nest == nil)

        world.browser.reopen()
        let back = world.browser.tabs.first { $0.address == url("brex") }
        #expect(back?.kept == true)
        #expect(back?.nest == nil)
    }

    @Test func aRemovedFoldersTabsComeBackAsTodays() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        // Remove Folder and N Tabs leaves its tabs' ghosts as before.
        world.browser.discard([world.tabs["ga"]!, world.tabs["amp"]!])
        #expect(world.browser.ghosts.allSatisfy { !$0.kept })
        world.browser.reopen()
        let back = world.browser.tabs.filter { $0.address == url("ga") || $0.address == url("amp") }
        #expect(back.count == 2)
        #expect(back.allSatisfy { !$0.kept })
    }
    // History › Recently Closed: a folder removed with its tabs is one line,
    // "SEO · 4 tabs", and brings them all back into it (Dia 1.16).
    @Test func aRemovedFolderIsOneLineOfRecentlyClosed() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        world.browser.close(world.tabs["hn"]!)
        world.browser.removeFolder(world.seo, with: world.browser.tabs(in: world.seo))
        let lines = world.browser.recentlyClosed
        #expect(lines.count == 2)
        guard case .folder(let nest, let group) = lines.first else {
            Issue.record("no folder line")
            return
        }
        #expect(nest === world.seo)
        #expect(group.count == 4)
        if case .tab(let ghost) = lines.last { #expect(ghost.url == url("hn")) } else { Issue.record("hn not a tab line") }

        world.browser.reopen(from: group[0])
        for name in ["gsc", "ywm", "sem", "sim"] {
            let back = world.browser.tabs.first { $0.address == url(name) }
            #expect(back?.kept == true)
            #expect(back?.nest?.within(world.seo) == true)
        }
        #expect(world.browser.recentlyClosed.count == 1)
    }

    // A few of a folder's tabs closed leave the folder: a line each.
    @Test func someOfAFoldersTabsAreLinesOfTheirOwn() {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        world.browser.discard([world.tabs["gsc"]!, world.tabs["ywm"]!], rekept: true)
        #expect(world.browser.recentlyClosed.count == 2)
        #expect(world.browser.recentlyClosed.allSatisfy { if case .tab = $0 { true } else { false } })
    }
}
