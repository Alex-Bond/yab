import Foundation
import Testing
@testable import Fast

// Move to Space on a folder of yours (Browser.moveFolder), as Arc's Move to:
// the folder goes whole, its folders and tabs with it, kept to the other's
// kept and today's to its today's; a tab moved alone leaves its folder;
// the session of each space says so, which is what sync writes; ⌘Z puts it
// all back as it was.
@Suite(.serialized)
@MainActor
struct FolderToSpaceTests {
    /// Trip › Food with two tabs, Trip's own tab, Mail kept loose, and one of
    /// today's, in the first space; Work beside it.
    private func world(_ body: (Browser, UUID, (trip: Nest, food: Nest, tabs: [Tab])) throws -> Void) rethrows {
        let window = UUID(), browser = Browser(windowID: window)
        browser.prefs.usesSpaces = true
        let saved = Store.settings.object(forKey: "spaces")
        let work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: false)
        browser.spaces.append(work)
        Spaces.sharing.insert(work.id)
        let trip = Nest(name: "Trip"), food = Nest(name: "Food")
        food.parent = trip
        let tabs = (0..<5).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://folders.test/\(index)")!, title: "Tab \(index)")
            browser.prepare(tab)
            return tab
        }
        for tab in tabs.prefix(4) { tab.kept = true }
        tabs[0].nest = food
        tabs[1].nest = food
        tabs[2].nest = trip
        browser.lay(tabs)
        browser.activeID = tabs[4].id
        Browser.pretendHand = true
        defer {
            Browser.pretendHand = false
            browser.letGo()
            Spaces.sharing.remove(work.id)
            Spaces.pageCounts[work.id] = nil
            Store.settings.set(saved, forKey: "spaces")
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString)-\(work.id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
        }
        try body(browser, work.id, (trip, food, tabs))
    }

    @Test func theFolderGoesWholeToTheOtherKept() throws {
        try world { browser, work, made in
            #expect(browser.moveFolder(made.trip, to: work, say: false, ask: false))
            // Gone from here; Mail and today's stay.
            #expect(browser.tabs.map(\.id) == [made.tabs[3].id, made.tabs[4].id])
            #expect(browser.spaceID != work)
            let row = try #require(browser.parked[work])
            #expect(row.tabs.prefix(3).map(\.id) == made.tabs.prefix(3).map(\.id))
            #expect(try row.tabs.prefix(3).allSatisfy(\.kept))
            #expect(made.tabs[0].nest === made.food && made.food.parent === made.trip && made.trip.parent == nil)
            // Work's session, which sync writes from: the tree, Trip at the top.
            let entries = Session.read(space: work, window: browser.windowID).tabs
            #expect(entries.filter { $0.folder == made.food.id.uuidString }.count == 2)
            #expect(entries.first { $0.folder == made.food.id.uuidString }?.folderPath?.map(\.id) == [made.trip.id.uuidString])
            #expect(entries.first { $0.folder == made.trip.id.uuidString }?.folderPath == nil)
        }
    }

    @Test func aFolderInAFolderComesOutToTheTop() throws {
        try world { browser, work, made in
            #expect(browser.moveFolder(made.food, to: work, say: false, ask: false))
            #expect(made.food.parent == nil)
            #expect(browser.tabs.contains { $0 === made.tabs[2] } && made.tabs[2].nest === made.trip)
            let entries = Session.read(space: work, window: browser.windowID).tabs
            #expect(entries.count == 2 && entries.allSatisfy { $0.folder == made.food.id.uuidString && $0.folderPath == nil })
        }
    }

    @Test func aFolderOfTodaysLandsAtTheTopOfTheOthersToday() throws {
        try world { browser, work, made in
            let search = Nest(name: "Kyoto")
            search.fleeting = true
            let a = made.tabs[4], b = Tab()
            b.restore(url: URL(string: "https://folders.test/b")!, title: "B")
            browser.prepare(b)
            a.nest = search
            b.nest = search
            browser.lay(browser.tabs + [b])
            let old = Tab()
            old.restore(url: URL(string: "https://folders.test/old")!, title: "Old")
            browser.parked[work] = Parked(tabs: [old], active: old.id)
            #expect(browser.moveFolder(search, to: work, say: false, ask: false))
            let row = try #require(browser.parked[work])
            #expect(row.tabs.map(\.id) == [a.id, b.id, old.id])
            #expect(row.tabs.prefix(2).allSatisfy { !$0.kept && $0.nest === search })
            #expect(search.today)
        }
    }

    @Test func aTabAloneLeavesItsFolderBehind() throws {
        try world { browser, work, made in
            let moved = try #require(browser.moveTabs([made.tabs[0]], to: work, say: false))
            // In Work loose, still kept; Food stays here with its other tab.
            #expect(made.tabs[0].nest == nil && made.tabs[0].kept)
            #expect(made.tabs[1].nest === made.food && browser.tabs.contains { $0 === made.tabs[1] })
            let entries = Session.read(space: work, window: browser.windowID).tabs
            #expect(entries.count == 1 && entries[0].folder == nil)
            browser.undoMove(moved)
            #expect(made.tabs[0].nest === made.food && browser.tabs.first === made.tabs[0])
        }
    }

    @Test func everyTabOfAFolderInsideTakesThatFolderOutOfItsParent() throws {
        try world { browser, work, made in
            let moved = try #require(browser.moveTabs([made.tabs[0], made.tabs[1]], to: work, say: false))
            #expect(made.tabs[0].nest === made.food && made.food.parent == nil)
            #expect(made.tabs[2].nest === made.trip)
            browser.undoMove(moved)
            #expect(made.food.parent === made.trip)
        }
    }

    @Test func emptyFoldersInsideGoWithIt() throws {
        try world { browser, work, made in
            let previous = Folders.shared.browser
            Folders.shared.browser = browser
            let later = try #require(Folders.shared.makeEmpty(in: made.trip))
            defer {
                Folders.shared.removeEmpty(later)
                Folders.shared.browser = previous
            }
            #expect(Folders.shared.empties.contains { $0 === later })
            #expect(browser.moveFolder(made.trip, to: work, say: false, ask: false))
            #expect(!Folders.shared.empties.contains { $0 === later })
            #expect(Folders.shared.empties(in: work).contains { $0 === later })
            #expect(browser.undoWindow())
            #expect(Folders.shared.empties.contains { $0 === later } && later.parent === made.trip)
        }
    }

    @Test func undoPutsItAllBack() throws {
        try world { browser, work, made in
            let before = browser.tabs.map(\.id)
            #expect(browser.moveFolder(made.trip, to: work, say: false, ask: false))
            #expect(browser.undoWindow())
            #expect(browser.tabs.map(\.id) == before)
            #expect(try made.tabs.prefix(4).allSatisfy(\.kept))
            #expect(made.tabs[0].nest === made.food && made.tabs[2].nest === made.trip)
            #expect(made.food.parent === made.trip)
            #expect(!(browser.parked[work]?.tabs ?? []).contains { $0.nest?.within(made.trip) == true })
        }
    }

    @Test func notToTheSpaceOnScreenNorWithoutSpaces() throws {
        try world { browser, work, made in
            #expect(!browser.moveFolder(made.trip, to: browser.spaceID, say: false, ask: false))
            browser.prefs.usesSpaces = false
            #expect(!browser.moveFolder(made.trip, to: work, say: false, ask: false))
            browser.prefs.usesSpaces = true
            #expect(browser.tabs.count == 5)
        }
    }
}
