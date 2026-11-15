import Foundation

/// Translate page's states: a page in Portuguese (Pages/lisboa-alfama.html,
/// "Alfama, de manhã cedo") opened over the atlas's start, the page menu
/// offering Translate, the page part way and all the way in English, the
/// menu of a translated page, the site always translated, and a private tab.
/// The stand-in translator speaks the fixture's own English.
extension StateCatalog {
    static let translatePage = URL(string: "https://lisboa-a-pe.pt/alfama-de-manha")!

    static let translate: [NamedState] = [
        NamedState("translate.1", "Translate", "A page in Portuguese: “Translate to English” in the menu, “This page is in Portuguese” under it.") { app in
            guard await openPortuguese(app) != nil else { return }
            openPageMenu(app)
        },
        NamedState("translate.2", "Translating", "What's visible is already in English, Portuguese still further down; “Translating…” under the address.") { app in
            guard let tab = await openPortuguese(app) else { return }
            app.translation.holdStandIn(after: 1)
            app.translation.translate(tab.id)
            await waitForTranslation(app, tab.id) { if case let .translating(done, _) = $0 { done >= 1 } else { false } }
        },
        NamedState("translate.3", "Translated", "The whole page in English, “Translated” under the address.") { app in
            guard let tab = await openPortuguese(app) else { return }
            app.translation.translate(tab.id)
            await waitForTranslation(app, tab.id) { $0 == .translated }
        },
        NamedState("translate.4", "Translated page menu", "“Show Original”, “Translated from Portuguese”, “Always Translate Portuguese”.") { app in
            guard let tab = await openPortuguese(app) else { return }
            app.translation.translate(tab.id)
            await waitForTranslation(app, tab.id) { $0 == .translated }
            openPageMenu(app)
        },
        NamedState("translate.always", "Always translate", "The site remembered: the page translated by itself, a checkmark on “Always Translate Portuguese” in the menu.") { app in
            app.siteSettings.setAlwaysTranslates("pt", for: "lisboa-a-pe.pt", isPrivate: false)
            guard let tab = await openPortuguese(app) else { return }
            await waitForTranslation(app, tab.id) { $0 == .translated }
            openPageMenu(app)
        },
        NamedState("translate.private", "Translation in Private", "A private tab's dark menu offers translation too, on this iPhone.") { app in
            guard await openPortuguese(app, privately: true) != nil else { return }
            openPageMenu(app)
        },
    ]

    /// The Portuguese page in a new tab in front, drawn and looked at.
    @MainActor
    @discardableResult
    static func openPortuguese(_ app: AppModel, privately: Bool = false) async -> Tab? {
        let page = PageFixtures.tab(for: translatePage, in: app.world, fixturesEnabled: app.fixturesEnabled)
        if privately { app.openPrivately(page) } else { app.browser.open(page) }
        // The chrome closes a menu as the tab changes: everything after it.
        try? await Task.sleep(for: .milliseconds(300))
        guard let tab = app.browser.tab else { return nil }
        app.pages.activate(tab)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
        for _ in 0..<120 where app.translation.page(tab.id) == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return tab
    }

    @MainActor
    static func waitForTranslation(_ app: AppModel, _ id: Tab.ID, until: (PageTranslation.Phase) -> Bool) async {
        for _ in 0..<120 {
            if let phase = app.translation.page(id)?.phase, until(phase) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
