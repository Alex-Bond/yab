import AppKit
import WebKit

// Who may speak for a page to Yab.
//
// A page's questions reach Yab through scripts in Yab's own world
// (Web.world), which carry DOM events, and what they read off the page, to
// message handlers. The page can't reach those handlers, but it can raise
// the events the bridges listen for, and so can any frame on it, an ad's
// included, since some bridges are in every frame. So Yab's side never takes
// a message's word for where it came from: it reads `message.frameInfo`,
// which WebKit fills in, and holds it to what the relay is for.
//
// - Acting for the site you're on, a share of the screen, a card or a
//   password to keep, the site's badge: the main frame, or a frame of the
//   same site as the page on top, and nothing else.
// - Serving one place: that origin only. The Web Store's button, Meet's
//   switches, this Mac's own servers for Developer Mode, yab:// pages.
// - What only a person may start, a share of the screen: a click or a key
//   of theirs in that tab a moment before too, as AppKit handed it to the
//   page (PageView), or Yab's own button pressed for them; never what the
//   page says of itself.
// - Every frame only where that is the point: the card boxes in Stripe's
//   and the like's frames, a picture's menu, an agent's frames.
//
// DuckDuckGo's browser holds its handlers to origins the same way
// (UserScriptMessaging's MessageOriginPolicy) and judges a click from the
// last event's time (PopupHandlingTabExtension).

@MainActor
enum RelayGuard {
    /// Whose hand was last on a page.
    enum Hand: Equatable {
        /// A click or a key of the person's, in the page.
        case page
        /// Yab's own control pressed for the page: the call window's Share.
        case yab
    }

    /// How long a click or a key stands behind what the page asks next:
    /// WebKit's own transient activation, five seconds.
    nonisolated static let fresh: TimeInterval = 5

    private final class Touch {
        let at: TimeInterval
        let hand: Hand
        init(at: TimeInterval, hand: Hand) {
            self.at = at
            self.hand = hand
        }
    }

    /// The last hand on each page, kept no longer than the page.
    private static let touched = NSMapTable<AnyObject, Touch>.weakToStrongObjects()

    /// Seconds since the Mac started, the clock AppKit's events keep.
    nonisolated static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A click or a key of the person's, handed to the page (PageView).
    static func felt(_ page: AnyObject, at time: TimeInterval = now) {
        touched.setObject(Touch(at: time, hand: .page), forKey: page)
    }

    /// Yab pressed the page's own button for the person.
    static func vouch(_ page: AnyObject, at time: TimeInterval = now) {
        touched.setObject(Touch(at: time, hand: .yab), forKey: page)
    }

    /// The last hand on the page if it is recent enough to stand behind a
    /// question, used up by the asking: one click, one question.
    static func take(_ page: AnyObject?, now time: TimeInterval = now) -> Hand? {
        guard let page, let last = touched.object(forKey: page) else { return nil }
        touched.removeObject(forKey: page)
        return recent(last.at, now: time) ? last.hand : nil
    }

    nonisolated static func recent(_ at: TimeInterval, now: TimeInterval) -> Bool {
        now >= at && now - at <= fresh
    }

    // MARK: - frames

    /// The page's own frame: the main frame, or one of the same site as the
    /// page on top.
    static func ownFrame(_ frame: PageFrame, of tab: Tab) -> Bool {
        ownFrame(main: frame.isMain, scheme: frame.origin.scheme, host: frame.origin.host, top: top(of: tab))
    }

    static func ownFrame(_ frame: WKFrameInfo, of tab: Tab) -> Bool {
        ownFrame(main: frame.isMainFrame, scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, top: top(of: tab))
    }

    nonisolated static func ownFrame(main: Bool, scheme: String, host: String, top: URL?) -> Bool {
        main || sameSite(scheme: scheme, host: host, as: top)
    }

    /// The same scheme and the same registrable domain: accounts.google.com
    /// on mail.google.com, not an ad's frame, and not a.github.io on
    /// b.github.io. An opaque frame, a sandbox's or a data: one, has no host
    /// and is no one's.
    nonisolated static func sameSite(scheme: String, host: String, as top: URL?) -> Bool {
        let scheme = scheme.lowercased(), host = bare(host)
        guard let top, let topScheme = top.scheme?.lowercased(), let topHost = top.host().map(bare),
              !host.isEmpty, !topHost.isEmpty, scheme == topScheme, scheme == "https" || scheme == "http"
        else { return false }
        return Vault.registrable(host) == Vault.registrable(topHost)
    }

    /// The page on top as it committed. While the next one loads the
    /// address can already be the next one's, and a frame of that site is
    /// not yet the page's own.
    static func top(of tab: Tab) -> URL? {
        tab.builtPage?.committedURL ?? tab.address
    }

    /// The main frame of one place, over https: the Web Store, Meet.
    static func from(_ frame: PageFrame, _ host: String) -> Bool {
        frame.isMain && exactly(scheme: frame.origin.scheme, host: frame.origin.host, host)
    }

    static func from(_ frame: WKFrameInfo, _ host: String) -> Bool {
        frame.isMainFrame && exactly(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host, host)
    }

    nonisolated static func exactly(scheme: String, host: String, _ wanted: String) -> Bool {
        scheme.lowercased() == "https" && bare(host) == wanted
    }

    /// A page on this Mac's own server, as Developer Mode counts one:
    /// loopback, *.localhost and *.test, over http or https.
    static func local(_ origin: PageOrigin) -> Bool {
        local(scheme: origin.scheme, host: origin.host)
    }

    static func local(_ origin: WKSecurityOrigin) -> Bool {
        local(scheme: origin.protocol, host: origin.host)
    }

    nonisolated static func local(scheme: String, host: String) -> Bool {
        let host = bare(host)
        guard !host.isEmpty else { return false }
        return Address.isLocal(URL(string: "\(scheme.lowercased())://\(host.contains(":") ? "[\(host)]" : host)/"))
    }

    /// A host as WebKit and URL may each write it: lowercased, an IPv6
    /// address without its brackets.
    nonisolated private static func bare(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    // MARK: - sharing a screen

    /// A page's ask for the screen (Share.swift): from the page's own
    /// frames, and only just after a click or a key of yours in its tab, or
    /// Yab's Share pressed for it. Nil is no.
    static func share(_ frame: PageFrame, on tab: Tab) -> Hand? {
        guard ownFrame(frame, of: tab) else { return nil }
        return take(tab.builtPage)
    }

    static func share(_ frame: WKFrameInfo, on tab: Tab) -> Hand? {
        guard ownFrame(frame, of: tab) else { return nil }
        return take(tab.webKitOnly("Authenticated WebKit screen sharing", build: false))
    }
}
