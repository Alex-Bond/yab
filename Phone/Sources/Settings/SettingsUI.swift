import SwiftUI
import UIKit

/// What Settings, its pages and the welcome show right now, beside what
/// Surfaces says is open: the sheets' movements, the page in front, and the
/// few things a named state sets up (a scrolled list, a text size).
@MainActor
@Observable
final class SettingsUI {
    static let shared = SettingsUI()

    /// The Settings sheet: a plain sheet from below, never
    /// grown out of what opened it.
    let sheet = GrowingSurface(plain: .init(up: .settingsOpen, down: .settingsClose))
    /// Joining a Mac: sync's join (Join/JoinContent) in this sheet.
    let join = GrowingSurface()

    /// The pages over the root, deepest last. The sheet owns this stack: a
    /// page changes the sheet's body in place (SettingsSheet), and the root
    /// with its query and scroll position stays alive underneath.
    var navigation: [SettingsRoute] = []
    /// The page Settings was opened at, standing as its root (× closes it,
    /// no ‹): History from "All History" (AppModel.showHistory).
    var openedAt: SettingsRoute?
    var search = ""
    /// The feedback draft survives Back and reopening during this session.
    var feedbackDraft = ""
    var searchSpot: String?
    var pageID: SettingsPageID? {
        navigation.last.flatMap { if case let .page(id) = $0 { return id }; return nil }
    }
    /// Settings no longer returns to the column's tray when it closes: it
    /// is a plain sheet. These stay for callers that still set them and are
    /// never called.
    @ObservationIgnored var returnToTray: (() -> Void)?
    @ObservationIgnored var returnPrepared = false
    /// Something an action inside Settings asked for once it has gone (Add
    /// Space names the new space in the column).
    @ObservationIgnored var afterClose: (() -> Void)?

    /// Named states: the list scrolled this far (as far as it goes) once
    /// it has its whole height; `scrolled` says it has.
    @ObservationIgnored var scrollTarget: CGFloat?
    @ObservationIgnored var scrolled = false
    /// How far the sheet's list can scroll, from its last layout.
    @ObservationIgnored var listRoom: CGFloat = 0
    /// Named states: the text size of these screens, whatever the system's.
    var typeSize: DynamicTypeSize?
    /// Named states: the welcome whatever the world says.
    var welcomeForced: Bool?
    /// Named states: no Mac yet, whatever the world says.
    var noMac = false
    /// Named states: the icon App Icon shows first, and its Light/Dark preview.
    var appIconPreview: PhoneAppIcon?
    var appIconPreviewDark: Bool?
    /// Named states: Yab is the default browser, as the prototype's world
    /// assumes (the simulator can't make it one).
    var assumeDefaultBrowser = false
    /// What is known of it when Settings last opened (SettingsContext.checkDefaultBrowser).
    var yabIsDefaultBrowser: Bool?
    /// Named states: About shows its switches for crash reports and daily
    /// activity as a build with a site does (test runs have none).
    var assumeReports = false

    /// Where each row is on screen (SettingsRow writes it as it moves), for
    /// the page or the join sheet that grows out of it. Not observed: it
    /// changes with every scroll and nothing redraws for it.
    @ObservationIgnored var rowFrames: [String: CGRect] = [:]
    /// How far the sheet's list was scrolled, for when it comes back from
    /// under a page that covered it. A new Settings starts at the top.
    @ObservationIgnored var rootOffset: CGFloat = 0
    /// Rows have gone under the head (the root's list, or the page's in
    /// front): the head's bar shows, as iOS's does.
    var rootUnder = false
    var pageUnder = false
    /// How far a finger has pulled the page in front to the right, going
    /// back as iOS's navigation does; 0 at rest.
    var backDrag: CGFloat = 0
    /// Privacy's Clear History and Website Data asks first.
    var confirmClearData = false
    /// Sync's Turn Off Sync on This iPhone asks first.
    var confirmSyncOff = false
    /// The Recovery Key, once Face ID said yes on its page (SyncRecovery);
    /// gone as Settings closes.
    var recoveryShown: String?
    /// A space Add Space has just made: its name field starts empty.
    @ObservationIgnored var namingNew: Space.ID?
    /// The corner radius of what joining grows out of next: a settings
    /// row's 16, or the welcome's capsule, half its height.
    @ObservationIgnored var joinOriginRadius: CGFloat = Metrics.Settings.originRadius
    /// The next close was the finger's: the sheet goes on down from there.
    @ObservationIgnored var flickNext = false
    /// The sheet's height at the last layout, for a flick's way down.
    @ObservationIgnored var sheetHeight: CGFloat = Metrics.screen.height - Metrics.Settings.top

    func openPage(_ id: SettingsPageID, from rowID: String? = nil) {
        searchSpot = rowID
        pageUnder = false
        open(.page(id))
    }

    /// The page comes in from the right as iOS pushes one, the body in front
    /// going a third of the way left under it (settingsPush).
    func open(_ route: SettingsRoute) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard navigation.last != route else { return }
        TaskMotion.run(.settingsPush) { navigation.append(route) }
    }

    /// The page in front is the one Settings was opened at: it has no page
    /// under it to go back to.
    var standsAsRoot: Bool { navigation.count == 1 && navigation.first == openedAt }

    /// A rect in screen points, in the sheet's own coordinates: the sheet
    /// stands Metrics.Settings.top under the screen's top.
    static func inSheet(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: 0, dy: -Metrics.Settings.top)
    }

    /// Back the same way (settingsBack); the same query and scroll position
    /// are below.
    func closePage() {
        guard !navigation.isEmpty, !standsAsRoot else { return }
        // Back from the Recovery Key: it is hidden again.
        if navigation.last == .page(.recoveryKey) { recoveryShown = nil }
        pageUnder = false
        TaskMotion.run(.settingsBack) { navigation.removeLast() }
    }

    /// A finger let go of the page it pulled: on past 40 % of the width or
    /// thrown right, it goes off and the page under it is in front; else it
    /// springs back.
    func letGoBack(width: CGFloat, velocity: CGFloat) {
        guard !navigation.isEmpty, !standsAsRoot else { backDrag = 0; return }
        let projected = backDrag + velocity * 0.16
        if projected > width * 0.4 || velocity > 600 {
            let route = navigation.last
            TaskMotion.run(.settingsBack, { backDrag = width }, completion: { [self] in
                var quiet = Transaction(animation: nil)
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    if route == .page(.recoveryKey) { recoveryShown = nil }
                    if navigation.last == route { navigation.removeLast() }
                    pageUnder = false
                    backDrag = 0
                }
            })
        } else {
            TaskMotion.run(.settingsBack) { backDrag = 0 }
        }
    }

    func settingsGone() {
        let returning = afterClose
        navigation = []
        openedAt = nil
        search = ""
        searchSpot = nil
        rootOffset = 0
        rowFrames = [:]
        afterClose = nil
        returnToTray = nil
        returnPrepared = false
        recoveryShown = nil
        confirmSyncOff = false
        returning?()
    }

}

/// One appearance for the browser, its sheets, the keyboard and UIKit.
/// System leaves the window's style to iOS; Light and Dark are explicit.
enum AppAppearance {
    static let drawsDark = true

    /// The scheme Yab's own screens take.
    @MainActor
    static func scheme(_ store: SettingsStore, systemIsDark: Bool) -> ColorScheme {
        store.colorScheme(systemIsDark: systemIsDark)
    }

    @MainActor
    static var current: ColorScheme {
        scheme(.shared, systemIsDark: SystemAppearance.shared.isDark)
    }

    /// The window's own style, for what UIKit draws.
    static func windowStyle(_ appearance: SettingsStore.Appearance) -> UIUserInterfaceStyle {
        UIUserInterfaceStyle(appearance)
    }
}

/// The system's own appearance (light or dark), read from the window's
/// scene and followed as it changes.
@MainActor
@Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var isDark = false
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var registration: UITraitChangeRegistration?

    func watch(_ scene: UIWindowScene?) {
        guard let scene, scene !== self.scene else { return }
        self.scene = scene
        update(scene)
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (scene: UIWindowScene, _: UITraitCollection) in
            self?.update(scene)
        }
    }

    private func update(_ scene: UIWindowScene) {
        MainStalls.count("systemStyle")
        let dark = scene.traitCollection.userInterfaceStyle == .dark
        if dark != isDark { isDark = dark }
    }
}

/// An invisible view that finds the window: it follows the system's
/// appearance through the window's scene and gives the window the app's
/// choice in Settings › Appearance, System leaving it to iOS.
struct AppearanceProbe: UIViewRepresentable {
    let appearance: SettingsStore.Appearance

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        MainStalls.count("appearanceProbe")
        view.style = AppAppearance.windowStyle(appearance)
        view.apply()
    }

    final class ProbeView: UIView {
        var style: UIUserInterfaceStyle = .unspecified

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            SystemAppearance.shared.watch(window.windowScene)
            if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
        }
    }
}

extension View {
    /// These screens' appearance, the app's (AppAppearance), and the text
    /// size a named state asks for. One layer carries the probe that finds
    /// the window.
    func settingsAppearance(probe: Bool = false) -> some View {
        modifier(SettingsAppearance(probe: probe))
    }
}

private struct SettingsAppearance: ViewModifier {
    let probe: Bool

    func body(content: Content) -> some View {
        let store = SettingsStore.shared
        let ui = SettingsUI.shared
        let scheme = AppAppearance.scheme(store, systemIsDark: SystemAppearance.shared.isDark)
        content
            .environment(\.colorScheme, scheme)
            .modifier(TypeSize(size: ui.typeSize))
            .background {
                if probe {
                    AppearanceProbe(appearance: store.appearance)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct TypeSize: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
