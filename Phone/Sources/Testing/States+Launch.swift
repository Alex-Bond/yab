import Foundation
import os

/// Yab coming to the front (Field/LaunchKeyboard): a cold launch lands in
/// New Tab's field with the keyboard up; a launch right
/// after leaving a page read halfway down keeps the page. Both go through
/// the rule itself, with what the launch would have read.
extension StateCatalog {
    static let launch: [NamedState] = [
        NamedState("launch.1", "Cold launch", "Yab opens on New Tab's field, the keyboard up, the page under it.") { app in
            await arrive(app, scrolled: 0, away: 3 * 60 * 60)
        },
        NamedState("launch.2", "Back to a page being read", "Launched a minute after leaving a page read halfway down: the page stays, no keyboard.") { app in
            await arrive(app, scrolled: 1200, away: 60)
        },
    ]

    @MainActor
    private static func arrive(_ app: AppModel, scrolled: Double, away: TimeInterval) async {
        if let tab = app.browser.tab {
            app.pages.activate(tab)
            await app.pages.waitUntilPainted(tab.id, timeout: .seconds(8))
        }
        var situation = app.launchKeyboardSituation(.launch, asked: false, away: away)
        situation.scrolled = scrolled
        let opens = LaunchKeyboard.opens(situation)
        Logger(subsystem: "dev.serafim.fast.iphone", category: "state").info("launch.opens=\(opens ? "yes" : "no", privacy: .public)")
        if opens { app.openLaunchField() }
        try? await Task.sleep(for: .milliseconds(opens ? 900 : 200))
    }
}
