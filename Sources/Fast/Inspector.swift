import AppKit
import WebKit

// Developer tools, on Chrome's keys: ⌥⌘I for the card (DevTools.swift),
// ⌥⌘J for its console, ⌥⌘C to pick an element on the page.
//
// The card is one for every page, its head Chrome's row (DevHead.swift):
// WebKit's tabs docked in it, and yab's own lists. On a local page with
// the card away, ⌥⌘C is Measure; with the card out, and on any other page,
// it is WebKit's picker, in the card's Elements. The page's right-click
// Inspect Element always opens Yab's Elements on what was clicked;
// Measure has its own row there when the card is away.
//
// The two are never picking at once: WebKit's picker starting puts Measure
// away, whose layer over the page would take the clicks meant for it, and
// Measure coming stops WebKit's picker.
//
// WebKit answers for its inspector only through names outside the public
// framework, so each is asked for before it is used: a WebKit without them
// leaves the menu doing nothing rather than the app falling over.

@MainActor
enum Inspector {
    /// Inspect Element in the page's own right-click menu, and the
    /// inspector's keys working on it. `isInspectable` alone only lets
    /// Safari's Develop menu reach the page.
    static func allow(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, true)
    }

    /// A page's inspector, the object WebKit keeps for it.
    private static let get = NSSelectorFromString("_inspector")

    static func ofPage(_ page: any PageHandle) -> NSObject? {
        guard let web = WebKitOnly.page(page, for: "WebKit Inspector") else { return nil }
        return of(web)
    }

    static func of(_ web: WKWebView) -> NSObject? {
        guard web.responds(to: get) else { return nil }
        return web.perform(get)?.takeUnretainedValue() as? NSObject
    }

    static func send(_ inspector: NSObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    static func asks(_ inspector: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: selector), to: Getter.self)(inspector, selector)
    }
}

extension Tab {
    /// WebKit's inspector is up on this page.
    var webInspecting: Bool {
        guard let web = webKitOnly("WebKit inspector state", build: false), let inspector = Inspector.of(web) else { return false }
        return Inspector.asks(inspector, "isVisible")
    }

    /// WebKit's picker is waiting for a click on this page.
    var webPicking: Bool {
        guard let web = webKitOnly("WebKit inspector state", build: false), let inspector = Inspector.of(web) else { return false }
        return Inspector.asks(inspector, "isElementSelectionActive")
    }
}

extension Browser {
    /// View › Web Inspector and the command: the card on Elements, or away
    /// if it is on Elements or one of WebKit's tabs.
    func toggleInspector() {
        if chromiumDevFront != nil { developerTools(); return }
        if devOpen, devPane.isWebKit || devPane == .elements { closeDevTools(); return }
        if devOpen { pickDevPane(.elements) } else { openDevTools(.elements) }
    }

    /// ⌥⌘J: the card on Console, or away: pressed
    /// again with the card out in the window, on whatever pane, it goes
    /// (feedback #1467). In a window of its own it comes forward on
    /// Console instead, as Chromium's undocked tools do.
    func showConsole() {
        if devOpen || devComing, !devDetached { closeDevTools(); return }
        if devOpen { pickDevPane(.console) } else { openDevTools(.console) }
        consolePanel.focusPrompt = true
    }

    /// ⌥⌘C: on a local page with the card away, Measure, on or away;
    /// otherwise WebKit's picker, in the card: the next click on the page
    /// picks what Elements shows, and again, the picking stops.
    func inspectElement() {
        if let tab = toolsFront, tab.page.engine == .chromium, devOpen || devFront == nil { pickWithChromium(tab); return }
        if devPicking { stopPickingElement(); return }
        if devFront != nil, !devOpen {
            toggleMeasure()
            return
        }
        if let tab = active, tab.webPicking, let inspector = Inspector.ofPage(tab.page) {
            Inspector.send(inspector, "toggleElementSelection")
            return
        }
        pickWithWebKit()
    }
}
