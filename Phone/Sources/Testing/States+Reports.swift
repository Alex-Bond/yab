import Foundation

/// The named states of crash reports and daily activity (Reports/): the
/// question after a crash, and About with its switches as a build with a
/// site shows them, sending turned on or sharing turned off.
extension StateCatalog {
    static let reports: [NamedState] = [
        NamedState("reports.ask", "Crash reports: the question",
                   "After a crash, over the page: Share saved crash reports? Send or Don’t Send.") { _ in
            // Over the page once it is up; the answer goes nowhere.
            try? await Task.sleep(for: .milliseconds(300))
            CrashQuestion.presenter()?.present(CrashQuestion.alert { _ in }, animated: false)
        },

        NamedState("reports.about-on", "About: sending on",
                   "Automatically send crash reports on, Share daily activity on.") { app in
            SettingsStore.shared.sendCrashReports = true
            SettingsStore.shared.shareDailyActivity = true
            about(app)
        },

        NamedState("reports.about-off", "About: sharing off",
                   "Crash reports asked after each crash, Share daily activity off.") { app in
            SettingsStore.shared.sendCrashReports = false
            SettingsStore.shared.shareDailyActivity = false
            about(app)
        },
    ]

    @MainActor
    private static func about(_ app: AppModel) {
        SettingsUI.shared.assumeDefaultBrowser = true
        SettingsUI.shared.assumeReports = true
        app.surfaces.openSettings()
        SettingsUI.shared.openPage(.about)
    }
}
