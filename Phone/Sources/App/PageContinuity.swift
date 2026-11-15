import Observation
import SyncKit
import UIKit

/// Handoff for the page in front (SyncKit's ContinuePage): its card in the
/// app switcher of an iPad, its icon on the Dock of a Mac signed in to the
/// same Apple ID. It follows what the screen shows: the tab in front, and
/// nothing at all for a private page, a page in
/// a world made for tests, or an address only this iPhone can reach.
@MainActor
final class PageContinuity {
    private weak var app: AppModel?
    private weak var scene: UIScene?
    private var offered: ContinuePage.Page?
    private var activity: NSUserActivity?

    init(app: AppModel, scene: UIScene) {
        self.app = app
        self.scene = scene
    }

    func start() { follow() }

    private func follow() {
        guard let app else { return }
        let page = withObservationTracking {
            Self.page(in: app)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        offer(page)
    }

    static func page(in app: AppModel) -> ContinuePage.Page? {
        guard !app.fixturesEnabled, !app.hasPrivateForeground else { return nil }
        guard let tab = app.browser.tab, !tab.isPrivate else { return nil }
        // A space only the Mac knows by name: its id is a UUID on both.
        let space = app.browser.space.id
        return ContinuePage.page(url: tab.navigationURL, title: tab.title,
                                 space: UUID(uuidString: space) == nil ? nil : space)
    }

    private func offer(_ page: ContinuePage.Page?) {
        guard page != offered else { return }
        // The same page under a new title keeps its activity.
        if let page, let was = offered, was.url == page.url, was.space == page.space, let activity {
            activity.title = page.title
            offered = page
            return
        }
        offered = page
        activity?.invalidate()
        activity = nil
        guard let page else {
            scene?.userActivity = nil
            return
        }
        let next = NSUserActivity(activityType: ContinuePage.type)
        next.title = page.title
        next.webpageURL = page.url
        next.userInfo = page.userInfo
        next.isEligibleForHandoff = true
        next.isEligibleForSearch = false
        next.isEligibleForPublicIndexing = false
        activity = next
        scene?.userActivity = next
    }
}

extension AppModel {
    /// A page picked up from a Mac (or another iPhone) by Handoff: a tab at
    /// the top of today's in the space it was in there when this iPhone has
    /// that one, else in the space in front; a page the space already has is
    /// brought up instead of opened twice (BrowserStore.open). Never into a
    /// private space: the page left a Mac that kept it.
    func pickUp(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == ContinuePage.type,
              let arrival = ContinuePage.arrival(webpageURL: userActivity.webpageURL, userInfo: userActivity.userInfo)
        else { return }
        pickUp(arrival)
    }

    func pickUp(_ arrival: ContinuePage.Arrival) {
        let spaces = browser.spaces.filter { !$0.isPrivate }
        let target = arrival.space.flatMap { id in spaces.first { ContinuePage.sameSpace($0.id, id) } }
            ?? spaces.first { $0.id == browser.ordinarySpaceID } ?? spaces.first
        guard let target else { return }
        if let same = target.allTabs.first(where: { !$0.isPrivate && $0.navigationURL.map { ContinuePage.same($0, arrival.url) } == true }) {
            browser.select(same.id)
            return
        }
        browser.open(PageFixtures.tab(for: arrival.url, in: world, fixturesEnabled: fixturesEnabled), in: target.id)
    }
}
