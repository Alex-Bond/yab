import AppKit
import SyncKit

/// Handoff for the page in front (ContinuePage): its icon on the Dock of
/// another Mac, its card on an iPhone's app switcher, and the page on this
/// Mac when it is picked up from the iPhone. Every browser window carries an
/// activity of its own, and AppKit makes the key window's the current one,
/// so what is offered follows the window you are in.
@MainActor
enum PageContinuity {
    /// What a window offers: the page in front, unless it is private, Mail's
    /// Yab's own work out of sight, or
    /// an address only this Mac can reach.
    static func page(in browser: Browser) -> ContinuePage.Page? {
        guard !Store.testing, !Headless.on, let tab = browser.active, !tab.shy, !browser.inMail,
              !Agents.shared.sealed(tab) else { return nil }
        return ContinuePage.page(url: tab.address, title: tab.title,
                                 space: browser.prefs.usesSpaces ? browser.spaceID.uuidString : nil)
    }

    /// Brings the window's activity up to date with its page. Called as the
    /// window retitles, which is whenever its tab, title or address change.
    static func advertise(_ browser: Browser, in window: NSWindow) {
        let page = page(in: browser)
        // The same page under a new title (a chat counting its unread) keeps
        // its activity: a new one for every tick of a title would be churn.
        if let current = window.userActivity, let page, current.webpageURL == page.url,
           current.userInfo?[ContinuePage.spaceKey] as? String == page.space {
            if current.title != page.title { current.title = page.title }
            return
        }
        if page == nil, window.userActivity == nil { return }
        window.userActivity?.invalidate()
        guard let page else {
            window.userActivity = nil
            return
        }
        let activity = NSUserActivity(activityType: ContinuePage.type)
        activity.title = page.title
        activity.webpageURL = page.url
        activity.userInfo = page.userInfo
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        window.userActivity = activity
        if window.isKeyWindow { activity.becomeCurrent() }
    }
}

extension Browser {
    /// A page picked up from another device: the tab that already shows it
    /// (sync may have brought it here first), else a tab of its own in front.
    func pickUp(_ url: URL) {
        if let same = tabs.first(where: { !$0.shy && $0.address.map { ContinuePage.same($0, url) } == true }) {
            select(same)
        } else {
            arrive(url)
        }
    }
}
