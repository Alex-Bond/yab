import WebKit

/// Yab's own looks at a page, run without a user gesture.
///
/// A script run through WebKit's public API is a user gesture to the page,
/// and macOS 27's WebKit (bug 324512, fixed upstream on 2026-10-07) resets
/// the page's transient activation as each one ends: a real click's too.
/// Yab reads the page on its own many times a minute (the selection 1.2 s
/// after every click, the bar's color as the page scrolls or settles, the
/// page's icons, drafts, whether it still answers), and a site that copies,
/// opens a window or asks a permission after a wait (a fetch, then the
/// copy) found its click gone: evals/activation measured every copy made
/// 1.5 s after a real click failing, on every click. Run without a gesture,
/// a script neither grants the page an activation nor takes one away.
///
/// For reads and Yab's own bookkeeping only. A script that does something
/// for the person that a site or WebKit lets only a click do (play a video
/// with sound, go full screen, press a site's button that opens a window)
/// keeps the public call and its gesture. YAB_QUIET_SCRIPTS=0 runs them
/// all with a gesture again, for an A/B.
extension WKWebView {
    private static let quiet = ProcessInfo.processInfo.environment["YAB_QUIET_SCRIPTS"] != "0"
    private static let quietSelector = NSSelectorFromString(
        "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")
    private typealias Quiet = @convention(c) (AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld,
                                             @escaping @convention(block) (Any?, Error?) -> Void) -> Void

    /// `evaluateJavaScript(_:in:in:)` without a gesture: the value, or the error.
    func evaluateQuietly(_ script: String, in frame: WKFrameInfo? = nil, in world: WKContentWorld = .page,
                         done: (@MainActor (Result<Any?, Error>) -> Void)? = nil) {
        guard Self.quiet, responds(to: Self.quietSelector) else {
            evaluateJavaScript(script, in: frame, in: world) { result in done?(result.map { $0 as Any? }) }
            return
        }
        unsafeBitCast(method(for: Self.quietSelector), to: Quiet.self)(
            self, Self.quietSelector, script as NSString, false, nil, nil, false, frame, world) { value, error in
                MainActor.assumeIsolated { done?(error.map { .failure($0) } ?? .success(value)) }
            }
    }

    /// `callAsyncJavaScript(_:arguments:in:in:)` without a gesture: the
    /// body of an async function, its arguments named.
    func callAsyncQuietly(_ body: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil, in world: WKContentWorld = .page,
                          done: (@MainActor (Result<Any?, Error>) -> Void)? = nil) {
        guard Self.quiet, responds(to: Self.quietSelector) else {
            callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in done?(result.map { $0 as Any? }) }
            return
        }
        unsafeBitCast(method(for: Self.quietSelector), to: Quiet.self)(
            self, Self.quietSelector, body as NSString, true, nil, arguments as NSDictionary, false, frame, world) { value, error in
                MainActor.assumeIsolated { done?(error.map { .failure($0) } ?? .success(value)) }
            }
    }

    /// In the page's world, answered as `evaluateJavaScript(_:completionHandler:)` answers.
    func evaluateQuietly(_ script: String, done: @escaping @MainActor (Any?, Error?) -> Void) {
        evaluateQuietly(script, in: nil, in: .page) { result in
            switch result {
            case .success(let value): done(value, nil)
            case .failure(let error): done(nil, error)
            }
        }
    }
}

/// A click's activation kept through every script run in the page, not
/// only Yab's own.
///
/// Running Yab's reads quietly (above) covers the scripts Yab runs. Some
/// it can't: WebKit runs extensions' scripts in the page itself, with a
/// gesture (scripting.executeScript, content scripts injected late, the
/// storage guard Yab's shims put into each extension's world through it),
/// and a password manager or a shopping helper does that on a focus or a
/// press. One landing between a click's mouse-down and its release left
/// the click with no activation, and ChatGPT's Copy, which tries the
/// clipboard three ways, failed all three: "Couldn't copy to clipboard"
/// (register 1058). WebKit's own switch for bug 324512 stops the reset for
/// every script run in this view; where WebKit doesn't reset (macOS 26) it
/// changes nothing. evals/clipboard/sitecopy.py measures it.
/// YAB_KEEP_ACTIVATION=0 leaves it off, for an A/B.
extension WKWebView {
    private static let keepSelector = NSSelectorFromString("_setDontResetTransientActivationAfterRunJavaScript:")
    private static let keep = ProcessInfo.processInfo.environment["YAB_KEEP_ACTIVATION"] != "0"
    private typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void

    /// Whether this view now keeps a click's activation through scripts.
    @discardableResult
    func keepActivationThroughScripts() -> Bool {
        guard Self.keep, responds(to: Self.keepSelector) else { return false }
        unsafeBitCast(method(for: Self.keepSelector), to: SetFlag.self)(self, Self.keepSelector, true)
        return true
    }
}
