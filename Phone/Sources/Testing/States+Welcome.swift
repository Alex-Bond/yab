import Foundation

/// The first launch, step by step as the accepted "One chain" draws it
/// (Welcome/FirstRun, design unse3fvhd9 v4). Shoot them in the empty world,
/// `remote shot welcome.1 --world empty`, or in mira for the found Mac's
/// name; they force the welcome on in any world. welcome.3 and welcome.4 are
/// the browser after it, kept at their numbers.
extension StateCatalog {
    static let welcome: [NamedState] = [
        NamedState("welcome.1", "Welcome", "The drop, the pen drawings around it, Your Mac's tabs. In your pocket., Get Started.") { _ in
            start(.welcome)
        },
        NamedState("welcome.2", "Code, no connection", "The code's keycaps pale, the line under them says Yab keeps trying.") { app in
            NetworkWatch.shared.forcedOffline = true
            code(app)
            start(.code, .init(mac: .none, hero: .key))
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
        NamedState("welcome.5", "Join Your Mac, looking", "The drop is ‹; tabs, key and globe are the three ways; the tabs drawing has no colour and sways.") { _ in
            start(.mac)
        },
        NamedState("welcome.6", "Join Your Mac, found", "Same Apple ID: the tabs drawing painted in, the first row says the Mac's name.") { app in
            found(app)
            start(.mac, .init(mac: .found))
        },
        NamedState("welcome.7", "Join Your Mac, not found", "No Mac on this Apple ID: the tabs back and pale, the key in front.") { _ in
            start(.mac, .init(mac: .none))
        },
        NamedState("welcome.8", "Join Your Mac, in sync", "A reinstall that kept the key: MacBook Pro, In Sync.") { app in
            found(app)
            start(.mac, .init(mac: .insync))
        },
        NamedState("welcome.9", "Code", "The key in the card's corner, eight keycaps, Copy, the next code's countdown, three steps for the Mac.") { app in
            code(app)
            start(.code, .init(mac: .none, hero: .key))
        },
        NamedState("welcome.10", "Code, the Mac let it in", "The keycaps black, the line says the Mac joined; no check marks.") { app in
            code(app)
            app.sync.pretendMac(awake: true, front: nil)
            start(.code, .init(mac: .none, hero: .key, accepted: true))
        },
        NamedState("welcome.11", "Code, renewed", "Ten minutes on: a new code flipped onto the keycaps, the line says the old one expired.") { app in
            app.sync.pretend(.joining(.code("M2LD-8HTW")), sheet: false)
            start(.code, .init(mac: .none, hero: .key, renewed: true))
        },
        NamedState("welcome.12", "Recovery Key, wrong", "The last group red, the line says to check each group of four.") { app in
            app.sync.typed = "K7QM-4TZP-B2C9"
            app.sync.pretend(.joining(.recovery(wrong: true)), sheet: false)
            start(.recovery, .init(mac: .none, hero: .key, wrongs: 1))
        },
        NamedState("welcome.13", "Recovery Key", "The same card, a new height: fourteen empty groups, Paste, Type It Instead.") { app in
            app.sync.typed = ""
            app.sync.pretend(.joining(.recovery(wrong: false)), sheet: false)
            start(.recovery, .init(mac: .none, hero: .key))
        },
        NamedState("welcome.14", "Recovery Key, pasted", "All fourteen groups filled, Join on.") { app in
            app.sync.typed = recoveryKey
            app.sync.pretend(.joining(.recovery(wrong: false)), sheet: false)
            start(.recovery, .init(mac: .none, hero: .key))
        },
        NamedState("welcome.15", "Recovery Key, typing", "Type It Instead: the keyboard up, Join riding it, the caret in the next group.") { app in
            app.sync.typed = "MZ4Q-81TC-7H"
            app.sync.pretend(.joining(.recovery(wrong: false)), sheet: false)
            start(.recovery, .init(mac: .none, hero: .key, typing: true))
        },
        NamedState("welcome.16", "Private by Default", "The shield, four trackers thrown back, the count 4 beside Block ads and trackers.") { app in
            found(app)
            SettingsStore.shared.blocksAds = true
            start(.privacy, .init(mac: .found, trackers: .thrown, thrownBack: 4))
        },
        NamedState("welcome.17", "Private by Default, blocking off", "The shield grey, the trackers staying around it.") { app in
            found(app)
            SettingsStore.shared.blocksAds = false
            start(.privacy, .init(mac: .found, trackers: .at))
        },
        NamedState("welcome.18", "Make Yab Default?", "The shield's blot swelled into the drop on paper: the app icon; a link opens in Safari.") { app in
            found(app)
            SettingsUI.shared.assumeDefaultBrowser = false
            start(.makeDefault, .init(mac: .found))
        },
        NamedState("welcome.19", "Make Yab Default?, Yab chosen", "Back from iOS Settings with Yab: the link opens in Yab, Continue.") { app in
            found(app)
            start(.makeDefault, .init(mac: .found, isDefault: true))
        },
        NamedState("welcome.20", "Make Yab Default?, still Safari", "Back from iOS Settings with nothing changed: still Safari, the question stays.") { app in
            found(app)
            SettingsUI.shared.assumeDefaultBrowser = false
            start(.makeDefault, .init(mac: .found))
        },
        NamedState("welcome.21", "To search", "The hand-over done: New Tab's own search sheet where the icon stretched to, with the eyes the drop became.") { app in
            found(app)
            start(.makeDefault, .init(mac: .found, isDefault: true))
            // The hand-over itself, not a still of the stage: the chain's last
            // step opens the app's own field (FirstRun.toEnd).
            FirstRun.shared.holds = false
            FirstRun.shared.toEnd(app)
        },
        NamedState("welcome.22", "Private by Default, without a Mac", "Continue Without a Mac: the globe became the shield.") { _ in
            SettingsStore.shared.blocksAds = true
            start(.privacy, .init(mac: .none, hero: .globe, trackers: .thrown, thrownBack: 4, withoutMac: true))
        },
        NamedState("welcome.23", "The whole way", "First launch live: the drop grows, the drawings burst, the words come out of blur.") { _ in
            FirstRun.shared.reset()
            SettingsUI.shared.welcomeForced = true
            NetworkWatch.shared.forcedOffline = false
        },
    ]

    /// A Recovery Key's shape (fourteen groups, base32), not a real key.
    static let recoveryKey = "MZ4Q-81TC-7HKD-W3PA-NE6F-QJ2R-V5XB-90LA-C3TK-8RMP-H2QW-6ZNE-4YDS-JK7"

    @MainActor
    private static func start(_ step: FirstRun.Step, _ still: FirstRun.Still = .init()) {
        // The app always wears the search sheet; a test run draws it only when
        // asked, and the chain ends in it (FieldModel.sheetAllowed).
        FieldModel.sheetInTests = true
        SettingsUI.shared.welcomeForced = true
        FirstRun.shared.pretend(step, still)
    }

    @MainActor
    private static func code(_ app: AppModel) {
        app.sync.pretend(.joining(.code(FirstRun.standInCode)), sheet: false)
    }

    @MainActor
    private static func found(_ app: AppModel) {
        app.sync.pretend(.on, sheet: false)
        app.sync.pretendMac(awake: true, front: nil)
    }
}
