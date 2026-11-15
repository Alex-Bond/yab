import Foundation
import WebKit

/// Where the time of opening a tab goes, step by step, for the stand's
/// profile of it (docs/evidence/tab-open-2026-10-13.md). With YAB_OPEN_TRACE
/// set, each step is a line on standard error, "OPEN-TRACE <step> <ms since
/// 1970> <main-thread ms it took>", which the stand's page notes line up with.
/// Otherwise nothing.
enum OpenTrace {
    static let on = ProcessInfo.processInfo.environment["YAB_OPEN_TRACE"] != nil

    static func mark(_ step: String, took: Double? = nil) {
        guard on else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let line = "OPEN-TRACE \(step) \(String(format: "%.1f", now))" + (took.map { String(format: " %.1f", $0) } ?? "") + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    /// The work in `body`, timed on the main thread.
    static func time<T>(_ step: String, _ body: () -> T) -> T {
        guard on else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        let value = body()
        mark(step, took: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        return value
    }

    /// The page's content process, by pid, so a reused one tells from a new.
    static func process(_ web: WKWebView) -> String {
        let key = "_webProcessIdentifier"
        guard web.responds(to: NSSelectorFromString(key)) else { return "?" }
        return "\((web.value(forKey: key) as? Int32) ?? 0)"
    }

    /// Every stretch the main thread was busy for, from now for `ms`:
    /// "OPEN-TRACE busy <ms since 1970 it began> <ms it lasted>", 1 ms or
    /// more, to see what a navigation's IPC waits behind (round 11).
    static func watchBusy(_ ms: Double = 80) {
        guard on else { return }
        busyUntil = CFAbsoluteTimeGetCurrent() + ms / 1000
        guard busyObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                busySince = now
            } else if let since = busySince {
                busySince = nil
                let took = (now - since) * 1000
                guard since <= busyUntil, took >= 1 else { return }
                let began = (since + kCFAbsoluteTimeIntervalSince1970) * 1000
                FileHandle.standardError.write(String(format: "OPEN-TRACE busy %.1f %.1f\n", began, took).data(using: .utf8)!)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        busyObserver = observer
    }
    private nonisolated(unsafe) static var busyObserver: CFRunLoopObserver?
    private nonisolated(unsafe) static var busySince: CFAbsoluteTime?
    private nonisolated(unsafe) static var busyUntil: CFAbsoluteTime = 0

    /// The run loop's next turns after a move: the first is reached once
    /// the move's SwiftUI and Core Animation commit are done.
    static func turns(_ step: String) {
        guard on else { return }
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            mark("\(step).turn1", took: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            DispatchQueue.main.async {
                mark("\(step).turn2", took: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }
    }
}

/// Changes to what the window redraws on a tab's coming to front or a
/// link, each on unless YAB_NARROW_<NAME>=0, for an A/B on one build
/// (scripts/stand/open_ab.sh, docs/evidence/clean-gap-2026-10-13.md).
enum Narrow {
    static func on(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment["YAB_NARROW_" + name] != "0"
    }
    /// The window's body reads whether the tab in front can have
    /// Developer Tools only while they are out, not at every navigation.
    static let dev = on("DEV")
    /// Another app's copy is read off the main thread (Clips.look), not
    /// waited for there. YAB_NARROW_CLIP_READ=0 is the old way, for the
    /// eval's before (evals/clipboard/look.py).
    static let clipRead = on("CLIP_READ")
    /// A name's letters laid out once, not again at every repaint of the
    /// same name at another width (the strip's pills making room).
    static let inkMemo = on("INK_MEMO")
    /// A name's looks under the pointer and beside a ring painted only once
    /// they have been needed, not with every name from the start.
    static let inkLazy = on("INK_LAZY")
    /// The column's words on the site's color a gray of the site's light,
    /// not its hue (Tone.columnInk, feedback #186).
    static let columnInk = on("COLUMN_INK")
    /// The strip's names go to their new width at once when a tab opens,
    /// not with the pills at every frame of their slide.
    static let inkSnap = on("INK_SNAP")
    /// The menu bar reads the tab in front through MenuFront, a moment
    /// late, not the tab itself at every navigation.
    static let menu = on("MENU")
    /// Keys the menus hold with fn (fn F, full screen) pressed by the
    /// window's key monitor before the page's WebKit view takes them.
    /// YAB_NARROW_FN_MENU=0 is the old way, for the eval's before
    /// (evals/fullscreen-key, register #1693).
    static let fnMenu = on("FN_MENU")
    /// With MENU, the menu bar's other reads of the tab in front's address
    /// (Keep Tab's, the site's buttons) go through MenuFront too, so a
    /// link's start doesn't run the menu bar (round 11).
    static let menuAddress = menu && on("MENU_ADDRESS")
    /// "Blank?" and "Mail?" read off a tab's own values, written only when
    /// they change, not off its address (Tab.blankFlag, round 12).
    static let addressFlags = on("ADDRESS_FLAGS")
    /// The window's title follows the tab in front a moment late.
    static let title = on("TITLE")
    /// The ring and Stop show a load only once it has gone on a moment.
    static let ring = on("RING")
    /// A switch whose page is on the stage early writes the rest (the tab
    /// in front, SwiftUI's redraw) after the page's first frame there.
    static let deferSwitch = on("DEFER_SWITCH")
    /// ⌘W puts the next page on the stage, from its last frame, before the
    /// closed page is torn down and the switch is written (Browser.close).
    static let closeFirst = on("CLOSE_FIRST")
    /// Back and Forward show the page's last frame at once, kept from when
    /// it was left, until the page draws.
    static let backStills = on("BACK_STILLS")
    /// A tab opened in front goes on the stage at once, under the page
    /// shown until its own document has drawn; the window's redraw for it
    /// (the row, the bar: 40-60 ms of main thread on adhd) is written after
    /// the page's next frames, not while they wait for the thread.
    /// YAB_NARROW_OPEN_FIRST=N waits N of the page's frames after it is
    /// shown (2 by default); 0 turns it off.
    static let openFirstFrames = Int(ProcessInfo.processInfo.environment["YAB_NARROW_OPEN_FIRST"] ?? "") ?? 2
    static var openFirst: Bool { openFirstFrames > 0 }
    /// With OPEN_FIRST, the new tab's row too waits for the page's frames
    /// (kept among the window's tabs outside the row meanwhile): adding it
    /// redraws the strip or the column.
    static let openLateRow = on("OPEN_LATE_ROW")
    /// A navigation's changes to what the window draws wait for the page's
    /// first frame after it commits (Tab.held). Off unless
    /// YAB_NARROW_HOLD_NAV=1: three rounds moved Back and Forward a few ms
    /// sooner in some profiles and nothing else past the noise
    /// (docs/evidence/clean-gap-2026-10-13.md, round 6).
    static let holdNav = ProcessInfo.processInfo.environment["YAB_NARROW_HOLD_NAV"] == "1"
    /// The window's body reads the tab in front only in the leaves that
    /// draw it (LiveLeaf), not in its own body. Off unless
    /// YAB_NARROW_LEAVES=1: it took ContentView's body out of every switch
    /// and link, but the stand's times moved no further than their noise,
    /// some up, some down (docs/evidence/clean-gap-2026-10-13.md, round 3).
    static let leaves = ProcessInfo.processInfo.environment["YAB_NARROW_LEAVES"] == "1"
    /// A navigation's writes to what the window draws wait until WebKit's
    /// question about its response is answered (or it commits or fails),
    /// so that question isn't queued behind them on the main thread
    /// (Tab.quietUntilAnswered, round 11). Off unless YAB_NARROW_QUIET_START=1:
    /// DOM ready came at Chrome's time, but the 13-20 ms of the window's
    /// update only moved behind the commit, and the first frame didn't
    /// come sooner (farms fc7eca11, 3efcd989, 7958e688).
    static let quietStart = ProcessInfo.processInfo.environment["YAB_NARROW_QUIET_START"] == "1"
    /// The longest QUIET_START holds, for a server slow to answer:
    /// YAB_NARROW_QUIET_MS, 60 by default.
    static let quietFor = (Double(ProcessInfo.processInfo.environment["YAB_NARROW_QUIET_MS"] ?? "") ?? (quietUntilFrame ? 150 : 60)) / 1000
    /// QUIET_START lets go after the page's first frame from its commit,
    /// not once its response is answered: YAB_NARROW_QUIET_UNTIL=frame.
    static let quietUntilFrame = ProcessInfo.processInfo.environment["YAB_NARROW_QUIET_UNTIL"] == "frame"
    /// Another browser's sign-ins go into WebKit's store off the main
    /// thread where they can, and a few milliseconds of it at a time where
    /// they can't (CookiePour, crash #60). YAB_NARROW_COOKIE_POUR=0 pours
    /// them as before, for evals/cookie-import's before.
    static let cookiePour = on("COOKIE_POUR")
    /// With COOKIE_POUR, macOS 26's setCookies of a few hundred at once;
    /// YAB_NARROW_COOKIE_BULK=0 sends one a message, as before macOS 26.
    static let cookieBulk = on("COOKIE_BULK")
}

/// Why WebKit keeps a page out of its back-forward cache, on standard
/// error, with YAB_BF_TRACE set: WebKit's own diagnostic messages
/// (`_WKDiagnosticLoggingDelegate`), "BF-TRACE <message> <description>".
/// A bare WKWebView keeps every page; Yab's Back loaded the page again.
@MainActor
final class BFTrace: NSObject {
    static let on = ProcessInfo.processInfo.environment["YAB_BF_TRACE"] != nil
    static let shared = BFTrace()

    static func prepare(_ configuration: WKWebViewConfiguration) {
        guard on else { return }
        configuration.preferences.setValue(true, forKey: "diagnosticLoggingEnabled")
    }

    static func attach(_ web: WKWebView) {
        guard on else { return }
        let setter = NSSelectorFromString("_setDiagnosticLoggingDelegate:")
        if web.responds(to: setter) { web.perform(setter, with: shared) }
    }

    private func say(_ parts: [Any?]) {
        let line = "BF-TRACE " + parts.map { "\($0 ?? "-")" }.joined(separator: " ") + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    @objc(_webView:logDiagnosticMessage:description:)
    func log(_ web: WKWebView, message: String, description: String) { say([message, description]) }

    @objc(_webView:logDiagnosticMessageWithResult:description:result:)
    func log(_ web: WKWebView, result message: String, description: String, result: Int) { say([message, description, result]) }

    @objc(_webView:logDiagnosticMessageWithValue:description:value:)
    func log(_ web: WKWebView, value message: String, description: String, value: String) { say([message, description, value]) }

    @objc(_webView:logDiagnosticMessageWithEnhancedPrivacy:description:)
    func log(_ web: WKWebView, private message: String, description: String) { say([message, description]) }
}

/// The page's Navigation API (`window.navigation`) off, for an A/B only
/// (YAB_NAVIGATION_API=0): restoring a page from the back-forward cache,
/// WebKit asks the window's process for every entry of the tab's history,
/// one synchronous message each (CachedPage::restoreNavigationAPIHistoryItems,
/// WebBackForwardListProxy::itemAtIndex), 13 ms a Back on the stand.
enum NavigationAPI {
    static func off(_ preferences: WKPreferences) { WebFeature.set("NavigationAPIEnabled", false, in: preferences) }
}

/// One of WebKit's feature flags (WKPreferences' private `_features`, the
/// list Safari's Feature Flags shows), set by its key. False when this
/// WebKit has no such flag.
enum WebFeature {
    @discardableResult
    static func set(_ key: String, _ on: Bool, in preferences: WKPreferences) -> Bool {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard preferences.responds(to: set), let feature = features.first(where: { ($0.value(forKey: "key") as? String) == key }),
              let method = class_getInstanceMethod(WKPreferences.self, set) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, set, on, feature)
        return true
    }

    static func isOn(_ key: String, in preferences: WKPreferences) -> Bool? {
        let get = NSSelectorFromString("_isEnabledForFeature:")
        guard preferences.responds(to: get), let feature = features.first(where: { ($0.value(forKey: "key") as? String) == key }),
              let method = class_getInstanceMethod(WKPreferences.self, get) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(preferences, get, feature)
    }

    /// The flags YAB_WEBKIT_FLAGS names, comma separated, KEY for on and
    /// KEY=0 for off: how evals/webkit-gaps tries one of WebKit's flags in
    /// Yab before anything ships it. Test runs only (Tab.swift).
    static func fromEnvironment(_ preferences: WKPreferences) {
        guard let list = ProcessInfo.processInfo.environment["YAB_WEBKIT_FLAGS"] else { return }
        for item in list.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = parts.first, !key.isEmpty else { continue }
            set(key, parts.count < 2 || parts[1] != "0", in: preferences)
        }
    }

    /// Read once: WebKit's list doesn't change while it runs.
    nonisolated(unsafe) private static let features: [NSObject] = {
        let list = NSSelectorFromString("_features")
        guard WKPreferences.responds(to: list) else { return [] }
        return WKPreferences.perform(list)?.takeUnretainedValue() as? [NSObject] ?? []
    }()
}
