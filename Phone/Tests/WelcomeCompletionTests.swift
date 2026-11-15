import XCTest
@testable import YabPhone

@MainActor
final class WelcomeCompletionTests: XCTestCase {
    func testCompletionRevealsHomeWithoutOpeningSearchLater() async throws {
        let run = FirstRun.shared
        let saved = (SettingsStore.shared.welcomed, SettingsUI.shared.welcomeForced)
        defer {
            run.reset()
            SettingsStore.shared.welcomed = saved.0
            SettingsUI.shared.welcomeForced = saved.1
        }
        let app = AppModel(world: try World.load(named: "empty"))
        run.reset()
        run.pretend(.incognito)
        SettingsUI.shared.welcomeForced = true
        run.finish(app)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FirstLaunch.shows(app))
        XCTAssertNil(app.surfaces.field, "completion must not schedule a field over home")
        XCTAssertNil(app.browser.tab)
        XCTAssertNil(TabStack.of(app).gallery)
    }
}
