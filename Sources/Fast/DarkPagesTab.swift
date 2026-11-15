import AppKit
import SwiftUI
import WebKit

/// A tab's part of dark pages: the decision its next document was armed
/// with, the one its document has now, and the frames that asked.
@MainActor
final class DarkTabState {
    let relay = DarkRelay()
    /// What the next document was armed with (Tab.arm).
    var armed: DarkDecision = .none
    /// What the document up now was told, from its main frame's ask.
    var page: DarkDecision = .none
    var host: String?
    /// The frames of the document up now that asked, to tell of a change
    /// without a reload.
    var frames: [PageFrame] = []
    /// Whether the appearance and the ground under the page are ours.
    var appearanceSet = false
    var underSet = false
}

extension Tab {
    /// Before the request leaves: the decision for where the tab is going,
    /// the appearance it is drawn in and the ground under its first frame.
    func darkArm(url: URL?, host: String?) {
        if DarkPages.active(windowDark: DarkPages.windowDark(for: self)) { DarkLists.shared.warm() }
        let decision = DarkPages.decision(for: self, url: url, host: host)
        darkState.armed = decision
        darkDress(decision)
        if decision == .engine || decision == .on || decision == .check { Tab.forgetShade(url ?? address) }
    }

    /// The appearance the page is drawn in (DarkPages.appearance) and the
    /// ground under the page, dark from before its first frame while the
    /// engine may be coming. A Chromium page is told both before its
    /// request leaves (ChromiumPage+Dark.swift).
    func darkDress(_ decision: DarkDecision) {
        guard let view = builtPage else { return }
        let wantedDark = DarkPages.appearance(decision, windowDark: DarkPages.windowDark(for: self))
            ?? (DarkPages.windowDark(for: self) ? NSAppearance.Name.darkAqua : nil)
        if let wanted = wantedDark {
            if view.appearance?.name != wanted { view.appearance = NSAppearance(named: wanted) }
            darkState.appearanceSet = true
        } else if darkState.appearanceSet {
            view.appearance = nil
            darkState.appearanceSet = false
        }
        let under: NSColor? = decision == .engine || decision == .on || decision == .check ? DarkPages.groundColor() : nil
        if let under {
            darkGround(under)
            darkState.underSet = true
        } else if darkState.underSet {
            darkGround(nil)
            darkState.underSet = false
        }
    }

    /// The ground under the page: WebKit's under-page color, Chromium's
    /// default background.
    private func darkGround(_ color: NSColor?) {
        if let web = built { web.underPageBackgroundColor = color }
        else if let chromium = builtPage as? ChromiumPage { chromium.darkGround(color) }
    }

    /// The page turned out dark of its own, or the engine failed: the
    /// ground goes back to the page's.
    private func clearDarkGround() {
        guard darkState.underSet else { return }
        darkGround(nil)
        darkState.underSet = false
    }

    /// A frame asked what it gets. The main frame starts a new document:
    /// its decision is made again from the address it really has.
    func darkAsked(_ frame: PageFrame, url: URL?, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        if frame.isMain {
            let host = PageScripts.host(of: url)
            let decision = DarkPages.decision(for: self, url: url, host: host)
            darkState.frames = [frame]
            darkState.page = decision
            darkState.host = host
            if decision.scripted != darkState.armed.scripted { darkDress(decision) }
            dark = shown(decision)
        } else if darkState.frames.count < 64 {
            darkState.frames.append(frame)
        }
        let top = darkState.page, isMain = frame.isMain
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = DarkPages.answer(top: top, url: url, isMain: isMain)
            DispatchQueue.main.async { MainActor.assumeIsolated { reply(answer, nil) } }
        }
    }

    /// A new document that was armed without the scripts (kept light, or
    /// pages can't be dark here): it never asks, so it is said here.
    func darkCommitted() {
        let armed = darkState.armed
        guard !armed.scripted else { return }
        darkState.page = armed
        darkState.host = PageScripts.host(of: builtPage?.url ?? address)
        darkState.frames = []
        let now = shown(armed)
        if dark != now { dark = now }
    }

    /// What the page found: learned for its site, the window's tint after
    /// the darkened page.
    func darkDone(_ frame: PageFrame, _ body: [String: Any]) {
        guard frame.isMain, let host = darkState.host else { return }
        let sign = body["sign"] as? Bool ?? false
        switch body["result"] as? String {
        case "engine":
            dark = .engine
            if darkState.page == .check {
                DarkPages.learn(host, .engine, sign: sign, shy: shy)
            } else if darkState.page == .engine, DarkPages.relearns(DarkPages.learned(host), sign: sign) {
                // The site has grown a dark theme: the next visit looks again.
                DarkPages.forget(host)
            }
        case "own":
            dark = .own
            // A look, or the engine's second look once the page loaded: the
            // site turned out dark of its own (#336).
            if darkState.page == .check || darkState.page == .engine, body["locked"] as? Bool != true {
                DarkPages.learn(host, .own, sign: false, shy: shy)
            }
            clearDarkGround()
        case "error":
            dark = .none
            NSLog("yab: dark pages: the engine failed on %@ (Dark Reader %@): %@", host, DarkPages.version, body["error"] as? String ?? "")
            DebugLog.note("dark.error", ["host": host, "error": body["error"] as? String ?? "", "fixes": DarkPages.version])
            clearDarkGround()
        default:
            return
        }
        retone(fresh: true)
    }

    static func shown(_ decision: DarkDecision) -> DarkShown {
        shown(decision, extensionOn: DarkPages.extensionOn)
    }

    func shown(_ decision: DarkDecision) -> DarkShown {
        Tab.shown(decision, extensionOn: DarkPages.extensionOn(for: self))
    }

    static func shown(_ decision: DarkDecision, extensionOn: Bool) -> DarkShown {
        switch decision {
        case .engine, .on, .check: return .engine
        case .own: return .own
        case .off: return .off
        case .none: return extensionOn && DarkPages.active(windowDark: DarkPages.windowDark) ? .extensionDoes : .none
        }
    }

    /// Something every page follows changed (the mode, the window's
    /// appearance, the site's word): the page up now changes without a
    /// reload, and the next document is armed with the new decision.
    func darkRefresh() {
        guard let page = builtPage, !isBlank else {
            darkState.armed = .none
            return
        }
        let decision = DarkPages.decision(for: self, url: address, host: nil)
        let had = darkState.page
        darkState.armed = decision
        darkDress(decision)
        // Whether the document up now has the scripts: its frames asked.
        // A page turned off keeps them, and is told rather than given
        // them again (evals/dark-pages, Site Controls off then on).
        let loaded = !darkState.frames.isEmpty
        if decision.scripted, !loaded {
            // The page came without the scripts: given them now, the main
            // frame at least, and put in for whatever comes next.
            arm(hiding: veils)
            darkState.page = decision
            darkState.host = PageScripts.host(of: address)
            if page.engine == .chromium {
                let address = self.address
                // A page that came without Dark pages' world gets it bound
                // first: the run below waits for it in the page's queue.
                if let chromium = page as? ChromiumPage, !chromium.scripts.darkBound {
                    chromium.refreshFeatureScripts(to: address)
                }
                let source = DarkPages.engine.source + "\n;\n" + DarkPages.startScript(DarkLook.read(), ground: DarkPages.groundHex()).source
                // Remote evaluations can overlap while creating a world.
                // Finish the proxy first, then start the engine in one call.
                page.run(DarkPages.proxy.source, in: .page, gesture: false) { [weak self, weak page] result in
                    if case .failure(let error) = result {
                        NSLog("yab: dark pages: live proxy failed: %@", error.localizedDescription)
                    }
                    guard case .success = result, let self, let page, self.builtPage === page,
                          !self.gone, self.address == address, self.darkState.page == decision else { return }
                    page.run(source, in: DarkPages.pageWorld, gesture: false) { result in
                        if case .failure(let error) = result {
                            NSLog("yab: dark pages: live engine failed: %@", error.localizedDescription)
                        }
                    }
                }
            } else {
                page.run(DarkPages.proxy.source, in: .page, gesture: false)
                page.run(DarkPages.engine.source, in: DarkPages.pageWorld, gesture: false)
                page.run(DarkPages.startScript(DarkLook.read(), ground: DarkPages.groundHex()).source, in: DarkPages.pageWorld, gesture: false)
            }
        } else if decision.scripted {
            darkState.page = decision
            darkTell(decision)
        } else if loaded {
            darkState.page = decision
            darkTell(.off)
            if had.scripted { arm(hiding: veils) }
        } else {
            darkState.page = decision
        }
        dark = shown(decision)
        if !reader { retone(fresh: true) }
    }

    /// Each frame that asked, told what it gets now.
    func darkTell(_ decision: DarkDecision) {
        guard let page = builtPage else { return }
        for frame in darkState.frames {
            let given = frame.isMain ? decision : DarkPages.frame(top: decision, darkSite: DarkLists.shared.isDark(frame.url))
            page.run("window.__yabDark && window.__yabDark.apply('\(given.rawValue)')", in: DarkPages.pageWorld, frame: frame, gesture: false)
        }
    }

    /// The same words in every frame of the page.
    func darkEvaluate(_ script: String, done: (@MainActor () -> Void)? = nil) {
        guard let page = builtPage, darkState.page.scripted, !darkState.frames.isEmpty else { done?(); return }
        var left = darkState.frames.count
        for frame in darkState.frames {
            page.run(script, in: DarkPages.pageWorld, frame: frame, gesture: false) { _ in
                left -= 1
                if left == 0 { done?() }
            }
        }
    }

    /// Reading Mode has its own look: the engine stands aside while it is up.
    func darkReading(_ reading: Bool) {
        guard darkState.page.scripted else { return }
        darkTell(reading ? .off : darkState.page)
    }

    /// Paper stays white: the engine off for the print sheet, back after.
    func darkPrint(_ going: Bool, then: @escaping @MainActor () -> Void) {
        guard dark == .engine else { return then() }
        darkEvaluate("window.__yabDark && window.__yabDark.print(\(going))") {
            // A frame to restyle before WebKit lays the page out for paper.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { then() } }
        }
    }
}

extension Browser {
    /// The tab in front can be darkened or kept light from here: pages can
    /// be dark, Dark Reader the extension isn't doing it, and it is a site.
    func darkPageReady(_ given: Tab? = nil) -> Tab? {
        guard let tab = given ?? active, !tab.isBlank, !tab.bench, PageScripts.host(of: tab.address) != nil,
              DarkPages.active(windowDark: DarkPages.windowDark(for: tab), mode: prefs.darkPages), !DarkPages.extensionOn(for: tab),
              tab.dark == .engine || tab.dark == .own || tab.dark == .off
                || (tab.dark == .none && prefs.darkPages == .off && DarkPages.eligible(tab, url: tab.address)) else { return nil }
        return tab
    }

    /// ⌥⇧D, Site Controls, ⌘T and the View menu: the site in front kept
    /// light, or dark again. Every tab of the site follows, without a reload.
    @discardableResult
    func toggleDarkPage(_ given: Tab? = nil) -> Bool {
        guard let tab = darkPageReady(given), let host = PageScripts.host(of: tab.address) else { return false }
        DarkPages.toggle(host, darkNow: tab.dark == .engine || tab.dark == .own)
        DarkPages.refresh(host: host)
        return true
    }

    /// What ⌘T's Dark Page does here, said as its action.
    var darkPageAction: String {
        guard let tab = darkPageReady(), let host = PageScripts.host(of: tab.address) else { return "Run Command" }
        return tab.dark == .engine || tab.dark == .own ? "Turn Off for \(host)" : "Turn On for \(host)"
    }
}

/// View › Theme › Dark Page, under the themes: checked while the page in front
/// is dark, whether by the engine or its own.
struct DarkPageMenu: View {
    let browser: Browser

    var body: some View {
        let tab = browser.darkPageReady()
        Toggle("Dark Page", isOn: Binding(get: { tab.map { $0.dark == .engine || $0.dark == .own } ?? false },
                                          set: { _ in browser.toggleDarkPage() }))
            .disabled(tab == nil)
    }
}

extension DarkPages {
    /// An extension registered the same keys first: they are its, as any
    /// extension's keys are (Keymap.extensionClash).
    static func extensionHolds(_ event: NSEvent) -> Bool {
        guard #available(macOS 15.4, *), let pressed = Hotkey(event) else { return false }
        let extensions = Extensions.here
        return extensions.contexts.values.contains { context in
            context.commands.contains { command in
                guard let key = command.activationKey else { return false }
                return Hotkey(key, command.modifierFlags) == pressed
            }
        }
    }
}

/// The print sheet's end, for dark pages to come back after it.
final class PrintEnd: NSObject {
    private let done: @MainActor () -> Void
    private static var held: Set<PrintEnd> = []

    @MainActor init(_ done: @escaping @MainActor () -> Void) {
        self.done = done
        super.init()
        PrintEnd.held.insert(self)
    }

    @objc func printed(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated {
            done()
            PrintEnd.held.remove(self)
        }
    }

    static let selector = #selector(printed(_:success:contextInfo:))
}
