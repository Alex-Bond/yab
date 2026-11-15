import WebKit

// A link aimed at a named window (target="results", the common
// target="_new", window.open(url, "name")) opens a new tab the first time.
// The next such link from the same site finds that tab by its window's name,
// whatever it shows by now, and WebKit loads the link there, not in a new
// tab, as every browser does. WebKit then asks for that page to be brought
// forward (_focusWebView:). Yab never answered, so the link loaded behind
// you in an old tab, the page you clicked on stayed as it was, and the link
// only showed up later in a tab you had left on something else; closing
// your tabs or Open Link in New Tab was the only way to get it in front
// (register 1661, feedback #1214). Chrome, Safari and Arc bring that tab
// forward, so the link you clicked is what you see.
//
// Only right after your own click or key in a page of this window: a page
// calling window.focus() on its own takes nothing over.
extension Browser {
    /// How long after your click or key a page may still be brought
    /// forward: WebKit asks once the link's load has been decided, which a
    /// busy Mac takes a moment for.
    nonisolated static let namedWindowFocusWindow: TimeInterval = 1.5

    @objc(_focusWebView:)
    func focusWebView(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.builtPage === webView,
              Self.bringsForward(tab: tab.id, active: activeID, inRow: tabs.contains { $0 === tab },
                                 bench: tab.bench, lastInput: lastPageInput,
                                 now: ProcessInfo.processInfo.systemUptime)
        else { return }
        DebugLog.note("named-window-focus", ["host": webView.url?.host ?? ""])
        select(tab)
    }

    /// When you last clicked or pressed a key in any page of this window.
    private var lastPageInput: TimeInterval? {
        (tabs + outside).compactMap { $0.built?.lastInput }.max()
    }

    /// Whether a page WebKit asks to bring forward comes to the front: a
    /// tab of this window's row, not the one in front already, not an
    /// agent's, and only with your click or key a moment before.
    nonisolated static func bringsForward(tab: UUID, active: UUID?, inRow: Bool, bench: Bool,
                                          lastInput: TimeInterval?, now: TimeInterval) -> Bool {
        guard inRow, !bench, tab != active, let lastInput else { return false }
        return now >= lastInput && now - lastInput <= namedWindowFocusWindow
    }
}
