import Observation
import SwiftUI
import UIKit
import WebKit

/// Both entry points change the browser's existing flag, never a settings copy.
struct SpaceSignInsControls: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var change = SpaceSignInsChange()
    let spaceID: Space.ID
    let route: SpaceSignInsChange.Route

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Settings.headGap) {
            HStack(spacing: Metrics.Settings.headGap) {
                choice("Shared", own: false)
                choice("Its own", own: true)
            }
            Text(app.browser.space(spaceID)?.ownSignIns == true
                 ? "Its own: sign-ins stay in this space."
                 : "Shared: signed in wherever your other public spaces are.")
                .font(.footnote).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if change.unavailable {
                Text("Sign-ins could not change. Open this page again and try once more.")
                    .font(.footnote).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("space.signins.unavailable")
            }
        }
        .background { SpaceSignInsOwnerMarker(owner: change).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { change.cancel() } }
        .onChange(of: ObjectIdentifier(app)) { _, _ in change.cancel() }
        .onChange(of: spaceID) { _, _ in change.cancel() }
        .onDisappear { change.cancel() }
    }

    private func choice(_ words: String, own: Bool) -> some View {
        let selected = app.browser.space(spaceID)?.ownSignIns == own
        return Button { _ = change.request(own: own, in: app, spaceID: spaceID, route: route) } label: {
            HStack(spacing: Metrics.Settings.headGap) {
                Text(words).font(.body).fixedSize(horizontal: false, vertical: true)
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).accessibilityHidden(true) }
            }.frame(maxWidth: .infinity, minHeight: Metrics.touch)
                .padding(.horizontal, Metrics.Settings.rowPadding).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Ink.primary)
        .background(Ink.primary.opacity(selected ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius))
        .accessibilityIdentifier("space.signins." + (own ? "own" : "shared"))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The native alert captures one visible route and durable website namespace.
/// A mutation retires that request before a delayed native action can apply it.
@MainActor
@Observable
final class SpaceSignInsChange {
    /// Where the change was asked: Settings' page of the space.
    enum Route { case settings }
    enum Result: Equatable { case unchanged, changed, confirmation(UUID), unavailable }
    private(set) var unavailable = false
    @ObservationIgnored private weak var marker: UIView?
    @ObservationIgnored private weak var alert: UIAlertController?
    @ObservationIgnored private var pending: Request?

    private final class Retirement: @unchecked Sendable {
        private let lock = NSLock()
        private var retired = false
        func retire() { lock.lock(); retired = true; lock.unlock() }
        var isRetired: Bool { lock.lock(); defer { lock.unlock() }; return retired }
    }
    private struct Page: Equatable {
        let id: Tab.ID
        let url: String?
        let isPrivate: Bool
        init(_ tab: Tab) { id = tab.id; url = tab.url; isPrivate = tab.isPrivate }
    }
    @MainActor
    private final class Request {
        let id = UUID()
        let retirement = Retirement()
        weak var app: AppModel?
        weak var profile: BrowserProfile?
        weak var view: UIView?
        weak var window: UIWindow?
        weak var presenter: UIViewController?
        let spaceID: Space.ID
        let own: Bool
        let previous: Bool
        let profileID: UUID
        let previousStore: WKWebsiteDataStore
        let nextStoreID: UUID
        let selectedSpace: Space.ID
        let selectedTab: Tab.ID?
        let selectedURL: String?
        let targetCurrent: Tab.ID?
        let pages: [Page]
        let path: [SettingsRoute]

        init(app: AppModel, profile: BrowserProfile, view: UIView, window: UIWindow,
             presenter: UIViewController, space: Space, own: Bool, store: WKWebsiteDataStore,
             profileID: UUID, nextStoreID: UUID, route: Route) {
            self.app = app; self.profile = profile; self.view = view; self.window = window; self.presenter = presenter
            spaceID = space.id; self.own = own; previous = space.ownSignIns; previousStore = store
            self.profileID = profileID; self.nextStoreID = nextStoreID
            selectedSpace = app.browser.spaceID; selectedTab = app.browser.tab?.id; selectedURL = app.browser.tab?.url
            targetCurrent = space.current; pages = space.allTabs.map(Page.init)
            switch route {
            case .settings: path = SettingsUI.shared.navigation
            }
        }
    }

    func bind(_ view: UIView) {
        if marker !== view { cancel(); marker = view }
    }
    func detach(_ view: UIView) {
        guard marker === view else { return }
        cancel(); marker = nil
    }

    @discardableResult
    func request(own: Bool, in app: AppModel, spaceID: Space.ID, route: Route) -> Result {
        cancel(); unavailable = false
        guard !app.fixturesEnabled, !app.privateContentBlocked, !app.privateLock.presentsPrompt, let space = app.browser.space(spaceID), !space.isPrivate,
              !space.allTabs.contains(where: \.isPrivate), let profile = app.profile, let profileID = profile.dataStoreID,
              let view = marker, let window = view.window, let presenter = window.rootViewController,
              foreground(view, in: window), presenter.presentedViewController == nil else { return refuse() }
        if space.ownSignIns == own { return .unchanged }
        let store = app.pages.configurationForPage(in: space).websiteDataStore
        var next = space; next.ownSignIns = own
        guard store.isPersistent, store.identifier == profile.websiteStoreID(for: space),
              let nextID = profile.websiteStoreID(for: next) else { return refuse() }
        let request = Request(app: app, profile: profile, view: view, window: window, presenter: presenter,
                              space: space, own: own, store: store, profileID: profileID, nextStoreID: nextID, route: route)
        guard current(request, allowing: nil) else { return refuse() }
        // Cold and background tabs are not assumed safe. Any existing page
        // needs explicit confirmation of reload and possible unsaved form loss.
        if space.allTabs.isEmpty { return apply(request) ? .changed : refuse() }
        pending = request
        observe(request)
        let alert = UIAlertController(title: "Change Sign-ins?",
            message: "Pages in this space reload. Unsaved changes may be lost. Existing sign-ins are kept in their original store.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.cancel(request.id) })
        alert.addAction(UIAlertAction(title: "Change Sign-ins", style: .default) { [weak self] _ in _ = self?.confirm(request.id) })
        self.alert = alert
        presenter.present(alert, animated: true)
        return .confirmation(request.id)
    }

    @discardableResult
    func confirm(_ id: UUID) -> Bool {
        guard let request = pending, request.id == id, let alert, let presenter = request.presenter,
              presenter.presentedViewController == nil || presenter.presentedViewController === alert,
              current(request, allowing: presenter.presentedViewController == nil ? nil : alert) else {
            if pending?.id == id { cancel(); unavailable = true }
            return false
        }
        pending = nil; self.alert = nil
        // UIKit owns dismissal of its selected action. No async work separates
        // the final owner check from the existing flag mutation.
        let changed = apply(request, allowing: presenter.presentedViewController == nil ? nil : alert)
        if alert.presentingViewController != nil { alert.dismiss(animated: true) }
        return changed
    }

    func cancel() {
        pending?.retirement.retire(); pending = nil
        let own = alert; alert = nil
        if own?.presentingViewController != nil { own?.dismiss(animated: false) }
    }
    private func cancel(_ id: UUID) { if pending?.id == id { cancel() } }
    private func refuse() -> Result { unavailable = true; return .unavailable }

    private func foreground(_ view: UIView, in window: UIWindow) -> Bool {
        guard UIApplication.shared.applicationState == .active, window.isKeyWindow, !window.isHidden,
              window.windowScene?.activationState == .foregroundActive,
              view.window === window, let root = window.rootViewController, view.isDescendant(of: root.view) else { return false }
        var ancestor: UIView? = view
        while let item = ancestor { if item.isHidden || item.alpha <= 0.01 { return false }; ancestor = item.superview }
        return true
    }

    private func current(_ request: Request, allowing alert: UIAlertController?) -> Bool {
        guard !request.retirement.isRetired, let app = request.app, !app.fixturesEnabled,
              !app.privateContentBlocked, !app.privateLock.presentsPrompt,
              let profile = request.profile, app.profile === profile, profile.dataStoreID == request.profileID,
              let view = request.view, marker === view, let window = request.window, foreground(view, in: window),
              window.rootViewController === request.presenter, request.presenter?.presentedViewController === alert,
              let space = app.browser.space(request.spaceID), !space.isPrivate, space.ownSignIns == request.previous,
              space.current == request.targetCurrent, space.allTabs.map(Page.init) == request.pages,
              app.browser.spaceID == request.selectedSpace, app.browser.tab?.id == request.selectedTab,
              app.browser.tab?.url == request.selectedURL,
              app.pages.configurationForPage(in: space).websiteDataStore === request.previousStore,
              request.previousStore.identifier == profile.websiteStoreID(for: space) else { return false }
        var next = space; next.ownSignIns = request.own
        guard profile.websiteStoreID(for: next) == request.nextStoreID else { return false }
        let path = request.path
        return app.surfaces.settings && SettingsUI.shared.navigation == path && path.last == .space(request.spaceID)
    }

    private func apply(_ request: Request, allowing alert: UIAlertController? = nil) -> Bool {
        guard current(request, allowing: alert), let app = request.app else { return false }
        app.browser.setSpaceSignIns(request.spaceID, own: request.own)
        return app.browser.space(request.spaceID)?.ownSignIns == request.own
    }

    private func observe(_ request: Request) {
        let retirement = request.retirement, id = request.id
        withObservationTracking {
            _ = request.app?.browser.spaces; _ = request.app?.browser.spaceID
            _ = request.app?.surfaces.settings; _ = request.app?.surfaces.menu
            _ = request.app?.privateContentBlocked; _ = request.app?.privateLock.presentsPrompt
            _ = SettingsUI.shared.navigation
        } onChange: { [weak self] in
            // Observation calls this before the write. This synchronous latch
            // also rejects an owner that changed away and back in one turn.
            retirement.retire()
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }
}

/// The zero-sized noninteractive marker supplies the real owning window only.
private struct SpaceSignInsOwnerMarker: UIViewRepresentable {
    let owner: SpaceSignInsChange
    func makeUIView(context: Context) -> OwnerView { OwnerView(owner: owner) }
    func updateUIView(_ view: OwnerView, context: Context) {}
    static func dismantleUIView(_ view: OwnerView, coordinator: ()) { view.owner?.detach(view) }
    final class OwnerView: UIView {
        weak var owner: SpaceSignInsChange?
        init(owner: SpaceSignInsChange) { self.owner = owner; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { owner?.bind(self) } else { owner?.detach(self) }
        }
    }
}
