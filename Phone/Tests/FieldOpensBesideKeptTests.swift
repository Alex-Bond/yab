import XCTest
@testable import YabPhone

/// A page chosen in the plate's field over a pin or a kept tab (a folder's,
/// a live folder's) opens as a new tab first in today's; only a tab of
/// today's is loaded over. Loaded into a live folder's tab, the page rewrote
/// that tab on every device, so it looked as if new tabs went into the folder.
@MainActor
final class FieldOpensBesideKeptTests: XCTestCase {
    private var oldDisabled = false
    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() { Motion.disabled = oldDisabled }

    private func mira() throws -> AppModel { AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false }) }
    private func page(_ app: AppModel) -> Tab {
        PageFixtures.tab(for: URL(string: "https://www.apple.com/shop")!, in: app.world, fixturesEnabled: app.fixturesEnabled)
    }

    func testAFoldersTabStaysAndThePageOpensAtTodaysTop() throws {
        let app = try mira()
        app.browser.showSpace("work")
        app.browser.select("work-onb-spec")
        let kept = try XCTUnwrap(app.browser.tab("work-onb-spec"))
        XCTAssertEqual(kept.place, .kept)

        app.show(page(app), newTab: false)

        let space = try XCTUnwrap(app.browser.space("work"))
        XCTAssertEqual(app.browser.tab("work-onb-spec")?.url, kept.url)
        XCTAssertEqual(space.folder(holding: "work-onb-spec")?.id, "work-onboarding")
        XCTAssertNotEqual(app.browser.tab?.id, "work-onb-spec")
        XCTAssertEqual(space.today.first?.id, app.browser.tab?.id)
        XCTAssertEqual(app.browser.tab?.place, .today)
    }

    func testATodaysTabIsLoadedOver() throws {
        let app = try mira()
        app.browser.showSpace("work")
        app.browser.select("work-hn")
        let count = try XCTUnwrap(app.browser.space("work")).today.count

        app.show(page(app), newTab: false)

        XCTAssertEqual(app.browser.tab?.id, "work-hn")
        XCTAssertEqual(app.browser.space("work")?.today.count, count)
    }

    func testTheRowsSayNewTabOverAKeptTab() {
        XCTAssertEqual(Words.rows(for: "apple.com", in: .page, replaces: false).first?.subtitle, "Open in a new tab")
        XCTAssertEqual(Words.rows(for: "apple.com", in: .page).first?.subtitle, "Open in this tab")
    }
}
