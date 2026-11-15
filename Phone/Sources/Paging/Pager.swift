import SwiftUI
import UIKit
import os

/// A swipe across the plate in progress: how far the pages have gone and
/// who is beside the tab. The page in front (PageLayer), its neighbors
/// (PagingLayer) and the plate's label (PagingLabels) all follow `offset`.
struct PageSwipe: Equatable {
    var offset: CGFloat
    var before: Tab?
    var after: Tab?
    /// Past the last tab: a blank page with New Tab instead of a neighbor.
    var newTab: Bool
    /// The blank page settled in front; the New Tab field is over it.
    var blank = false
}

/// Pages through the space's tabs with a swipe across the plate, in the
/// column's order: the page and the plate's label follow the finger (the
/// pages 416 apart, the label by its share of that), the neighbor slides in;
/// let go past 150 (thrown by 0.2 of the speed) and the neighbor settles in
/// front, else everything goes back. At the first tab the pages resist; past
/// the last a blank page slides in with "New Tab", and the New Tab field
/// opens over it; nothing chosen, the blank page slides back out, so no tab
/// is ever left empty.
@MainActor
final class Pager: PlatePaging {
    let app: AppModel
    /// The screen the pages fill: PagingLayer tells.
    var screen: CGSize = Metrics.screen

    private lazy var spring: SpringValue = {
        let spring = SpringValue(0) { [weak self] x in self?.apply(x) }
        // Under Reduce Motion the next page cross-fades in instead of sliding.
        spring.fadeView = {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
        }
        return spring
    }()
    /// Where the pages were when the finger came down (a swipe can catch them moving).
    private var origin: CGFloat = 0
    /// The tab in front when the swipe began.
    private var front: Tab.ID?
    private var space: Space.ID?
    /// Let go into New Tab: it opens the moment its page lands, not when the
    /// spring's tail has died away, so the keyboard comes with the landing.
    private var landingNewTab = false
    /// The way a let go would turn now (-1 back, 1 on, 0 stay), and whether
    /// the first tab's resistance was felt: ticks where the finger decides.
    private var decided = 0
    private var resisted = false

    private var sourceCurrent: Bool {
        app.browser.spaceID == space && app.browser.tab?.id == front && !app.privateContentBlocked
    }

    init(app: AppModel) { self.app = app }

    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "paging")

    private static var pagers: [ObjectIdentifier: Pager] = [:]

    static func of(_ app: AppModel) -> Pager {
        let key = ObjectIdentifier(app)
        if let pager = pagers[key] { return pager }
        let pager = Pager(app: app)
        pagers[key] = pager
        return pager
    }

    /// How far the page in front goes for the next to land: Safari's, the
    /// next starting `lead` out and moving `lag` times the finger.
    var slot: CGFloat { (screen.width + Metrics.Page.lead) / Metrics.Page.lag }

    /// Where the tab before (on the left) and the one after (on the right)
    /// stand while the page in front is `offset` along.
    func beside(_ offset: CGFloat) -> (before: CGFloat, after: CGFloat) {
        let w = screen.width, lead = Metrics.Page.lead, lag = Metrics.Page.lag
        return (min(0, lag * max(offset, 0) - lead) - w, max(0, w + lead + lag * min(offset, 0)))
    }

    // MARK: - PlatePaging

    // The plate's SwiftUI drag: used only when PlateGestures isn't on the window.
    func began() { if !PlateGestures.installed { start() } }
    func moved(_ dx: CGFloat) { if !PlateGestures.installed { follow(by: dx) } }
    func ended(_ dx: CGFloat, velocity: CGFloat) { if !PlateGestures.installed { finish(dx, velocity: velocity) } }

    // MARK: - following the finger

    func start() {
        if let swipe = app.surfaces.pageSwipe {
            guard !swipe.blank else { return }
            spring.stop()
            landingNewTab = false
            origin = spring.value
            return
        }
        let order = app.browser.pagingOrder
        guard let tab = app.browser.tab, let i = order.firstIndex(where: { $0.id == tab.id }) else { return }
        let before = i > 0 ? order[i - 1] : nil
        let after = i + 1 < order.count ? order[i + 1] : nil
        // The neighbors' pages alive behind this one, ready to slide in.
        if let before { app.pages.warm(before) }
        if let after { app.pages.warm(after) }
        front = tab.id
        space = app.browser.spaceID
        origin = 0
        decided = 0
        resisted = false
        Haptics.prepare()
        log.info("paging from \(tab.id, privacy: .public): before \(before?.id ?? "none", privacy: .public), after \(after?.id ?? "New Tab", privacy: .public)")
        app.surfaces.pageSwipe = PageSwipe(offset: 0, before: before, after: after, newTab: after == nil)
        spring.set(0)
    }

    func follow(by dx: CGFloat) {
        guard let swipe = app.surfaces.pageSwipe, !swipe.blank else { return }
        let x = edge(origin + dx, swipe)
        spring.set(x)
        feel(x, raw: origin + dx, swipe)
    }

    /// Under the finger: a tick as it passes the point a let go would turn
    /// the tab (a tap into New Tab), a wall as the first tab resists.
    private func feel(_ x: CGFloat, raw: CGFloat, _ swipe: PageSwipe) {
        let now = turn(x, swipe)
        if now != 0, now != decided {
            if now > 0, swipe.newTab { Haptics.play(.light, reason: Haptics.Reason.newTabPage) }
            else { Haptics.play(.selection, reason: Haptics.Reason.tabCross) }
        }
        decided = now
        if swipe.before == nil, raw > Metrics.Page.resistFelt, !resisted {
            resisted = true
            Haptics.play(.soft, reason: Haptics.Reason.pagerEdge)
        }
    }

    /// The way a let go at `x` would turn: on (1), back (-1) or not (0).
    private func turn(_ x: CGFloat, _ swipe: PageSwipe) -> Int {
        if x <= -Metrics.Page.commit, swipe.after != nil || swipe.newTab { return 1 }
        if x >= Metrics.Page.commit, swipe.before != nil { return -1 }
        return 0
    }

    func finish(_ dx: CGFloat, velocity: CGFloat) {
        guard sourceCurrent else { cancel(animated: false); return }
        guard let swipe = app.surfaces.pageSwipe, !swipe.blank else { return }
        let x = edge(origin + dx, swipe)
        let projected = x + velocity * Metrics.Page.projection
        log.info("paging let go at \(Double(x), format: .fixed(precision: 1)) moving \(Double(velocity), format: .fixed(precision: 0)) pt/s")
        // Thrown short of the point: the tick comes as it is let go.
        let thrown = turn(projected, swipe)
        if thrown != 0, thrown != decided {
            if thrown > 0, swipe.newTab { Haptics.play(.light, reason: Haptics.Reason.newTabPage) }
            else { Haptics.play(.selection, reason: Haptics.Reason.tabCross) }
        }
        if swipe.newTab && projected <= -Metrics.Page.commit {
            landingNewTab = true
            spring.animate(to: -slot, .tabSwipe, velocity: velocity) { [weak self] finished in
                guard let self, finished, self.landingNewTab else { return }
                self.landingNewTab = false
                self.toBlank()
            }
            return
        }
        var step = 0
        if projected < -Metrics.Page.commit && swipe.after != nil { step = 1 }
        if projected > Metrics.Page.commit && swipe.before != nil { step = -1 }
        spring.animate(to: -CGFloat(step) * slot, .tabSwipe, velocity: velocity) { [weak self] finished in
            if finished { self?.settle(step) }
        }
    }

    /// UIKit cancellation never commits a tab or opens New Tab, even when
    /// the last translation had already crossed the normal commit distance.
    func cancel(animated: Bool = true) {
        guard let swipe = app.surfaces.pageSwipe, !swipe.blank else { return }
        spring.stop()
        if !animated {
            spring.set(0)
            app.surfaces.pageSwipe = nil
            return
        }
        spring.animate(to: 0, .tabSwipeBack) { [weak self] finished in
            if finished { self?.settle(0) }
        }
    }

    /// Resistance at the ends: before the first tab, and past New Tab's page.
    private func edge(_ x: CGFloat, _ swipe: PageSwipe) -> CGFloat {
        if x > 0 && swipe.before == nil { return ColumnMath.rubber(x, Metrics.Page.rubber) }
        if x < 0 && swipe.after == nil {
            return x < -slot ? -slot - ColumnMath.rubber(-slot - x, Metrics.Page.rubberPastNewTab) : x
        }
        return x
    }

    private func apply(_ x: CGFloat) {
        guard app.surfaces.pageSwipe != nil, app.surfaces.pageSwipe?.offset != x else { return }
        app.surfaces.pageSwipe?.offset = x
        // 3 short of its place the page has landed to the eye (New Tab stands
        // under 4 pt from it); the spring's tail after that is slow.
        if landingNewTab, x <= -slot + 3 {
            landingNewTab = false
            toBlank()
        }
    }

    /// The neighbor in front (or the same tab back in place); the swipe is over.
    private func settle(_ step: Int) {
        guard let swipe = app.surfaces.pageSwipe else { return }
        guard sourceCurrent else { app.surfaces.pageSwipe = nil; return }
        let next = step > 0 ? swipe.after : step < 0 ? swipe.before : nil
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            if let next { app.browser.select(next.id) }
            app.surfaces.pageSwipe = nil
        }
    }

    // MARK: - New Tab past the last tab

    private func toBlank() {
        guard sourceCurrent else { app.surfaces.pageSwipe = nil; return }
        app.surfaces.pageSwipe?.blank = true
        if PagingLayer.slidesSpaces(app) {
            // The spaces that slid in are New Tab itself: it stands where they
            // are, the pill already in the field's place, then the keyboard comes.
            var quiet = Transaction(animation: nil)
            quiet.disablesAnimations = true
            withTransaction(quiet) { app.field.openSpacesInPlace() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.app.surfaces.field == .newTab else { return }
                self.app.field.ask()
            }
        } else {
            let plate = ChromeGeometry(size: screen, folded: false, hasNow: app.nowItem != nil).plate
            Motion.fieldOpen.run { app.surfaces.openField(.newTab, from: plate) }
        }
        watchBlank()
    }

    /// The field closes: a new tab came in front, or nothing was chosen and
    /// the blank page slides back out.
    private func watchBlank() {
        withObservationTracking {
            _ = app.surfaces.field
            _ = app.browser.tab?.id
        } onChange: { [weak self] in
            Task { @MainActor in self?.checkBlank() }
        }
    }

    private func checkBlank() {
        guard let swipe = app.surfaces.pageSwipe, swipe.blank else { return }
        if app.browser.tab?.id != front {
            app.surfaces.pageSwipe = nil
            return
        }
        guard app.surfaces.field == nil else { return watchBlank() }
        leaveBlank()
    }

    func leaveBlank() {
        guard app.surfaces.pageSwipe?.blank == true else { return }
        app.surfaces.pageSwipe?.blank = false
        spring.animate(to: 0, .tabSwipeBack) { [weak self] finished in
            guard finished, let self else { return }
            self.app.surfaces.pageSwipe = nil
        }
    }

    /// A tap on the blank page while nothing stands over it: the field lets go.
    func tapBlank() {
        if app.surfaces.field != nil {
            Motion.fieldClose.run { app.surfaces.closeField() }
        } else {
            leaveBlank()
        }
    }

    // MARK: - without a swipe

    /// VoiceOver's Next Tab and Previous Tab on the plate: the same page
    /// turn a swipe past the commit makes (past the last tab, New Tab).
    func step(_ direction: Int) {
        guard direction != 0, app.surfaces.pageSwipe == nil else { return }
        start()
        guard app.surfaces.pageSwipe != nil else { return }
        finish(direction > 0 ? -slot : slot, velocity: 0)
    }

    // MARK: - named states

    /// The pages stopped `dx` into a swipe, as if a finger held them there.
    func hold(at dx: CGFloat) {
        start()
        follow(by: dx)
    }
}
