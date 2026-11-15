import AppKit
import WebKit

// The windows a page asks for. WebKit used to judge them itself and drop any
// window.open that wasn't inside a click's own handler, without a word: a
// "Sign in with Google" button that first fetched something from its server
// opened nothing, and nothing said why.
//
// Now every one comes to Browser's createWebViewWith and is judged here, the
// way DuckDuckGo's Mac browser judges them: a window asked for within a few
// seconds of your last click or key in that page opens, as before; any other
// is blocked, and the plate says "Window blocked", with the place it was
// going in its menu and "Always allow on <site>" (WindowChip). One click lets
// one window through, so a page can't open a stream of them on it; a site
// you allowed still gets only a couple in a row, and only while it is on
// screen. An agent's tabs open what their pages ask for, as they did.

/// A window the page asked for and didn't get.
struct BlockedWindow: Identifiable, Equatable {
    let id = UUID()
    /// Where it was going; nil or about:blank for a window the page meant to
    /// write into itself.
    let url: URL?
    /// The site of the page that asked, for "Always allow on …".
    let site: String
}

/// What a page has done about windows, from when it came until it is left.
struct PageWindows: Equatable {
    /// Newest first, one for each place, a few at most: the plate's chip and
    /// its menu.
    var blocked: [BlockedWindow] = []
    /// When windows opened with no input of yours, on a site allowed or for
    /// this visit, by the events' clock: the burst limit counts them.
    var unasked: [TimeInterval] = []
    /// "Allow on this visit": windows open until the page is left.
    var visit = false

    /// One more blocked: in front, in place of one going to the same place.
    mutating func block(_ window: BlockedWindow) {
        blocked.removeAll { WindowGate.place($0.url) == WindowGate.place(window.url) }
        blocked.insert(window, at: 0)
        if blocked.count > WindowGate.kept { blocked.removeLast(blocked.count - WindowGate.kept) }
    }
}

enum WindowGate {
    /// How long after a click or a key a window still counts as asked for:
    /// the threshold DuckDuckGo settled on for the same judgment, long enough
    /// for a sign-in button to hear back from its server first.
    static let after: TimeInterval = 6
    /// A site allowed, or a visit: at most this many windows without input
    /// in `span` seconds.
    static let burst = 2
    static let span: TimeInterval = 10
    /// How many blocked places the menu offers.
    static let kept = 3

    /// What is known about a window when it is asked for.
    struct Ask: Equatable {
        /// WebKit's own word: asked for inside a click's or a key's handler.
        var gesture = false
        /// Seconds since your last click or key in the page; nil when there
        /// was none since it came, or a window took it.
        var sinceInput: TimeInterval?
        /// Allowed on the page's site, or for this visit.
        var allowed = false
        /// The page is in front: the tab on screen, or a half of the pair.
        var onScreen = true
        /// Asked by the page or a frame of its own site, not another site's
        /// frame on it, an advertisement's most often.
        var own = true
    }

    enum Verdict: Equatable {
        /// It opens. `input`: it took your click, the next needs another.
        case open(input: Bool)
        /// It doesn't. `said`: on the plate; another site's frame is
        /// refused quietly, it is nothing you asked for.
        case block(said: Bool)
    }

    /// The judgment itself, with the clock handed in.
    static func decide(_ ask: Ask, unasked: [TimeInterval], now: TimeInterval) -> Verdict {
        if ask.gesture { return .open(input: true) }
        if let since = ask.sinceInput, (0...after).contains(since) { return .open(input: true) }
        if ask.allowed, ask.onScreen, ask.own, recent(unasked, now: now).count < burst { return .open(input: false) }
        return .block(said: ask.own)
    }

    /// The burst's stamps still inside its span.
    static func recent(_ stamps: [TimeInterval], now: TimeInterval) -> [TimeInterval] {
        stamps.filter { now - $0 < span }
    }

    /// The host a window was going to, as the menu writes it: no "www.", and
    /// nil for a window with nowhere of its own yet.
    static func place(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A page's site, as Site Controls names it: its host without "www.",
    /// and nil for a page that isn't on the web.
    static func site(of url: URL?) -> String? { place(url) }

    /// WebKit's word on whether the window was asked for inside a click's
    /// or a key's handler (WKNavigationActionPrivate). Missing, a link
    /// clicked is taken for one.
    static func gesture(_ action: WKNavigationAction) -> Bool {
        let name = NSSelectorFromString("_isUserInitiated")
        guard action.responds(to: name) else { return action.navigationType == .linkActivated }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(action.method(for: name), to: Get.self)(action, name)
    }

    /// The frame that asked. WebKit can leave it out, which Swift's
    /// non-optional property doesn't allow for.
    static func source(_ action: WKNavigationAction) -> WKFrameInfo? {
        action.value(forKey: "sourceFrame") as? WKFrameInfo
    }

    // MARK: - always allowed

    nonisolated static let key = "windows.allowed"

    /// Sites whose pages may open windows without a click, said in Site
    /// Controls' This Site rows.
    static var allowed: Set<String> { Set(Store.settings.stringArray(forKey: key) ?? []) }

    static func allows(_ site: String) -> Bool { allowed.contains(site) }

    static func allow(_ site: String) {
        Store.settings.set(Array(allowed.union([site])).sorted(), forKey: key)
    }

    static func forget(_ site: String) {
        Store.settings.set(Array(allowed.subtracting([site])).sorted(), forKey: key)
    }
}

extension Browser {
    /// Whether the window `webView`'s page asks for opens. One that doesn't
    /// is kept on its tab for the plate, until the page is left.
    func letsWindow(from view: any PageHandle, for action: PageAction, parent: Tab?) -> Bool {
        let gesture = action.userInitiated
        // A view no tab here holds, one let go when its tab went to sleep:
        // only what WebKit itself would have let through.
        guard let page = parent ?? peeking.flatMap({ $0.builtPage === view ? $0 : nil }), !page.asleep else { return gesture }
        // An agent's tabs as they were: what their pages open lands behind
        // you, in tabs of their own.
        if page.bench { return true }
        let now = ProcessInfo.processInfo.systemUptime
        let site = WindowGate.site(of: view.url)
        var own = true
        if let frame = action.source, !frame.isMainFrame {
            let host = frame.host
            own = !host.isEmpty && Browser.site(host) == view.url?.host().map(Browser.site)
        }
        let ask = WindowGate.Ask(
            gesture: gesture,
            sinceInput: view.lastInput.map { now - $0 },
            allowed: page.windows.visit || site.map(WindowGate.allows) == true,
            onScreen: onScreen(page.id),
            own: own
        )
        switch WindowGate.decide(ask, unasked: page.windows.unasked, now: now) {
        case .open(let input):
            if input {
                view.lastInput = nil
            } else {
                page.windows.unasked = WindowGate.recent(page.windows.unasked, now: now) + [now]
            }
            return true
        case .block(let said):
            if said, let site { page.windows.block(BlockedWindow(url: action.request.url, site: site)) }
            return false
        }
    }

    /// The page was left: what it asked for goes with it, and a click on
    /// the page before is no click on the new one.
    func windowsLeft(_ tab: Tab) {
        tab.builtPage?.lastInput = nil
        if tab.windows != PageWindows() { tab.windows = PageWindows() }
    }

    /// The menu's "Open <place>": the window as a tab beside its page, in
    /// front, as one it opened would have been. One with nowhere to go yet
    /// can't be opened after the fact: the page's next one is let through.
    func openBlocked(_ window: BlockedWindow, from tab: Tab) {
        tab.windows.blocked.removeAll { $0.id == window.id }
        guard let url = window.url, WindowGate.place(url) != nil else {
            tab.windows.visit = true
            return
        }
        let opened = open(url, foreground: true, from: tab, linked: true, backToSource: false)
        opened.opener = tab.id
    }

    /// "Always allow on <site>": said once, and the newest window it was
    /// about is opened.
    func allowWindows(on tab: Tab) {
        guard let site = tab.windows.blocked.first?.site else { return }
        WindowGate.allow(site)
        let newest = tab.windows.blocked.first { WindowGate.place($0.url) != nil }
        tab.windows.blocked = []
        if let newest { openBlocked(newest, from: tab) }
    }
}

/// Chromium's own blocker judges a Chromium page's windows, and it says so
/// only in a bubble nobody sees. A window.open it answered with nothing is told
/// to the plate, as WebKit's are ("Window blocked", WindowChip), and a site
/// allowed in Site Controls is allowed in Chromium's settings too
/// (ChromiumPermissions). A window asked for with noopener answers nothing by
/// design, and isn't counted.
final class WindowRelay: NSObject, PageScriptReceiving {
    static let name = "yabWindows"
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard message.frame.isMain else { return }
        let text = message.body as? String ?? ""
        MainActor.assumeIsolated {
            guard let tab, let site = WindowGate.site(of: tab.address) else { return }
            tab.windows.block(BlockedWindow(url: URL(string: text, relativeTo: tab.address)?.absoluteURL, site: site))
        }
    }

    static let page = """
    (function () {
      if (window.top !== window) return;
      var own = window.open;
      window.open = new Proxy(own, { apply: function (target, self, args) {
        var made = Reflect.apply(target, self, args);
        if (made === null && !/noopener|noreferrer/i.test(String(args[2] || ''))) {
          try { window.dispatchEvent(new CustomEvent('yab:window-blocked', { detail: String(args[0] || '') })); } catch (e) {}
        }
        return made;
      } });
    })();
    """

    /// In yab's world: where it was going, handed on.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabWindowsBridged) return;
      window.__yabWindowsBridged = true;
      window.addEventListener('yab:window-blocked', function (e) { handler.postMessage(String(e.detail)); });
    })();
    """
}
