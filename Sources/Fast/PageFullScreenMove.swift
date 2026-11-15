import AppKit
import WebKit

/// A page's own full screen (a video's button, x.com, YouTube) from a window
/// that is itself in macOS full screen.
///
/// WebKit lends the page to a window of its own and asks for that window's
/// full screen by its own animation: the page grows from where it was on the
/// desktop already showing, macOS moves to the new desktop once it fills the
/// screen. To be there to grow, the window is first put in front on the
/// desktop in front, made able to join any desktop for that moment
/// (WKFullScreenWindowController's beganEnterFullScreen). But a window that
/// may have a desktop of its own, put in front while its app's window has
/// one, is given its own by AppKit at once, from inside that very
/// makeKeyAndOrderFront, as a new window of a full-screen app is: macOS slid
/// to a new desktop with WebKit's window in its first state, black, its
/// animation never started, and the video came in only once the slide was
/// over, 150 to 430 ms of a black screen (register 1089, request 1007).
/// A bare WebKit window run as a plain tool, not an app bundle, is never
/// given one, and so showed none of it (evals/fullscreen-motion/control.py
/// now runs it from a bundle).
///
/// The window becomes key before it is put in front, inside the same call:
/// for that moment it is not one that may have a desktop of its own, so it
/// goes in front on this one, and WebKit gives it back its collection
/// behavior itself, the one it read before, as soon as it is in front, so
/// its own animation then takes it to full screen.
///
/// The same window has a title bar of its own (WebKit makes it titled, with
/// its content under the bar) that stays on through the whole move, and only
/// goes once the window is in full screen: a gray strip, the bar's own dark
/// fill, along the top of the growing video, and the page laid out below it,
/// the web view taking the bar's 32 points as an inset at the top on its own.
/// Once in, the bar goes, the inset with it, and the page was laid out again
/// a frame later at the full height: the video jumped up by half the bar
/// (register 1089 again, Almog). The bar is made clear, and the page keeps no
/// inset of its own while it is in WebKit's window: it rises flush, at the size it ends at.
@MainActor
final class PageFullScreenMove {
    private static let shared = PageFullScreenMove()

    static func watch() { shared.start() }
    static func moved(_ web: WKWebView) { shared.didMove(web) }
    static func ended(_ web: WKWebView) { shared.close(web) }

    private let center: NotificationCenter
    private let isWebKits: (NSWindow) -> Bool
    private let hasFullScreenWindow: (NSWindow) -> Bool
    private var watching: [NSObjectProtocol] = []
    private var sessions: [ObjectIdentifier: Session] = [:]

    init(center: NotificationCenter = .default,
         isWebKits: @escaping (NSWindow) -> Bool = { NSStringFromClass(type(of: $0)) == "WebCoreFullScreenWindow" },
         hasFullScreenWindow: @escaping (NSWindow) -> Bool = { window in
             NSApp.windows.contains { $0 !== window && $0.styleMask.contains(.fullScreen) && $0.isOnActiveSpace }
         }) {
        self.center = center
        self.isWebKits = isWebKits
        self.hasFullScreenWindow = hasFullScreenWindow
    }

    deinit {
        for token in watching { center.removeObserver(token) }
    }

    func start() {
        guard watching.isEmpty else { return }
        func hear(_ name: NSNotification.Name, _ action: @escaping (PageFullScreenMove, NSWindow) -> Void) {
            watching.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow else { return }
                    action(self, window)
                }
            })
        }
        hear(NSWindow.didBecomeKeyNotification) { move, window in
            move.prune()
            guard move.isWebKits(window) else { return }
            move.clear(window)
            move.hold(window)
        }
        hear(NSWindow.willEnterFullScreenNotification) { move, window in
            guard move.isWebKits(window) else { return }
            if let session = move.session(of: window) {
                if session.ending { move.restore(session) } else { session.releasePrimary() }
            }
            move.clear(window)
        }
        hear(NSWindow.didExitFullScreenNotification) { move, window in
            guard let session = move.session(of: window) else { return }
            move.finish(session)
        }
        hear(NSWindow.willCloseNotification) { move, window in
            guard let session = move.session(of: window) else { return }
            move.restore(session)
        }
    }

    /// Each loan owns only Yab's changes, not WebKit's views or windows.
    /// A reused host must not inherit a previous page's inset or hold.
    @MainActor
    private final class Session {
        weak var window: NSWindow?
        weak var web: WKWebView?
        let id: ObjectIdentifier
        let transparent: Bool
        var automatic: Bool?
        var heldPrimary = false
        var ending = false
        var observation: NSKeyValueObservation?

        init(_ window: NSWindow) {
            self.window = window
            id = ObjectIdentifier(window)
            transparent = window.titlebarAppearsTransparent
        }

        func releasePrimary() {
            if heldPrimary { window?.collectionBehavior.insert(.fullScreenPrimary) }
            heldPrimary = false
        }

        func restoreWindow() {
            releasePrimary()
            window?.titlebarAppearsTransparent = transparent
        }
    }

    var sessionCount: Int { sessions.count }

    /// The loan this very window holds. A key alone is not enough: once a
    /// host is freed, a later window (a browser window leaving full screen,
    /// a PiP panel, the Small Window) may get its address, and its
    /// notifications must not end or restore a loan that was never its.
    private func session(of window: NSWindow) -> Session? {
        guard let session = sessions[ObjectIdentifier(window)], session.window === window else { return nil }
        return session
    }

    /// Whether the session, if any, that `window` holds is still live
    /// (entered and not yet finished). For tests of the matching rule.
    func isLending(_ window: NSWindow) -> Bool { session(of: window).map { !$0.ending } ?? false }

    /// WebKit's own switch for that inset (WKWebViewPrivate), which Safari
    /// turns off for its pages. Its setter is not KVC's, so it is called.
    private static let getAutomatic = NSSelectorFromString("_automaticallyAdjustsContentInsets")
    private static let setAutomatic = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")

    static func automatic(of web: WKWebView) -> Bool? {
        guard web.responds(to: getAutomatic), web.responds(to: setAutomatic),
              let method = class_getInstanceMethod(type(of: web), getAutomatic) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Get.self)(web, getAutomatic)
    }

    static func set(_ on: Bool, automaticOf web: WKWebView) {
        guard let method = class_getInstanceMethod(type(of: web), setAutomatic) else { return }
        typealias Put = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Put.self)(web, setAutomatic, on)
    }

    /// WebKit's window with a clear title bar, and the page in it with no
    /// inset for that bar: the bar is there through the move only.
    private func clear(_ window: NSWindow, page: WKWebView? = nil) {
        prune()
        let id = ObjectIdentifier(window)
        if let previous = sessions[id], previous.ending { return }
        let web = page ?? window.contentView.flatMap(Self.firstWeb)
        if let previous = sessions[id], let before = previous.web, let web, before !== web {
            restore(previous)
        }
        if let web {
            for previous in Array(sessions.values) where previous.id != id && previous.web === web { restore(previous) }
        }
        let session = sessions[id] ?? Session(window)
        sessions[id] = session
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        guard let web, session.web == nil else { return }
        session.web = web
        session.automatic = Self.automatic(of: web)
        if session.automatic == true {
            Self.set(false, automaticOf: web)
            // Off, WebKit keeps the inset it last worked out, often the
            // bar's already. None at the top, the rest left as it was.
            Self.noTopInset(web)
        }
        session.observation = web.observe(\.fullscreenState, options: [.new]) { [weak self, weak session] web, _ in
            MainActor.assumeIsolated {
                guard let self, let session, web.fullscreenState == .notInFullscreen else { return }
                self.finish(session)
            }
        }
        StageView.mark("fs.clear", ["window": window.windowNumber])
    }

    private static func noTopInset(_ web: WKWebView) {
        if #available(macOS 26.0, *) {
            guard web.obscuredContentInsets.top != 0 else { return }
            var insets = web.obscuredContentInsets
            insets.top = 0
            web.obscuredContentInsets = insets
        } else {
            let selector = NSSelectorFromString("_setTopContentInset:")
            guard let method = class_getInstanceMethod(type(of: web), selector) else { return }
            typealias Put = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            unsafeBitCast(method_getImplementation(method), to: Put.self)(web, selector, 0)
        }
    }

    /// Attachment, not a two-second timer, ends a loan. An exit may return
    /// the page late, through PiP, or without a didExit notification at all.
    func didMove(_ web: WKWebView) {
        if let window = web.window, isWebKits(window) {
            // Keep the entry adjustment at WebKit's key/enter boundary.
            // Attachment can supply a page that was not there yet.
            if session(of: window) != nil { clear(window, page: web) }
            return
        }
        for session in Array(sessions.values) where session.web === web {
            if web.window != nil || session.ending { restore(session) }
        }
    }

    func close(_ web: WKWebView) {
        for session in Array(sessions.values) where session.web === web { restore(session) }
    }

    private func finish(_ session: Session) {
        guard sessions[session.id] === session else { return }
        session.ending = true
        session.observation = nil
        session.restoreWindow()
        // A page detached during exit has no next host to wait for.
        guard let window = session.web?.window, isWebKits(window) else { restore(session); return }
    }

    private func restore(_ session: Session) {
        guard sessions[session.id] === session else { return }
        sessions[session.id] = nil
        session.observation = nil
        session.restoreWindow()
        if let web = session.web, let automatic = session.automatic { Self.set(automatic, automaticOf: web) }
    }

    private func prune() {
        for session in Array(sessions.values) where session.window == nil || session.web == nil { restore(session) }
    }

    private static func firstWeb(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for kid in view.subviews { if let web = firstWeb(in: kid) { return web } }
        return nil
    }

    private func hold(_ window: NSWindow) {
        // WebKit's window, not yet in full screen, while a window of ours
        // is in full screen on this desktop: only then does AppKit give it
        // a desktop of its own. (It counts as visible already, kept ordered
        // in off the screen between its turns.)
        guard !window.styleMask.contains(.fullScreen),
              window.collectionBehavior.contains(.fullScreenPrimary),
              let session = self.session(of: window), !session.ending,
              hasFullScreenWindow(window) else { return }
        session.heldPrimary = true
        window.collectionBehavior.remove(.fullScreenPrimary)
        StageView.mark("fs.hold", ["behavior": window.collectionBehavior.rawValue])
    }
}
