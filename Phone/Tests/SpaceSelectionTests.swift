import XCTest
import SyncKit
@testable import YabPhone

@MainActor
final class SpaceSelectionTests: XCTestCase {
    private var previousSpace: Space.ID?

    override func setUp() {
        previousSpace = NewTabPager.shared.spaceID
    }

    override func tearDown() {
        NewTabPager.shared.spaceID = previousSpace
    }

    private func app() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"))
    }

    func testSwitchingSpacesPreservesEveryTabAndSelection() throws {
        let app = try app()
        let before = app.browser.spaces
        app.field.openSpaces()
        for _ in 0..<3 {
            for space in before where !space.isPrivate { app.selectSpacePage(space.id) }
        }
        XCTAssertEqual(app.browser.spaces, before)
    }

    func testMacShortcutBelongsOnlyToItsSourceSpace() throws {
        let app = try app()
        let mac = try XCTUnwrap(app.browser.onMac)
        let owner = try XCTUnwrap(app.browser.space(holding: mac.id))
        XCTAssertNotNil(NewTabContent.macNow(app, in: owner.id))
        for space in app.browser.spaces where space.id != owner.id {
            XCTAssertNil(NewTabContent.macNow(app, in: space.id), space.name)
        }
    }

    func testMacPresenceResolvesItsRecordInsteadOfMatchingURLAcrossSpaces() throws {
        let app = try app()
        app.sync.attach(app, setup: nil)
        app.browser.setOnMac(nil)
        app.sync.pretendMacToday([(url: "https://example.com/same", title: "Mac page")], in: "work")
        let front = SyncPresence(device: "mac", name: "Mac", at: Date().timeIntervalSince1970,
                                 url: "https://example.com/same", title: "Mac page", tab: "mac-work-0")
        app.sync.pretendMacs([SyncMac(id: "mac", name: "Mac", model: "", online: true, front: front)])
        app.browser.open(Tab(id: "same-url-personal", title: "Same URL", site: "Example", icon: "globe",
                             url: "https://example.com/same"), in: "personal")
        XCTAssertEqual(NewTabContent.macNow(app, in: "work")?.title, "Mac page")
        guard case .open = NewTabContent.macNow(app, in: "work")?.action else {
            return XCTFail("a URL in another space must not be selected")
        }
        XCTAssertNil(NewTabContent.macNow(app, in: "personal"))
        XCTAssertNil(NewTabContent.macNow(app, in: "lisbon"))
    }

    func testChoosingASpaceKeepsItBeforeOpeningAnyTab() throws {
        let app = try app()
        app.field.openSpaces()
        app.selectSpacePage("lisbon")
        XCTAssertEqual(app.browser.spaceID, "lisbon")
        XCTAssertEqual(app.browser.ordinarySpaceID, "lisbon")
        XCTAssertEqual(NewTabPager.shared.spaceID, "lisbon")
        app.field.close()
        app.field.openNewTab(privately: false)
        XCTAssertEqual(app.browser.spaceID, "lisbon")
    }

    func testSearchFromViewedSpaceIsInsertedThere() throws {
        let app = try app()
        app.field.openSpaces()
        app.selectSpacePage("lisbon")
        app.field.askFromSpaces()
        app.field.typed("g")
        app.choose(WordRow(action: .searchFor("g"), icon: .magnifier, title: "g", subtitle: "", key: .search, group: .web))
        let selected = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(app.browser.spaceID, "lisbon")
        XCTAssertEqual(app.browser.space(holding: selected.id)?.id, "lisbon")
        XCTAssertTrue(app.browser.space("lisbon")!.today.contains { $0.id == selected.id })
        XCTAssertFalse(app.browser.space("personal")!.allTabs.contains { $0.id == selected.id })
    }

    func testFrequentTileAdoptsTheViewedSpaceBeforeClosingTheField() throws {
        let app = try app()
        app.field.openSpaces()
        NewTabPager.shared.spaceID = "lisbon"
        let site = try XCTUnwrap(NewTabContent.make(for: app).frequent.first)
        app.chooseFrequent(site)
        XCTAssertEqual(app.browser.spaceID, "lisbon")
        XCTAssertEqual(app.browser.space(holding: try XCTUnwrap(app.browser.tab).id)?.id, "lisbon")
    }

    func testSiteSearchRowAdoptsTheViewedSpace() throws {
        let app = try app()
        app.field.openSpaces()
        NewTabPager.shared.spaceID = "lisbon"
        let site = try XCTUnwrap(NewTabContent.make(for: app).frequent.first)
        app.choose(WordRow(action: .site(key: site.key), icon: .magnifier, title: site.name,
                           subtitle: "", key: .search, group: .web))
        XCTAssertEqual(app.browser.spaceID, "lisbon")
        XCTAssertEqual(app.browser.space(holding: try XCTUnwrap(app.browser.tab).id)?.id, "lisbon")
    }

    func testAddressPreviewAndNonSpacePagesDoNotChangeTheSelectedSpace() throws {
        let app = try app()
        let original = app.browser.spaceID
        app.surfaces.openField(.address)
        app.selectSpacePage("lisbon")
        XCTAssertEqual(app.browser.spaceID, original)
        XCTAssertEqual(NewTabPager.shared.spaceID, "lisbon")
        app.selectSpacePage(NewTabPager.chatsPage)
        app.selectSpacePage(NewTabPager.privatePage)
        app.selectSpacePage("deleted")
        XCTAssertEqual(app.browser.spaceID, original)
        XCTAssertEqual(NewTabPager.shared.spaceID, "lisbon")
    }

    func testViewedSpaceSurvivesRelaunchWithAndWithoutANewTab() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpaceSelection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = LaunchOptions(arguments: ["Yab", "-YabProfileDirectory", directory.path])
        var app = AppModel.launch(options)
        let chosen = app.browser.createSpace(name: "Studio", emoji: "", look: SpaceLook(color: RGB(100, 150, 200)))
        app.browser.showSpace("local.personal")
        app.field.openSpaces()
        app.selectSpacePage(chosen)
        await app.flushProfile()
        app = AppModel.launch(options)
        XCTAssertEqual(app.browser.spaceID, chosen, "selection alone must be saved")
        app.field.openNewTab(privately: false)
        app.field.typed("g")
        app.choose(WordRow(action: .searchFor("g"), icon: .magnifier, title: "g", subtitle: "", key: .search, group: .web))
        let tab = try XCTUnwrap(app.browser.tab)
        await app.flushProfile()
        let restored = AppModel.launch(options)
        XCTAssertEqual(restored.browser.spaceID, chosen)
        XCTAssertEqual(restored.browser.tab?.id, tab.id)
        XCTAssertEqual(restored.browser.space(holding: tab.id)?.id, chosen)
    }
}
