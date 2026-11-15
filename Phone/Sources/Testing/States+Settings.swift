import Foundation
import SwiftUI

/// The named states of the settings branch, registered here and nowhere else:
/// the prototype's board "Where settings are and what's in them" (settings.1, .3, .4;
/// settings.2, the word in the field, is the field's to draw, H + E), the
/// pages Settings' rows open, and the first launch (States+Welcome.swift).
///
/// settings.1 assumes Yab is the default browser, as the prototype's world
/// does: the simulator can't make it one, and the row would say "Not Yet".
extension StateCatalog {
    static let settings: [NamedState] = settingsSheet + settingsPages + settingsAppIcon + settingsColor + websiteDarkening + questionsSearch + welcome

    private static let questionsSearch: [NamedState] = [
        NamedState("settings.search-guess-off", "Search without guessing", "Guess from Your Words off, Ask taken away: Return searches.") { app in
            SettingsStore.shared.guessesFromWords = false
            SettingsStore.shared.offersAsk = false
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.search)
        },
        NamedState("field.question-search", "A question searches", "Guess from Your Words off: a question leads with the search.") { app in
            SettingsStore.shared.guessesFromWords = false
            app.surfaces.openField(.address)
            app.field.typed(FieldSamples.ask)
        },
    ]

    private static let websiteDarkening: [NamedState] = [
        NamedState("settings.websites-on", "Darken Websites", "The existing Appearance switch, on.") { app in
            SettingsStore.shared.darkenWebsites = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.appearance)
        },
        NamedState("settings.websites-off", "Darken Websites off", "Light pages keep their original colors.") { app in
            SettingsStore.shared.darkenWebsites = false
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.appearance)
        },
        NamedState("websites.dark", "A light website darkened", "The Mac's engine changes the page while preserving its media.") { app in
            await openDarkeningPage(app, dark: true)
        },
        NamedState("websites.light", "The original light website", "Light appearance keeps the page's original colors.") { app in
            await openDarkeningPage(app, dark: false)
        },
        NamedState("websites.native", "The site's own dark theme", "A site's native dark colors take precedence.") { app in
            await openDarkeningPage(app, dark: true, native: true)
        },
    ]

    @MainActor private static func openDarkeningPage(_ app: AppModel, dark: Bool, native: Bool = false) async {
        SettingsStore.shared.appearance = dark ? .dark : .light
        SettingsStore.shared.darkenWebsites = true
        let tab = Tab(id: "website-darkening", title: "Morning notes", site: "Field Notes", icon: "globe",
                      url: "fieldnotes.example/morning", page: "website-darkening", host: "fieldnotes.example")
        app.browser.open(tab)
        let view = app.pages.activate(tab)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(10))
        if native { _ = try? await view.evaluateJavaScript("document.body.classList.add('native-dark'); true") }
        for _ in 0..<60 {
            let active = (try? await view.evaluateJavaScript("Boolean(document.getElementById('yab-website-darkening'))")) as? Bool
            if active == (dark && !native) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static let settingsSheet: [NamedState] = [
        NamedState("settings.backDrag", "Swipe back", "The Appearance page a third of the way off to the right, the root sliding out from under it.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.appearance)]
            try? await Task.sleep(for: .milliseconds(400))
            SettingsUI.shared.backDrag = 140
        },
        NamedState("settings.addSpace", "Add Space", "A new space is made in Settings: its page with an empty name.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.spaces)]
            try? await Task.sleep(for: .milliseconds(300))
            let id = app.browser.createSpace(name: "", emoji: "🌐", look: SpaceLook(color: RGB(168, 195, 160)))
            SettingsUI.shared.namingNew = id
            SettingsUI.shared.navigation.append(.space(id))
            SettingsUI.shared.navigation.append(.spaceName(id))
            try? await Task.sleep(for: .milliseconds(400))
        },
        NamedState("settings.overSpaces", "Over spaces", "The gear on the spaces screen: Settings on top, spaces under them.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.field.openSpacesInPlace()
            try? await Task.sleep(for: .milliseconds(300))
            app.openSettingsFromSpaces(at: nil)
        },
        NamedState("settings.backToSpaces", "Back to spaces", "Settings opened from spaces closed: the spaces screen again.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.field.openSpacesInPlace()
            try? await Task.sleep(for: .milliseconds(300))
            app.openSettingsFromSpaces(at: nil)
            try? await Task.sleep(for: .milliseconds(300))
            app.surfaces.closeSettings()
            try? await Task.sleep(for: .milliseconds(600))
        },
        NamedState("settings.clearData", "Clear history", "Privacy › Clear History and Website Data asks: a red button and Cancel.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.navigation = [.page(.privacy)]
            try? await Task.sleep(for: .milliseconds(500))
            SettingsUI.shared.confirmClearData = true
        },
        NamedState("settings.1", "Settings", "Mac, answers, tabs, privacy, appearance.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
        },

        NamedState("settings.3", "Further down", "Tabs and links, privacy and Face ID, notifications, appearance, about Yab.") { app in
            // The prototype moves the list up 330, past its end (the page
            // shows through under it); a finger scrolls it only as far as
            // About Yab at the bottom. Scrolled 330 as far as it goes, once
            // the list has its whole height, before the picture.
            let ui = SettingsUI.shared
            ui.assumeDefaultBrowser = true
            ui.scrolled = false
            ui.scrollTarget = 330
            app.surfaces.openSettings()
            for _ in 0..<150 where !ui.scrolled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        },

        NamedState("settings.xxxl", "Settings, XXXL", "Settings at the largest text size before the accessibility sizes.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            SettingsUI.shared.typeSize = .xxxLarge
            app.surfaces.openSettings()
        },

        NamedState("settings.join", "Sync", "Your Mac › Sync opens joining a Mac: sync's code for the Mac, over the Mac's page.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.mac)
            app.openJoin()
        },
    ]

    /// A space's Color, the Mac's Look editor, its page wearing the look.
    static let settingsColor: [NamedState] = [
        NamedState("settings.color", "Space color", "The Look editor as on the Mac: the field with a lens, presets, wave and grain; the page in the space's color.") { app in
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.spaces)
            SettingsUI.shared.open(.spaceColor(app.browser.space.id))
        },
    ]

    /// App Icon's page in each of its states (s-appicon): settings.page-appIcon
    /// is the icon in use ("In Use"); these browse to another one.
    static let settingsAppIcon: [NamedState] = [
        NamedState("settings.appIcon-use", "App Icon: another", "Watercolor Glass in the center, a Use This Icon button.") { app in
            appIcon(app, .watercolorGlass)
        },
        NamedState("settings.appIcon-changing", "App Icon: Changing…", "The button waits for iOS.") { app in
            await appIcon(app, .watercolorGlass, stage: { AppIconSelection.shared.stage(changing: true) })
        },
        NamedState("settings.appIcon-error", "App Icon: error", "iOS didn't change the icon: a line over the button.") { app in
            await appIcon(app, .watercolorGlass, stage: { AppIconSelection.shared.stage(error: AppIconSelection.failure) })
        },
        NamedState("settings.appIcon-flat-dark", "App Icon: Flat, Dark", "Flat's own dark picture, over a light screen.") { app in
            SettingsUI.shared.appIconPreviewDark = true
            appIcon(app, .flat)
        },
        NamedState("settings.appIcon-dark", "App Icon: Dark", "Dark icon previews, Opal in the center.") { app in
            SettingsUI.shared.appIconPreviewDark = true
            appIcon(app, .opal)
        },
        NamedState("settings.appIcon-pumpkin", "App Icon: Pumpkin", "The seasonal icon on iPhone.") { app in
            SettingsStore.shared.appIcons.adopt([PhoneAppIcon.pumpkin.grantKey: .bool(true)])
            appIcon(app, .pumpkin)
        },
        NamedState("settings.appIcon-gift", "App Icon: First Edition", "The feedback gift received from a Mac.") { app in
            SettingsStore.shared.appIcons.adopt([PhoneAppIcon.firstEdition.grantKey: .bool(true)])
            appIcon(app, .firstEdition)
        },
        NamedState("settings.appIcon-charm", "App Icon: Best Friends", "The same lilac and rose halves as on the Mac.") { app in
            SettingsStore.shared.appIcons.adopt([PhoneAppIcon.charm.grantKey: .bool(true),
                "invite.charm.left": .string("lilac"), "invite.charm.right": .string("rose")])
            appIcon(app, .charm)
        },
        NamedState("settings.appIcon-locked", "App Icon: locked", "Yearbook waits for the same reward as on the Mac.") { app in
            SettingsStore.shared.appIcons.adopt([:])
            appIcon(app, .yearbook)
        },
    ]

    @MainActor
    private static func appIcon(_ app: AppModel, _ icon: PhoneAppIcon) {
        SettingsUI.shared.assumeDefaultBrowser = true
        SettingsUI.shared.appIconPreview = icon
        app.surfaces.openSettings()
        SettingsUI.shared.openPage(.appIcon)
    }

    /// The page shown, then its button staged once the page has said hello
    /// to the selection (which clears what it shows on arrival).
    @MainActor
    private static func appIcon(_ app: AppModel, _ icon: PhoneAppIcon, stage: @MainActor () -> Void) async {
        appIcon(app, icon)
        try? await Task.sleep(for: .milliseconds(400))
        stage()
    }

    /// Each row's page: settings.page-mac, settings.page-appearance ...
    /// About and Privacy as a build with a site shows them (Reports).
    static let settingsPages: [NamedState] = SettingsPageID.allCases.map { page in
        NamedState("settings.page-\(page.rawValue)", SettingsContent.title(page), "The page the row opens.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            SettingsUI.shared.assumeReports = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(page)
        }
    }
}
