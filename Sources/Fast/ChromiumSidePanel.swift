import AppKit
import SwiftUI
import WebKit

/// An extension's side panel for a Chromium page, in the column where the
/// WebKit stack shows its panels (ExtensionSidePanelColumn). Chrome would
/// draw the panel in its own browser window, which Yab never shows, so Yab
/// hosts the extension's panel page itself, in the clicked tab's profile:
/// the page has the same origin, storage and chrome.* APIs as in Chromium.
@MainActor
final class ChromiumSidePanel: ObservableObject {
    static let shared = ChromiumSidePanel()

    final class Panel: Identifiable {
        let extensionID: String
        let contextID = UUID().uuidString
        let name: String
        let button: Extensions.Button?
        let tab: Tab
        let events: Events
        weak var browser: Browser?
        var id: String { contextID }

        init(extensionID: String, name: String, button: Extensions.Button?, tab: Tab, events: Events, browser: Browser) {
            self.extensionID = extensionID
            self.name = name
            self.button = button
            self.tab = tab
            self.events = events
            self.browser = browser
        }
    }

    /// The panel page's own engine events: links it opens go to an ordinary
    /// tab of the window; nothing else from it is offered.
    final class Events: NSObject, WKNavigationDelegate, WKUIDelegate, PageEvents {
        weak var browser: Browser?
        var finished = false
        var failed = false

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            switch event {
            case .started: finished = false
            case .finished: finished = true
            case .failed(_, let error, _):
                if (error as NSError).code != NSURLErrorCancelled { failed = true }
            case .redirected, .committed: break
            }
        }

        func page(_ page: any PageHandle, ended reason: PageEnd?) { failed = true }

        func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) {
            if let url = popup.action.request.url, url.scheme == "https" || url.scheme == "http", let browser {
                _ = browser.open(url, foreground: true, atEnd: true)
            }
            reply(nil)
        }

        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
    }

    /// What the extension said of its panel, read in its own origin.
    struct Options: Equatable {
        var path: String
        var enabled: Bool
        var openOnClick: Bool
    }

    @Published private(set) var panels: [Panel] = []

    func panels(in browser: Browser) -> [Panel] { panels.filter { $0.browser === browser } }

    /// The button press for an extension without a popup on this page: its
    /// panel, when it has one it wants opened from its button. False hands
    /// the press back to Chrome's own action click.
    @available(macOS 15.4, *)
    func press(_ id: String, from tab: Tab) async -> Bool {
        guard let browser = (tab.delegate as? Browser) ?? BrowserWindows.shared.activeBrowser else { return false }
        if let open = panels(in: browser).first(where: { $0.extensionID == id }),
           browser.panelExtension == id, browser.panelContextID == open.contextID, browser.chatOpen {
            close(open)
            return true
        }
        let panel = make(id, from: tab, browser: browser)
        guard let options = await read(panel), options.enabled, options.openOnClick, !options.path.isEmpty,
              let url = URL(string: "chrome-extension://\(id)/" + options.path.drop(while: { $0 == "/" })),
              url.host == id else {
            panel.tab.close()
            return false
        }
        show(panel, url: url)
        return true
    }

    /// chrome.sidePanel.open() and Yab's own menu: the panel, whatever its
    /// button does.
    @available(macOS 15.4, *)
    func open(_ id: String, from tab: Tab) async -> Bool {
        guard let browser = (tab.delegate as? Browser) ?? BrowserWindows.shared.activeBrowser else { return false }
        let panel = make(id, from: tab, browser: browser)
        guard let options = await read(panel), options.enabled, !options.path.isEmpty,
              let url = URL(string: "chrome-extension://\(id)/" + options.path.drop(while: { $0 == "/" })),
              url.host == id else {
            panel.tab.close()
            return false
        }
        show(panel, url: url)
        return true
    }

    func close(_ panel: Panel) {
        if let browser = panel.browser, browser.panelContextID == panel.contextID {
            browser.moveChat(open: false)
            browser.panelExtension = nil
            browser.panelContextID = nil
        }
        panels.removeAll { $0 === panel }
        panel.tab.close()
    }

    /// The column went away with this panel in front (Browser.hideChat).
    func closePanel(contextID: String?) {
        guard let contextID, let panel = panels.first(where: { $0.contextID == contextID }) else { return }
        close(panel)
    }

    // MARK: -

    @available(macOS 15.4, *)
    private func make(_ id: String, from source: Tab, browser: Browser) -> Panel {
        let page = (source.builtPage as? ChromiumPage)?.extensions.items.first { $0.id == id }
        let button = ChromiumColumn.shared.buttons(for: source, all: true).first { $0.id == id }
        let config = Web.configuration(shy: source.shy, store: source.store)
        let tab = Tab(shy: source.shy, configuration: config, engine: .chromium)
        let events = Events()
        events.browser = browser
        // The source's profile: the extension and its storage live there.
        tab.warmProfile = source.chromiumProfile
        tab.delegate = events
        tab.page.frame = CGRect(x: 0, y: 0, width: ChatLook.normal, height: 700)
        return Panel(extensionID: id, name: page?.name ?? button?.name ?? id, button: button, tab: tab, events: events, browser: browser)
    }

    /// Reads chrome.sidePanel's options from a document of the extension's
    /// own origin (its manifest, which every extension has), the only place
    /// the API answers.
    private func read(_ panel: Panel) async -> Options? {
        guard let manifest = URL(string: "chrome-extension://\(panel.extensionID)/manifest.json") else { return nil }
        panel.tab.go(to: manifest)
        for _ in 0..<60 {
            if panel.events.failed { return nil }
            if panel.events.finished, !panel.tab.page.isLoading,
               panel.tab.page.url?.host == panel.extensionID { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let body = """
        const m = chrome.runtime.getManifest();
        const fallback = (m.side_panel && m.side_panel.default_path) || '';
        if (!chrome.sidePanel) return {path: fallback, enabled: false, click: false};
        const o = await chrome.sidePanel.getOptions({}).catch(() => ({}));
        const b = await chrome.sidePanel.getPanelBehavior().catch(() => ({}));
        return {path: o.path || fallback, enabled: o.enabled !== false, click: !!b.openPanelOnActionClick};
        """
        guard let value = try? await panel.tab.page.call(body, gesture: false) as? [String: Any] else { return nil }
        let path = value["path"] as? String ?? ""
        // Only as the extension asked (setPanelBehavior), as in Chromium.
        let click = value["click"] as? Bool == true
        return Options(path: path, enabled: value["enabled"] as? Bool ?? false, openOnClick: click)
    }

    private func show(_ panel: Panel, url: URL) {
        guard let browser = panel.browser else { return }
        // One panel per extension per window, as Chromium keeps it.
        for old in panels(in: browser) where old.extensionID == panel.extensionID { close(old) }
        panels.append(panel)
        panel.tab.go(to: url)
        browser.panelTabID = nil
        browser.panelContextID = panel.contextID
        browser.panelExtension = panel.extensionID
        browser.moveChat(open: true)
    }

    var benchState: [[String: Any]] {
        panels.map { panel in
            let page = panel.tab.builtPage as? ChromiumPage
            return ["extension": panel.extensionID, "context": panel.contextID, "url": page?.url?.absoluteString ?? "",
                    "title": page?.title ?? "", "loading": page?.isLoading ?? false,
                    "front": panel.browser?.panelContextID == panel.contextID && panel.browser?.chatOpen == true,
                    "remote": page?.remoteID ?? "", "surface": page?.contextID ?? 0,
                    "visible": page.map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false]
        }
    }
}

private struct ChromiumSidePanelPage: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = tab.builtPage as? NSView, view.superview !== container else { return }
        view.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// ExtensionSidePanelColumn's look, round a Chromium panel page.
@available(macOS 15.4, *)
struct ChromiumSidePanelColumn: View {
    let browser: Browser
    let panel: ChromiumSidePanel.Panel
    let width: CGFloat
    @Environment(\.tabTitleSize) private var titleSize
    private static let inset: CGFloat = 4
    private static var cross: ButtonSize { SideBar.row >= ButtonSize.regular.height + 8 ? .regular : .small }
    private static var pageCorner: CGFloat { Radius.surface - inset } // design: concentric with the column's own corner, the inset in

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SideBar.markGap) {
                if let button = panel.button {
                    ExtensionIcon(button: button, size: SideBar.mark)
                        .frame(width: SideBar.mark, height: SideBar.mark)
                }
                Text(panel.name)
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    ChromiumSidePanel.shared.close(panel)
                } label: { Symbol("xmark", size: 13) }
                    .buttonStyle(.yab(.quiet, Self.cross, tint: Palette.ink, icon: .square))
                    .focusable(false)
                    .keyTip("Close", shortcut: "Hide Chat")
            }
            .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
            .padding(.trailing, (SideBar.row - Self.cross.height) / 2) // design: the cross's middle half a row in
            .frame(height: SideBar.row)
            .padding([.horizontal, .top], Self.inset)
            ChromiumSidePanelPage(tab: panel.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.pageCorner, style: .continuous))
                .padding([.horizontal, .bottom], Self.inset)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { HUD.plate(Radius.surface, surface: .page) }
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
    }
}
