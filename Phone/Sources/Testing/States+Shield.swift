import Foundation

/// The ad blocker (Page/Shield): a news page with what the built-in list
/// stops (Pages/shield.html, whose strip says what loaded), blocked, off for
/// its site and in a private tab; the switch in Site Settings and in
/// Settings › Privacy. Each waits for the lists before the page opens, so the
/// page is blocked from its first request, as it is once Yab has run once.
extension StateCatalog {
    static let shield: [NamedState] = [
        NamedState("shield.1", "Ads blocked", "The ad script and tracker didn't load, the ad slots are hidden.") { app in
            await openShieldPage(app)
        },
        NamedState("shield.2", "Off for the site", "The same site with blocking off: the ads are there.") { app in
            app.siteSettings.setBlocksAds(false, for: shieldHost, isPrivate: false)
            await openShieldPage(app)
        },
        NamedState("shield.3", "Private tab", "A private tab blocks the same way.") { app in
            await openShieldPage(app, isPrivate: true)
        },
        NamedState("shield.site", "Site Settings: blocking", "Block Ads and Trackers on for the site.") { app in
            await openShieldPage(app)
            try? await Task.sleep(for: .milliseconds(300))
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("shield.site-off", "Site Settings: off", "Block Ads and Trackers off for this site.") { app in
            app.siteSettings.setBlocksAds(false, for: shieldHost, isPrivate: false)
            await openShieldPage(app)
            try? await Task.sleep(for: .milliseconds(300))
            openPageMenu(app)
            app.pageMenu.page = .site
        },
        NamedState("shield.settings", "Privacy: blocking", "Settings › Privacy: Block ads and trackers on.") { app in
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.privacy)
        },
        NamedState("shield.settings-off", "Privacy: off", "Settings › Privacy: blocking off everywhere.") { app in
            SettingsStore.shared.blocksAds = false
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.privacy)
        },
    ]

    /// Where the news page says it is.
    static let shieldHost = "dailyledger.example"

    /// The news page in front, once the blocker's lists are in.
    @MainActor
    static func openShieldPage(_ app: AppModel, isPrivate: Bool = false) async {
        await Shield.shared.settled()
        let tab = Tab(id: isPrivate ? "private-shield" : "shield-ledger", title: "Harbor fees rise as the ferries return",
                      site: "The Daily Ledger", icon: "dailyledger", url: shieldHost + "/world/harbor-fees", page: "shield",
                      host: shieldHost, isPrivate: isPrivate)
        if isPrivate { app.openPrivately(tab) } else { app.browser.open(tab) }
    }
}
