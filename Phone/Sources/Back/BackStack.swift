import SwiftUI
import UIKit

/// Where ‹ and a pull from the left edge lead. While the page has a Back it
/// is the page's own (WebKit's swipe with its pictures, or ‹ through the
/// timeline); at the first page of a tab a link opened, the tab it came
/// from, this one closing; else nowhere: ‹ dims and the page only gives.
enum BackRoute: Equatable, Sendable {
    case history
    case opener(Tab.ID)
    case nowhere

    static func decide(canGoBack: Bool, opener: Tab.ID?) -> BackRoute {
        if canGoBack { return .history }
        return opener.map(BackRoute.opener) ?? .nowhere
    }
}

/// The page pulled from the left edge where WebKit's swipe can't start, or
/// ‹ playing the same: how far it has gone, in points.
struct BackSwipe: Equatable {
    enum Kind: Equatable {
        /// The tab that opened this one under the page, as a card.
        case opener(Tab.ID)
        /// Nothing behind: the page gives like a list's end and springs back.
        case nothing
    }
    var id = UUID()
    var kind: Kind
    /// The tab pulled, the one in front when the finger came down.
    var tab: Tab.ID
    var offset: CGFloat
}

/// A tab just closed: everything Undo needs to bring it back as it was.
struct ClosedTab {
    let id = UUID()
    let at = Date()
    let tab: Tab
    let space: Space.ID
    let spot: BrowserStore.Spot
    let wasFront: Bool
    /// Its pages and the place in them, WebKit's session when it had one.
    let memory: WebPool.ClearMemory?

    /// The toast's words name its site: "Closed nhc.noaa.gov".
    var host: String { BackStack.host(of: tab) }
}

/// Going back, wherever it starts: which page opened which tab, the pull
/// from the left edge (BackGestures) and what it reveals (BackRevealLayer),
/// ‹ at a first page, and the last closed tab, which the toast's Undo brings
/// back with its pages (a close from the column too).
@MainActor
@Observable
final class BackStack {
    /// Tabs a page opened (target=_blank, window.open), each to its opener.
    private(set) var openers: [Tab.ID: Tab.ID] = [:]
    /// The page pulled from the left edge, or going back to its opener.
    private(set) var swipe: BackSwipe?
    /// The last tab closed, while the toast offers it back.
    @ObservationIgnored private(set) var closed: ClosedTab?
    /// The screen the page fills: BackRevealLayer tells.
    @ObservationIgnored var width: CGFloat = Metrics.screen.width
    @ObservationIgnored private(set) weak var app: AppModel?
    /// Let go past the commit, or ‹: the opener comes in front as the page lands.
    @ObservationIgnored private var landing = false
    /// The pull is past the point a let go goes back; a tick was felt there
    /// in this pull; a page with nothing behind was felt resisting.
    @ObservationIgnored private var past = false
    @ObservationIgnored private var crossed = false
    @ObservationIgnored private var resisted = false
    @ObservationIgnored private lazy var spring: SpringValue = {
        let spring = SpringValue(0) { [weak self] x in self?.apply(x) }
        // Under Reduce Motion the opener cross-fades in instead.
        spring.fadeView = {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow }
        }
        return spring
    }()
    @ObservationIgnored lazy var gestures = BackGestures(stack: self)

    init(app: AppModel) { self.app = app }

    /// A tab's site as going back says it: "nhc.noaa.gov", no www.
    nonisolated static func host(of tab: Tab) -> String {
        let host = tab.addressHost.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - who opened whom

    /// A page opened `id`: Back at its first page returns to `source`.
    func opened(_ id: Tab.ID, by source: Tab.ID) {
        guard let app, id != source else { return }
        // Pairs whose tab is gone for good (no Undo still holds it) go.
        let tabs = Set(app.browser.allTabs.map(\.id))
        openers = openers.filter { tabs.contains($0.key) || $0.key == closed?.tab.id }
        openers[id] = source
    }

    /// The tab that opened `id`, while it is still there: in the same space,
    /// as private or as public as this one.
    func opener(of id: Tab.ID) -> Tab.ID? {
        guard let app, let source = openers[id], source != id, let space = app.browser.space(holding: id),
              let tab = space.tab(id), let opener = space.tab(source), opener.isPrivate == tab.isPrivate else { return nil }
        return opener.id
    }

    /// Where Back leads from the tab in front.
    func route(for tab: Tab?) -> BackRoute {
        guard let app, let tab, tab.id == app.browser.tab?.id else { return .nowhere }
        // Read first: a view asking is told again when the pool first speaks
        // for this page, before which it doesn't count as shown.
        _ = app.chrome.pageStates[tab.id]
        let state = app.currentPageState
        if state.canGoBack || state.readerEnabled { return .history }
        // A page the pool doesn't show yet may still have a way back: a tab
        // is never closed on a guess.
        guard app.pageStateOverride != nil || app.pages.represents(tab) else { return .nowhere }
        return .decide(canGoBack: false, opener: opener(of: tab.id))
    }

    // MARK: - the pull from the left edge

    /// Nothing else holds the screen and the page has no Back of its own:
    /// the left edge is this pull's (WebKit's swipe has it otherwise).
    var mayPull: Bool {
        guard pageIsFree, let tab = app?.browser.tab else { return false }
        return route(for: tab) != .history
    }

    /// Nothing else holds the screen: the page in front is the finger's.
    private var pageIsFree: Bool {
        guard let app, swipe == nil, app.browser.tab != nil, app.privateLock.isActive,
              !app.privateContentBlocked, !FirstLaunch.shows(app) else { return false }
        let s = app.surfaces
        return !s.coversChrome && s.chat == nil && s.menu == nil && !s.settings && !s.join
            && !s.pageSwiping && s.recede == 0
    }

    func pullBegan() {
        guard let app, mayPull, let tab = app.browser.tab else { return }
        let kind: BackSwipe.Kind
        switch route(for: tab) {
        case .history: return
        case let .opener(id): kind = .opener(id); warm(id)
        case .nowhere: kind = .nothing
        }
        landing = false
        past = false
        crossed = false
        resisted = false
        Haptics.prepare()
        swipe = BackSwipe(kind: kind, tab: tab.id, offset: 0)
        spring.set(0)
    }

    /// The finger `dx` from where it came down: the page follows it to the
    /// opener, against the rubber band with nothing behind.
    func pulled(by dx: CGFloat) {
        guard let swipe, !landing else { return }
        guard current(swipe) else { return cancelPull(animated: false) }
        let x = max(0, dx)
        spring.set(swipe.kind == .nothing ? ColumnMath.rubber(x, width) : min(x, width))
        feel(x, swipe)
    }

    /// Under the finger: a tick as the pull passes the point a let go goes
    /// back, a wall as a page with nothing behind resists.
    private func feel(_ x: CGFloat, _ swipe: BackSwipe) {
        if case .opener = swipe.kind {
            let now = min(x, width) / max(1, width) > Metrics.Back.commit
            if now, !past {
                crossed = true
                Haptics.play(.selection, reason: Haptics.Reason.backCross)
            }
            past = now
        } else if x > Metrics.Page.resistFelt, !resisted {
            resisted = true
            Haptics.play(.soft, reason: Haptics.Reason.backNothing)
        }
    }

    /// Let go: past half the screen or thrown, on to the opener; else back.
    func pullEnded(velocity: CGFloat) {
        guard let swipe, !landing else { return }
        guard current(swipe) else { return cancelPull(animated: false) }
        if case .opener = swipe.kind,
           spring.value / max(1, width) > Metrics.Back.commit || velocity > Metrics.Back.fling {
            // Thrown short of half: the tick comes as it is let go.
            if !past {
                crossed = true
                Haptics.play(.selection, reason: Haptics.Reason.backCross)
            }
            go(velocity: velocity)
        } else {
            // The rubber band's page moves slower than the finger: no throw back.
            cancelPull(velocity: swipe.kind == .nothing ? 0 : velocity)
        }
    }

    /// Back in place: UIKit took the touch, the tab changed, or let go short.
    func cancelPull(animated: Bool = true, velocity: CGFloat = 0) {
        guard let swipe, !landing else { return }
        guard animated else {
            spring.set(0)
            quietly { self.swipe = nil }
            return
        }
        let id = swipe.id
        spring.animate(to: 0, .backPull, velocity: velocity) { [weak self] finished in
            guard finished, let self, self.swipe?.id == id else { return }
            self.quietly { self.swipe = nil }
        }
    }

    /// ‹ at a first page, and VoiceOver's Back To: the same as a pull let go
    /// past half, the page leaving and the opener's card growing.
    func backToOpener() {
        guard let app, swipe == nil, let tab = app.browser.tab, case let .opener(opener) = route(for: tab) else { return }
        warm(opener)
        crossed = false
        swipe = BackSwipe(kind: .opener(opener), tab: tab.id, offset: 0)
        spring.set(0)
        go(velocity: 0)
    }

    /// Named states: the page held `dx` into a pull, as a finger would.
    func hold(at dx: CGFloat) {
        pullBegan()
        pulled(by: dx)
    }

    private func go(velocity: CGFloat) {
        landing = true
        spring.animate(to: width, .backPull, velocity: velocity) { [weak self] finished in
            if finished { self?.land() }
        }
    }

    private func apply(_ x: CGFloat) {
        guard swipe != nil, swipe?.offset != x else { return }
        swipe?.offset = x
        if landing, x >= width - Metrics.Back.landed { land() }
    }

    /// The page has left: it closes, the opener is in front, and the toast
    /// offers it back.
    private func land() {
        guard landing, let app, let swipe, case let .opener(opener) = swipe.kind else { return }
        landing = false
        guard current(swipe), app.browser.tab(opener) != nil, let closing = remember(swipe.tab) else {
            spring.set(0)
            quietly { self.swipe = nil }
            return
        }
        // A pull was felt where it was decided; ‹ is felt as the tab closes.
        if !crossed { Haptics.play(.soft, reason: Haptics.Reason.backToOpener) }
        quietly {
            app.browser.close(swipe.tab)
            app.browser.select(opener)
            self.swipe = nil
        }
        app.pages.forget(swipe.tab)
        offer(closing)
    }

    private func current(_ swipe: BackSwipe) -> Bool {
        guard let app else { return false }
        return app.browser.tab?.id == swipe.tab && !app.privateContentBlocked
    }

    /// The opener's page ready under the card: its picture, else its page
    /// alive behind this one.
    private func warm(_ id: Tab.ID) {
        guard let app, let tab = app.browser.tab(id), app.pages.snapshots[id] == nil else { return }
        app.pages.warm(tab)
    }

    private func quietly(_ body: () -> Void) {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet, body)
    }

    // MARK: - closing with Undo

    /// What Undo will need, taken just before a tab closes.
    func remember(_ id: Tab.ID) -> ClosedTab? {
        guard let app, let owner = app.browser.space(holding: id), let tab = owner.tab(id),
              let spot = BrowserStore.spot(of: id, in: owner) else { return nil }
        return ClosedTab(tab: tab, space: owner.id, spot: spot, wasFront: owner.current == id,
                         memory: app.pages.closedMemory(for: tab))
    }

    /// The tab has closed: it is kept for Undo, quietly. No plate says
    /// "Closed site · Undo"; the column or stack shows the close itself.
    func offer(_ closed: ClosedTab) {
        self.closed = closed
    }

    /// Undo: the tab back where it stood with its pages and its place in
    /// them, in front again if it was.
    @discardableResult
    func undo(_ id: UUID) -> Bool {
        guard let app, let saved = closed, saved.id == id, let space = app.browser.space(saved.space),
              !space.isPrivate || app.privateLock.mayReveal else { return false }
        closed = nil
        var restored = false
        Motion.columnRows.run { restored = app.browser.reinsert(saved.tab, in: saved.space, at: saved.spot) }
        guard restored else { return false }
        // The record before its pages: the profile keeps a timeline only for a tab it has.
        app.profile?.capture(app.browser)
        if let memory = saved.memory { app.pages.restoreClearMemory(memory, for: saved.tab.id) }
        if saved.wasFront { app.browser.select(saved.tab.id) }
        return true
    }
}

/// A sideways swipe anywhere on the page (SwipeAnywhere): WebKit's own swipe
/// while the page has a Back or a Forward, the pull to the opener at a first page.
extension BackStack: SwipeAnywhereHost {
    var maySwipeAnywhere: Bool { SettingsStore.shared.swipeAnywhere && pageIsFree }

    var maySwipeToOpener: Bool {
        guard maySwipeAnywhere, mayPull, case .opener = route(for: app?.browser.tab) else { return false }
        return true
    }
}
