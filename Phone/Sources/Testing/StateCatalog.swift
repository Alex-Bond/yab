import Foundation
import QuartzCore
import UIKit
import os

/// A named state of the app, one frame of the prototype's atlas: launched
/// with -YabState <name> it is set up from the world's start, then pictured.
/// Names are the atlas's positions, `<group>.<n>` (page.1 "Plain view",
/// field.1…, Phone/Reference/digest/states.md).
struct NamedState: Sendable {
    let name: String
    /// The frame's title in the prototype.
    let title: String
    /// What it shows, in the prototype's words.
    let note: String
    let apply: @MainActor @Sendable (AppModel) async -> Void

    init(_ name: String, _ title: String, _ note: String = "", apply: @escaping @MainActor @Sendable (AppModel) async -> Void) {
        self.name = name
        self.title = title
        self.note = note
        self.apply = apply
    }
}

/// Every named state, from each feature's own file (States+<Feature>.swift):
/// a branch registers its states there, never here.
enum StateCatalog {
    static var all: [NamedState] {
        page + field + chats + settings + sync + tasks + reports + design + history + back + shield + tabs + translate + voice
            + entrances + workspace + approvals + fieldAnswers + launch + tabEdits + siteIcons
    }

    static func named(_ name: String) -> NamedState? { all.first { $0.name == name } }
}

/// Sets a named state up and says when it has settled: a file named after the
/// state in Library/Caches/yab-ready, which Phone/scripts/phone waits for
/// before it takes the picture. Its lines say what was on screen.
@MainActor
enum StateRunner {
    private static let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "state")

    static func run(_ name: String, in app: AppModel, options: LaunchOptions) async {
        if StateProbe.handles(name, in: app) { return }
        StateProbe.began()
        app.surfaces.toastsStay = true
        // The atlas's start: no task running, the world's own space and tab.
        app.tasks.removeAll()
        var notes: [String] = []
        if let state = StateCatalog.named(name) {
            await state.apply(app)
            notes.append("title=\(state.title)")
        } else {
            log.error("no state named \(name, privacy: .public); the world's start instead")
            notes.append("unknown state: the world's start")
        }
        let settled = await settle(app)
        let tab = app.browser.tab
        notes += [
            "settled=\(settled ? "yes" : "no")",
            "state=\(name)", "world=\(options.world)",
            "space=\(app.browser.space.id)", "tab=\(tab?.id ?? "none")", "page=\(tab?.pageURL.absoluteString ?? "none")",
            "folded=\(app.chrome.folded)", "now=\(app.nowItem.map { "\($0.title): \($0.subtitle)" } ?? "none")",
            "dark=\(app.pageIsDark)",
            "web: \(tab.map { app.pages.describe($0.id) } ?? "none")",
        ]
        notes += windowNotes(app)
        ready(name, notes)
    }

    /// Waits for the page in front to load and draw, and the chrome to land.
    /// False when the page never drew in time (a cold web process on a busy
    /// Mac): the picture is taken anyway, and the script takes it again.
    @discardableResult
    static func settle(_ app: AppModel) async -> Bool {
        var painted = true
        if let tab = app.browser.tab {
            app.pages.activate(tab)
            await app.pages.waitUntilPainted(tab.id, timeout: .seconds(12))
            painted = app.pages.painted.contains(tab.id)
        }
        // Glass and the last layout pass, then one more frame on screen.
        try? await Task.sleep(for: .milliseconds(450))
        CATransaction.flush()
        try? await Task.sleep(for: .milliseconds(100))
        return painted
    }

    /// What the screen reports: window and screen sizes, safe areas, size
    /// classes, and the layout Yab took. For devices whose geometry is the question.
    static func windowNotes(_ app: AppModel) -> [String] {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else { return ["window: none"] }
        func rect(_ r: CGRect) -> String { "\(r.minX),\(r.minY) \(r.width)x\(r.height)" }
        func insets(_ i: UIEdgeInsets) -> String { "t\(i.top) l\(i.left) b\(i.bottom) r\(i.right)" }
        let sides = ChromeGeometry.effectiveSides
        var deviceNotes: [String] = []
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            deviceNotes += [
                "window.occlusions: \(window.reservedRegions(kind: .occlusion).filter(\.isActive).map { rect($0.frame) })",
                "window.divisions: \(window.reservedRegions(kind: .division).filter(\.isActive).map { rect($0.frame) })",
                "window.verticalBarEdge: \(window.traitCollection.verticalBarEdge)",
            ]
        }
        #endif
        let reservations = app.workspace.reservations
        let geometry = ChromeGeometry(size: window.bounds.size, folded: app.chrome.folded,
                                      hasNow: app.nowItem != nil,
                                      verticalControls: app.workspace.verticalControls,
                                      leadingRail: app.workspace.leadingRail)
        deviceNotes += [
            "window.statusBarFrame: \(rect(scene?.statusBarManager?.statusBarFrame ?? .zero))",
            "workspace.reservations: occlusions \(reservations.occlusions.map(rect)) divisions \(reservations.divisions.map(rect)) statusBarHeight \(reservations.statusBarHeight)",
            "rail.layout.back: \(rect(geometry.back)) sidebar: \(rect(geometry.sidebar))",
        ]
        if StateProbe.wantsFrames {
            for element in AXWalk.elements() where ["chrome.back", "workspace.sidebar"].contains(element.id) {
                deviceNotes.append("rail.element.\(element.id): \(rect(element.frame))")
            }
        }
        return deviceNotes + [
            "window.bounds: \(rect(window.bounds))",
            "window.safeArea: \(insets(window.safeAreaInsets))",
            "screen.bounds: \(rect(window.screen.bounds)) scale \(window.screen.scale)",
            "scene.orientation: \(scene?.interfaceOrientation.rawValue ?? -1) idiom \(window.traitCollection.userInterfaceIdiom.rawValue)",
            "sizeClass: h\(window.traitCollection.horizontalSizeClass.rawValue) v\(window.traitCollection.verticalSizeClass.rawValue)",
            "workspace: tablet=\(app.workspace.tabletControls) vertical=\(app.workspace.verticalControls) expanded=\(app.workspace.expanded) windowSize=\(app.workspace.windowSize.width)x\(app.workspace.windowSize.height)",
            "chrome.sides: left \(sides.left) right \(sides.right)",
        ]
    }

    static func ready(_ name: String, _ notes: [String]) {
        StateProbe.settled(name, notes)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let folder = caches.appendingPathComponent("yab-ready")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = notes.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        log.info("ready: \(name, privacy: .public)")
    }
}
