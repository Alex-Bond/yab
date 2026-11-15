import SwiftUI

/// The first launch (Welcome/FirstRun): over the app until it is answered,
/// joined or not. Nothing here asks for a permission: notifications are
/// asked for the first time a task needs the person, never by the welcome.
struct WelcomeLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let shows = FirstLaunch.shows(app)
        let dark = AppAppearance.current == .dark
        ZStack {
            if shows {
                FirstRunView()
                    .transition(.opacity)
            }
        }
        .settingsAppearance()
        // The welcome covers the page: the status bar reads over its ground.
        .onChange(of: shows ? dark : nil, initial: true) { _, light in
            app.surfaces.statusBarLight = light
        }
    }
}

/// When the welcome stands over the app.
enum FirstLaunch {
    /// Without a Mac, or with one just found through iCloud Keychain, until
    /// the person answers it; once begun (`running`) it runs to its end
    /// whatever joining or the answer written down does underneath. A named
    /// state may say otherwise.
    static func shows(hasMac: Bool, welcomed: Bool, forced: Bool?, held: Bool = false, running: Bool = false) -> Bool {
        forced ?? (running || (!welcomed && (!hasMac || held)))
    }

    @MainActor
    static func shows(_ app: AppModel) -> Bool {
        shows(hasMac: app.hasMac, welcomed: SettingsStore.shared.welcomed, forced: SettingsUI.shared.welcomeForced,
              held: app.sync.joinedByICloud, running: FirstRun.shared.started)
    }
}
