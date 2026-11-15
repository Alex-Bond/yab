import SwiftUI
import WebKit

extension Haptics.Reason {
    static let siteBlocking = "site blocking"
}

/// The blocker's say in the app: which pages get its lists (Settings' switch,
/// the site's own in Site Settings, the Mac's sites), and the per-site switch.
extension AppModel {
    /// Whether a page of this site gets the lists: never with the switch in
    /// Settings off; else what this iPhone was told for the site; else on,
    /// unless Yab on the Mac has it off for the site. A private page reads
    /// only what was said in private (SiteSettings keeps it apart).
    func blocksAds(on host: String?, isPrivate: Bool, settings: SettingsStore = .shared) -> Bool {
        guard settings.blocksAds else { return false }
        if let said = siteSettings.blocksAds(host, isPrivate: isPrivate) { return said }
        return !settings.macPausesAds(on: host)
    }

    /// Site Settings' Block Ads and Trackers, for the page in front.
    var pageBlocksAds: Bool {
        guard let tab = browser.tab else { return false }
        return blocksAds(on: siteHost(of: tab), isPrivate: pageIsPrivate)
    }

    /// Switched for the site in front: remembered for it, every open page
    /// of it follows from its next request, and this page loads again with
    /// the lists or without them, as on the Mac.
    func pageMenuBlocksAds(_ on: Bool) {
        guard let tab = browser.tab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.siteBlocking)
        siteSettings.setBlocksAds(on, for: siteHost(of: tab), isPrivate: pageIsPrivate)
        Shield.shared.apply()
        _ = pages.view(for: tab)
        pages.reload(tab.id)
    }

    /// The blocker told about this app: what each page gets, and the open
    /// pages following Settings' switch and the Mac's from then on.
    func attachShield(_ shield: Shield = .shared) {
        shield.wants = { [weak self] host, isPrivate in
            guard let self else { return SettingsStore.shared.blocksAds }
            return self.blocksAds(on: host, isPrivate: isPrivate)
        }
        pages.shield = shield
        watchShield(shield)
    }

    private func watchShield(_ shield: Shield) {
        withObservationTracking {
            _ = SettingsStore.shared.blocksAds
        } onChange: { [weak self, weak shield] in
            Task { @MainActor in
                guard let shield else { return }
                shield.apply()
                self?.watchShield(shield)
            }
        }
    }
}
