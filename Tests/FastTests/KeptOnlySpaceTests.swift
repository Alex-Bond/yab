import Foundation
import Testing
@testable import Fast

// Feedback #370: going to a space whose tabs are only kept ones, none in
// front, showed the last space's page behind the field. As Arc's empty
// window, such a space comes up on its own ground; one left on its kept
// tab comes back on it; a space with nothing in it at all keeps the page
// you were on under the field (docs/new-tab.md).
@MainActor
struct KeptOnlySpaceTests {
    @MainActor private final class World {
        let id = UUID()
        let browser: Browser
        // Imported spaces can have no Space.firstID; return to this fixture's home.
        let home: UUID
        private var made: [UUID] = []
        private let spaces: Any?
        private let spacesList: Data?
        private static var spacesFile: URL { Store.file("spaces.json") }

        init() {
            spaces = Store.settings.object(forKey: "spaces")
            spacesList = try? Data(contentsOf: World.spacesFile)
            let owner = Browser(windowID: id)
            browser = owner
            home = owner.spaceID
            owner.prefs.usesSpaces = true
        }

        func space(_ name: String) -> UUID {
            let space = Space(id: UUID(), name: name, icon: "🧪", ownSignIns: false)
            browser.spaces.append(space)
            Spaces.sharing.insert(space.id)
            made.append(space.id)
            return space.id
        }

        func page(_ address: String, kept: Bool = false) -> Tab {
            let tab = Tab()
            tab.restore(url: URL(string: address)!, title: address)
            tab.kept = kept
            browser.prepare(tab)
            return tab
        }

        func close() {
            browser.letGo()
            Store.settings.set(spaces, forKey: "spaces")
            if let spacesList { try? spacesList.write(to: World.spacesFile, options: .atomic) } else { try? FileManager.default.removeItem(at: World.spacesFile) }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            for space in made {
                Spaces.sharing.remove(space)
                Spaces.pageCounts[space] = nil
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)-\(space.uuidString).json"))
            }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
    }

    /// Personal on a page; Work with one kept tab, put down with ⌘W.
    private func world() -> (World, page: Tab, kept: Tab, work: UUID) {
        let world = World()
        let browser = world.browser
        let page = world.page("https://example.test/personal")
        browser.lay([page])
        browser.select(page)
        let work = world.space("Kept Work")
        browser.switchSpace(to: work)
        let kept = world.page("https://example.test/kept", kept: true)
        browser.lay([kept])
        browser.select(kept)
        return (world, page, kept, work)
    }

    @Test func aSpaceOfKeptTabsPutDownComesUpOnItsOwnGround() {
        let (world, page, kept, work) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(kept)
        #expect(browser.activeID == nil && browser.tabs.contains { $0 === kept })
        browser.switchSpace(to: world.home)
        #expect(browser.active === page)
        browser.switchSpace(to: work)
        #expect(browser.active == nil && browser.fieldShowing)
        #expect(browser.under == nil, "the last space's page stood behind the field")
    }

    // Alpha feedback 2026-10-28: the field over a space of kept tabs hid
    // the column, and Escape only cleared it. It goes now, until asked.
    @Test func escapePutsTheFieldAwayOverAColumnOfKeptTabs() {
        let (world, _, kept, work) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(kept)
        browser.switchSpace(to: world.home)
        browser.switchSpace(to: work)
        #expect(browser.fieldShowing && browser.fieldCanPutAway)
        browser.typed = "unfinished search"
        browser.dismiss()
        #expect(browser.active == nil && !browser.fieldShowing)
        #expect(browser.typed.isEmpty && !browser.editing && browser.under == nil)
        browser.newTab()
        #expect(browser.fieldShowing, "⌘T raises it again")
        browser.dismiss()
        browser.select(kept)
        #expect(browser.active === kept && !browser.fieldPutAway)
    }

    @Test func addressShortcutRaisesThePutAwayField() {
        let (world, _, kept, _) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(kept)
        browser.dismiss()
        #expect(browser.fieldPutAway && !browser.fieldShowing)
        browser.edit()
        #expect(browser.fieldShowing && browser.editing && !browser.fieldPutAway)
        browser.typed = "unfinished address"
        browser.dismiss()
        #expect(!browser.fieldShowing && !browser.editing && browser.typed.isEmpty)
    }

    @Test func returningToTheSpaceRaisesThePutAwayField() {
        let (world, page, kept, work) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(kept)
        browser.dismiss()
        #expect(!browser.fieldShowing)
        browser.switchSpace(to: world.home)
        #expect(browser.active === page && !browser.fieldPutAway)
        browser.switchSpace(to: work)
        #expect(browser.active == nil && browser.under == nil)
        #expect(browser.fieldShowing && !browser.fieldPutAway)
    }

    @Test func removingTheLastKeptTabLeavesTheFieldAvailable() {
        let (world, _, kept, _) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(kept)
        browser.dismiss()
        #expect(!browser.fieldShowing)
        // A refreshed row can lose its last kept tab without selecting a
        // replacement, for example after sync or a move to another Space.
        browser.lay([])
        #expect(browser.tabs.isEmpty && browser.active == nil)
        #expect(browser.fieldShowing && browser.fieldCanPutAway && !browser.fieldPutAway)
        browser.dismiss()
        #expect(!browser.fieldShowing && browser.fieldPutAway)
        // Sync can bring a kept row back without selecting it. The old
        // Escape belongs to the old column, not to this new arrival.
        browser.lay([kept])
        #expect(browser.fieldShowing && !browser.fieldPutAway)
        browser.dismiss()
        #expect(!browser.fieldShowing)
    }

    @Test func escapePutsTheFieldAwayWithOnlyAnOwnPin() {
        let (world, _, pin, _) = world()
        defer { world.close() }
        let browser = world.browser
        pin.kept = false
        pin.pin = "K"
        browser.close(pin)
        #expect(browser.active == nil && browser.fieldCanPutAway)
        browser.dismiss()
        #expect(!browser.fieldShowing)
        browser.select(pin)
        #expect(browser.active === pin && !browser.fieldPutAway)
    }

    @Test func sharedPinsAloneDoNotHideAnEmptySpacesField() {
        let (world, _, pin, _) = world()
        defer { world.close() }
        let browser = world.browser
        browser.close(pin)
        pin.kept = false
        pin.pin = "S"
        pin.everywhere = UUID()
        #expect(!browser.fieldCanPutAway)
        browser.dismiss()
        #expect(browser.fieldShowing && !browser.fieldPutAway)
    }

    @Test func aSpaceLeftOnItsKeptTabComesBackOnIt() {
        let (world, page, kept, work) = world()
        defer { world.close() }
        let browser = world.browser
        browser.switchSpace(to: world.home)
        #expect(browser.active === page)
        browser.switchSpace(to: work)
        #expect(browser.active === kept && browser.under == nil)
    }

    @Test func aSpaceWithNothingInItStillShowsThePageYouCameFrom() {
        let world = World()
        defer { world.close() }
        let browser = world.browser
        let page = world.page("https://example.test/personal")
        browser.lay([page])
        browser.select(page)
        let empty = world.space("Empty")
        browser.switchSpace(to: empty)
        #expect(browser.active == nil && browser.underTab === page)
    }
}
