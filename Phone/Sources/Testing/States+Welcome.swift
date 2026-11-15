import Foundation

/// The first launch, page by page as the agreed onboarding draws it
/// (Welcome/FirstRun, work/design/yab-iphone-onboarding-2026-11-04). Shoot
/// them in the empty world, `remote shot welcome.1 --world empty`, or in mira
/// for the found Mac's spaces; they force the welcome on in any world.
extension StateCatalog {
    static let welcome: [NamedState] = [
        NamedState("welcome.1", "Welcome", "\u{201C}Yab.\u{201D} in glass, sites drifting through the letters; Hi, it\u{2019}s Yab, Get Started.") { _ in
            start(.welcome)
        },
        NamedState("welcome.2", "No network", "A code on screen, no network: the plates faded, the caption says Yab is trying.") { app in
            NetworkWatch.shared.forcedOffline = true
            code(app)
            start(.code)
        },
        NamedState("welcome.3", "Not now", "The empty browser: the New Tab field over an empty page (the field branch draws the field).") { app in
            SettingsUI.shared.welcomeForced = false
            SettingsStore.shared.welcomed = true
            app.surfaces.openField(.newTab)
        },
        NamedState("welcome.4", "No Mac yet in Settings", "Settings before a Mac: Your Mac says Join Your Mac.") { app in
            SettingsUI.shared.welcomeForced = false
            SettingsUI.shared.noMac = true
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
        },
        NamedState("welcome.5", "No Mac", "No key: Yab is on Mac too, the Mac, Yab for Mac with Copy, Yab is on my Mac, Continue.") { _ in
            start(.noMac)
        },
        NamedState("welcome.6", "Mac found", "The same Apple ID: the Mac's spaces in a straight deck, Join.") { app in
            found(app)
            start(.found)
        },
        NamedState("welcome.7", "Joining", "Join laid the deck in a row; each space counts its tabs.") { app in
            found(app)
            start(.found, joining: true, counted: 0.6)
        },
        NamedState("welcome.8", "In sync", "Every space counted with a check; the page goes on by itself.") { app in
            found(app)
            start(.found, joining: true, joined: true, counted: 1)
        },
        NamedState("welcome.9", "Code", "Join your Mac: the code on glass plates, Use Recovery Key, Copy Code.") { app in
            code(app)
            start(.code)
        },
        NamedState("welcome.10", "Mac let it in", "The plates turned green and came together into a checkmark.") { app in
            code(app)
            start(.code, joined: true)
        },
        NamedState("welcome.11", "Recovery Key", "A three-line monospaced field in the glass, Join.") { app in
            app.sync.typed = "MZ4Q-81TC-7HKD-W3PA-NE6F-QJ2R-V5XB-90LA"
            app.sync.pretend(.joining(.recovery(wrong: false)), sheet: false)
            start(.recovery)
        },
        NamedState("welcome.12", "Wrong key", "An error line right away, the field shook.") { app in
            app.sync.typed = "K7QM-4TZP-B2C9"
            app.sync.pretend(.joining(.recovery(wrong: true)), sheet: false)
            start(.recovery, wrongs: 1)
        },
        NamedState("welcome.13", "Search, ask, hand off", "The field and its three ways, Search, Ask, Your Mac, each with the phrase it took; Open Keyboard at Launch.") { _ in
            start(.field)
        },
        NamedState("welcome.14", "Links", "Links open in Yab: a tab with the stack behind it, Make Yab Default.") { _ in
            start(.links, joined: true)
        },
        NamedState("welcome.15", "Private", "Close the eyes: the field with its eyes, tap the eyes in the pen, Face ID for Private Tabs.") { _ in
            start(.incognito)
        },
        NamedState("welcome.16", "The whole way", "First launch live, from the name in glass.") { _ in
            FirstRun.shared.reset()
            SettingsUI.shared.welcomeForced = true
            NetworkWatch.shared.forcedOffline = false
        },
        NamedState("welcome.17", "Private, eyes shut", "Night: You\u{2019}re browsing Incognito, what Private means in chips (Stays on this iPhone, Gone when closed, Hidden from the agent, Never synced).") { _ in
            start(.incognito, incognito: true)
        },
    ]

    @MainActor
    private static func start(_ step: FirstRun.Step, joining: Bool = false, joined: Bool = false, counted: Double = 0,
                              wrongs: Int = 0, incognito: Bool = false) {
        SettingsUI.shared.welcomeForced = true
        FirstRun.shared.reset()
        FirstRun.shared.pretend(step, joining: joining, joined: joined, counted: counted, wrongs: wrongs, incognito: incognito)
    }

    @MainActor
    private static func found(_ app: AppModel) {
        app.sync.pretend(.on, sheet: false)
        app.sync.pretendMac(awake: true, front: nil)
    }

    @MainActor
    private static func code(_ app: AppModel) {
        app.sync.pretend(.joining(.code(FirstRun.standInCode)), sheet: false)
    }
}
