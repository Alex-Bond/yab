import SwiftUI
import XCTest
@testable import YabPhone

/// The actual root query must lead to a working preference and Back must
/// keep the query, scroll and reviewable draft alive underneath the page.
@MainActor
final class SettingsIndexTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() {
        suite = "settings-index-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        Motion.disabled = false
    }

    func testSearchingDarkReachesTheActualChoiceAndTheChoicePersists() throws {
        let store = SettingsStore(defaults: defaults)
        let content = SettingsContent(store: store, context: SettingsContext())
        let result = try XCTUnwrap(SettingsIndex.matches("  DARK ", content: content).first { $0.page == .appearance })
        XCTAssertEqual(result.row, "appearance.dark", "the actual preference must win over the page keyword")
        let row = try XCTUnwrap(content.sections(result.page).flatMap(\.rows).first { $0.id == result.row })
        guard case let .choice(selected, choose) = row.kind else { return XCTFail("search led to a dead preference") }
        XCTAssertFalse(selected)
        choose()
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .dark)
        XCTAssertEqual(SettingsIndex.matches("appearance", content: content).first?.page, .appearance)
        XCTAssertNil(SettingsIndex.matches("appearance", content: content).first?.row, "an explicit page search still opens its hero")
    }

    func testPushBackAndClosePreserveOnlySessionDraftAndConsumeReturnOnce() {
        Motion.disabled = true
        let ui = SettingsUI()
        ui.search = "dark"
        ui.rootOffset = 96
        ui.feedbackDraft = "The title is difficult to read."
        ui.openPage(.appearance, from: "appearance.dark")
        ui.openPage(.privateTabs)
        XCTAssertEqual(ui.navigation, [.page(.appearance), .page(.privateTabs)])
        ui.closePage()
        XCTAssertEqual(ui.pageID, .appearance)
        XCTAssertEqual(ui.search, "dark")
        XCTAssertEqual(ui.rootOffset, 96)
        var returned = 0
        ui.returnPrepared = true
        ui.returnToTray = { returned += 1 }
        ui.afterClose = ui.returnToTray
        ui.settingsGone()
        ui.settingsGone()
        XCTAssertEqual(returned, 1, "one close must not reopen the originating tray twice")
        XCTAssertTrue(ui.navigation.isEmpty)
        XCTAssertTrue(ui.search.isEmpty)
        XCTAssertNil(ui.searchSpot)
        XCTAssertEqual(ui.rootOffset, 0)
        XCTAssertEqual(ui.feedbackDraft, "The title is difficult to read.", "closing Settings must not discard the feedback draft")
        XCTAssertNil(ui.returnToTray)
        XCTAssertNil(ui.afterClose)
    }

    func testNoMacSearchStillLeadsToARealJoinActionAndNoInventedSleepTime() throws {
        let content = SettingsContent(store: SettingsStore(defaults: defaults), context: SettingsContext(macAsleep: true, hasMac: false))
        XCTAssertEqual(content.macValue, "Asleep")
        let sync = try XCTUnwrap(SettingsIndex.matches("recovery", content: content).first { $0.page == .sync })
        let join = try XCTUnwrap(content.sections(sync.page).flatMap(\.rows).first { $0.id == "join" })
        guard case .join = join.kind else { return XCTFail("the available Sync action must really join") }
        XCTAssertTrue(SettingsIndex.matches("zzzzunknown", content: content).isEmpty)
    }
}
