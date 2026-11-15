import XCTest
import UIKit
import SyncKit
@testable import YabPhone

@MainActor
final class TabFolderEditingTests: XCTestCase {
    private func app() -> AppModel {
        AppModel(world: World(name: "edit", space: "S", spaces: [
            Space(id: "S", name: "Work", emoji: "", tint: RGB(220, 220, 230),
                  pins: [Tab(id: "pin", title: "Page title", site: "Site", icon: "globe", url: "https://example.com")],
                  kept: [.tab(Tab(id: "kept", title: "Kept title", site: "Site", icon: "globe"))])
        ]))
    }

    func testRenameResetAndPageNavigationPreserveSeparateTitles() throws {
        let app = app(), browser = app.browser
        XCTAssertTrue(browser.renameTab("pin", to: "  My name \n"))
        XCTAssertEqual(browser.tab("pin")?.name, "My name")
        XCTAssertEqual(browser.tab("pin")?.pageTitle, "Page title")
        var next = try XCTUnwrap(browser.tab("pin")); next.title = "New page title"
        browser.replace("pin", with: next)
        XCTAssertEqual(browser.tab("pin")?.title, "My name")
        XCTAssertEqual(browser.tab("pin")?.pageTitle, "New page title")
        XCTAssertFalse(browser.renameTab("pin", to: " \n"))
        XCTAssertTrue(browser.renameTab("pin", to: nil))
        XCTAssertEqual(browser.tab("pin")?.title, "New page title")
        XCTAssertNil(browser.tab("pin")?.name)
        XCTAssertTrue(browser.renameTab("kept", to: "Saved"))
        let encoded = try JSONEncoder().encode(browser.space)
        let restored = try JSONDecoder().decode(Space.self, from: encoded)
        XCTAssertEqual(restored.tab("kept")?.name, "Saved")
        XCTAssertEqual(restored.tab("kept")?.pageTitle, "Kept title")
    }

    func testResetUsesPageMetadataEvenWhenItMatchesTheCustomName() throws {
        let browser = app().browser
        XCTAssertTrue(browser.renameTab("pin", to: "Docs"))
        let page = Tab(id: "pin", title: "Docs", site: "Site", icon: "globe", url: "https://example.com/docs")
        browser.replace("pin", with: page)
        XCTAssertTrue(browser.renameTab("pin", to: nil))
        XCTAssertEqual(browser.tab("pin")?.title, "Docs")
    }

    func testNestedCreationDeletionPromotesChildrenAndNeverClosesTabs() throws {
        let app = app(), browser = app.browser
        let parent = try XCTUnwrap(browser.createFolder(name: "Parent", in: "S"))
        let child = try XCTUnwrap(browser.createFolder(name: "Child", in: "S", parent: parent))
        let tab = try XCTUnwrap(browser.tab("kept"))
        TabEdits.move(tab, in: "S", to: child, app: app)
        XCTAssertEqual(KeptTree.path(to: "kept", in: browser.space.kept).map(\.id), [parent, child])
        XCTAssertTrue(browser.renameFolder(child, in: "S", to: "Renamed"))
        XCTAssertTrue(browser.deleteFolder(parent, in: "S"))
        XCTAssertEqual(browser.space.folders.map(\.id), [child])
        XCTAssertEqual(browser.space.folder(holding: "kept")?.name, "Renamed")
        XCTAssertTrue(browser.deleteFolder(child, in: "S"))
        XCTAssertEqual(Set(browser.allTabs.map(\.id)), ["pin", "kept"])
        XCTAssertNil(browser.space.folder(holding: "kept"))
        XCTAssertTrue(browser.space.folders.isEmpty)
        XCTAssertNil(browser.createFolder(name: " ", in: "S"))
        XCTAssertNil(browser.createFolder(name: "Lost", in: "S", parent: "missing"))
    }

    func testPinMovesToFolderAndDepthIsLimitedToFive() throws {
        let app = app(), browser = app.browser
        var parent: String?
        for level in 1...5 { parent = try XCTUnwrap(browser.createFolder(name: "Level \(level)", in: "S", parent: parent)) }
        XCTAssertNil(browser.createFolder(name: "Too deep", in: "S", parent: parent))
        TabEdits.move(try XCTUnwrap(browser.tab("pin")), in: "S", to: parent, app: app)
        XCTAssertEqual(browser.tab("pin")?.place, .kept)
        XCTAssertEqual(KeptTree.path(to: "pin", in: browser.space.kept).count, 5)
        XCTAssertTrue(browser.space.pins.isEmpty)
    }

    func testLineLessMirrorKeepsThePageTitleAndEmptyNestedFolders() throws {
        let app = app()
        app.sync.attach(app, setup: nil)
        let root = try XCTUnwrap(app.browser.createFolder(name: "Root", in: "S"))
        let child = try XCTUnwrap(app.browser.createFolder(name: "Empty", in: "S", parent: root))
        XCTAssertTrue(app.browser.renameTab("pin", to: "Local label"))
        var page = try XCTUnwrap(app.browser.tab("pin")); page.title = "Latest page"
        app.browser.replace("pin", with: page)
        var ids = IDs()
        let mirror = SyncBridge.mirror(of: app.browser.spaces, ids: &ids, keeping: SyncMirror())
        XCTAssertEqual(mirror.tabs[ids.sync("pin")]?.title, "Latest page")
        XCTAssertEqual(mirror.tabs[ids.sync("pin")]?.name, "Local label")
        XCTAssertEqual(mirror.folders[ids.sync(child)]?.folder, ids.sync(root))
        XCTAssertEqual(mirror.folders.count, 2)
        app.sync.flushLocal()
    }

    func testLegacyCustomNameDoesNotReplaceTheSyncedPageTitle() {
        var tab = Tab(id: "legacy", title: "My label", site: "Site", icon: "globe")
        tab.name = "My label"
        let space = Space(id: "S", name: "Work", emoji: "", tint: RGB(220, 220, 230), pins: [tab])
        var ids = IDs(), prior = SyncMirror()
        let tid = ids.sync(tab.id), sid = ids.sync(space.id)
        prior.tabs[tid] = SyncTab(id: tid, space: sid, url: "https://site.com", title: "Original page", pin: "S", name: tab.name)
        let mirror = SyncBridge.mirror(of: [space], ids: &ids, keeping: prior)
        XCTAssertEqual(mirror.tabs[tid]?.title, "Original page")
        XCTAssertEqual(mirror.tabs[tid]?.name, "My label")
    }

    func testEditsUseTheViewedSpaceWithoutChangingThePageInFront() throws {
        let app = app()
        let other = Space(id: "other", name: "Other", emoji: "", tint: RGB(220, 220, 230),
                          kept: [.tab(Tab(id: "other-tab", title: "Other page", site: "Site", icon: "globe"))])
        app.browser.adopt(app.browser.spaces + [other])
        app.field.openSpaces()
        let pager = NewTabPager.shared
        let previousMode = pager.activeFieldMode, previousSpace = pager.spaceID, previousChats = pager.onChats
        defer { pager.activeFieldMode = previousMode; pager.spaceID = previousSpace; pager.onChats = previousChats }
        pager.activeFieldMode = .newTab; pager.spaceID = other.id; pager.onChats = false
        app.tabEdits.begin(.newFolder(other.id, nil, nil)); app.tabEdits.text = "Reading"
        app.tabEdits.save(in: app)
        let folder = try XCTUnwrap(app.browser.space(other.id)?.folders.first)
        TabEdits.move(try XCTUnwrap(app.browser.tab("other-tab")), in: other.id, to: folder.id, app: app)
        XCTAssertEqual(app.browser.space(other.id)?.folder(holding: "other-tab")?.id, folder.id)
        XCTAssertEqual(app.browser.spaceID, "S", "a menu edit does not navigate away from the page being read")
        app.tabEdits.begin(.folder(other.id, try XCTUnwrap(app.browser.space(other.id)?.folders.first)))
        app.tabEdits.text = "Stale"
        pager.spaceID = "S"
        app.tabEdits.save(in: app)
        XCTAssertEqual(app.browser.space(other.id)?.folders.first?.name, "Reading")
    }

    func testStaleRenameCannotChangeANavigatedTab() throws {
        let app = app()
        app.tabEdits.begin(.tab("S", try XCTUnwrap(app.browser.tab("pin"))))
        app.tabEdits.text = "Stale"
        var changed = try XCTUnwrap(app.browser.tab("pin")); changed.url = "https://example.org"
        app.browser.replace("pin", with: changed)
        app.tabEdits.save(in: app)
        XCTAssertNil(app.browser.tab("pin")?.name)
    }

    func testPrivateAndTodayTabsDoNotOfferRename() throws {
        let app = app()
        app.browser.open(Tab(id: "today", title: "Today", site: "Site", icon: "globe"))
        XCTAssertFalse(app.browser.renameTab("today", to: "No"))
        app.browser.open(Tab(id: "secret", title: "Secret", site: "Site", icon: "globe", isPrivate: true))
        XCTAssertFalse(app.browser.renameTab("secret", to: "No"))
        XCTAssertNil(app.browser.createFolder(name: "No", in: app.browser.spaceID))
    }
}
