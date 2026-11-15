import XCTest
@testable import YabPhone

/// When Yab opens on New Tab's field with the keyboard up (request 1086):
/// a tab comes back as it was, and a page just being read is kept in front.
@MainActor
final class LaunchKeyboardTests: XCTestCase {
    private typealias S = LaunchKeyboard.Situation

    func testAColdLaunchOpensTheField() {
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch)))
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch, away: 3 * 60 * 60)))
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch, hasTab: false)))
    }

    func testComingBackKeepsThePageUnlessNoTabIsOpen() {
        // Reactivated with a tab, the tab; with none, the search bar.
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .back, away: 3 * 60 * 60)))
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .back, scrolled: 0, away: 24 * 60 * 60)))
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .back, hasTab: false, away: 5)))
    }

    func testAPageBeingReadStaysAfterIOSEndedYab() {
        let reading = LaunchKeyboard.readingDepth + 1
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, scrolled: reading, away: 60)))
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, scrolled: 4000, away: LaunchKeyboard.readingHold - 1)))
        // Long away, or never known to have gone: a new search.
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch, scrolled: reading, away: LaunchKeyboard.readingHold)))
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch, scrolled: reading, away: nil)))
        // Near the top is not reading.
        XCTAssertTrue(LaunchKeyboard.opens(S(moment: .launch, scrolled: LaunchKeyboard.readingDepth, away: 60)))
    }

    func testNeverOverSomethingElse() {
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, enabled: false)), "Settings › General switch off")
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, asked: true)), "launched for a link, a widget, a notification")
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, welcome: true)), "never during the welcome")
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, privateFront: true)), "no Face ID ask nobody started")
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .launch, covered: true)), "the field, a chat or Settings already up")
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .back, enabled: false, hasTab: false)))
        XCTAssertFalse(LaunchKeyboard.opens(S(moment: .back, welcome: true, hasTab: false)))
    }

    func testTimeAwayIsKeptBetweenLaunches() throws {
        let name = "launch-keyboard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(LaunchKeyboard.away(in: defaults))
        let left = Date(timeIntervalSinceReferenceDate: 800_000_000)
        LaunchKeyboard.left(at: left, in: defaults)
        XCTAssertEqual(try XCTUnwrap(LaunchKeyboard.away(now: left.addingTimeInterval(90), in: defaults)), 90, accuracy: 0.001)
        // A clock set back never reads as negative time.
        XCTAssertEqual(LaunchKeyboard.away(now: left.addingTimeInterval(-30), in: defaults), 0)
    }

    func testTheSwitchIsOnUntilTurnedOff() throws {
        let name = "launch-keyboard-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.openKeyboardAtLaunch)
        store.openKeyboardAtLaunch = false
        XCTAssertFalse(SettingsStore(defaults: defaults).openKeyboardAtLaunch)
    }

    func testTestRunsAskForItByName() {
        XCTAssertFalse(LaunchOptions(arguments: ["Yab"]).launchKeyboard)
        XCTAssertTrue(LaunchOptions(arguments: ["Yab", "-YabLaunchKeyboard", "YES"]).launchKeyboard)
    }

    func testTheAppSaysWhatIsInFrontAndOpensNewTab() throws {
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        XCTAssertNotNil(app.browser.tab)
        var situation = app.launchKeyboardSituation(.launch, asked: false, away: 60)
        XCTAssertTrue(situation.hasTab)
        XCTAssertFalse(situation.covered)
        XCTAssertFalse(situation.privateFront)
        XCTAssertEqual(situation.away, 60)
        XCTAssertEqual(situation.enabled, SettingsStore.shared.openKeyboardAtLaunch)

        app.openLaunchField()
        XCTAssertEqual(app.surfaces.field, .newTab)
        situation = app.launchKeyboardSituation(.launch, asked: false, away: 60)
        XCTAssertTrue(situation.covered, "a second arrival never opens it again")
        XCTAssertFalse(LaunchKeyboard.opens(situation))
    }
}
