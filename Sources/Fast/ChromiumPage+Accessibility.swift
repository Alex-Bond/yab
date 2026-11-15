import AppKit
import YabCoreClient

/// AppKit's own bridge for an element that lives in another process. It is
/// how Chromium shows a page to VoiceOver from an app shim; private, and read
/// with care so a macOS without it only leaves the page unread.
@MainActor
final class ChromiumRemoteAccessibility {
    private(set) var element: NSObject?
    private var asked = false
    private var helper: pid_t = 0
    /// An assistive client has read a page. From then on every page has its
    /// tree, those open then and those attached later, as Chromium's accessibility, once a client
    /// reaches web content, is on for the whole process
    /// (BrowserAccessibilityState::CreateScopedModeForProcess): a tab opened
    /// or first shown later is there for a hint key's first press, not its
    /// second, since such apps walk once and ask nothing before.
    private(set) static var engaged = false

    /// Application-level AX client detection also covers pages opened later.
    static func engage() {
        engaged = true
        for page in ChromiumProcess.shared.livePages { page.accessibilityAttached() }
    }

    private static let bridge: AnyClass? = NSClassFromString("NSAccessibilityRemoteUIElement")
    nonisolated(unsafe) private static let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    static func remote(token: Data, presenter: pid_t) -> NSObject? {
        guard let bridge, let send else { return nil }
        typealias Register = @convention(c) (AnyClass, Selector, Int32) -> Void
        typealias Allocate = @convention(c) (AnyClass, Selector) -> UnsafeRawPointer?
        typealias Make = @convention(c) (UnsafeRawPointer, Selector, NSData) -> Unmanaged<NSObject>?
        unsafeBitCast(send, to: Register.self)(bridge, NSSelectorFromString("registerRemoteUIProcessIdentifier:"), presenter)
        // Raw, so ARC keeps out of init's taking over of alloc's reference.
        guard let blank = unsafeBitCast(send, to: Allocate.self)(bridge, NSSelectorFromString("alloc")) else { return nil }
        return unsafeBitCast(send, to: Make.self)(blank, NSSelectorFromString("initWithRemoteToken:"), token as NSData)?.takeRetainedValue()
    }

    /// This view as a token the helper can open, for the way up from the page.
    private static func token(for view: NSView) -> String {
        guard let bridge, let send else { return "" }
        typealias Token = @convention(c) (AnyClass, Selector, AnyObject) -> Unmanaged<NSData>?
        let data = unsafeBitCast(send, to: Token.self)(bridge, NSSelectorFromString("remoteTokenForLocalUIElement:"), view)?.takeUnretainedValue()
        return (data as Data?)?.base64EncodedString() ?? ""
    }

    func request(_ page: ChromiumPage) {
        guard !asked, element == nil else { return }
        asked = true
        Task { @MainActor [weak self, weak page] in
            defer { self?.asked = false }
            guard let page, !page.retired, page.remoteID != nil,
                  let reply = try? await page.navigationRequest("tab.accessibility", ["client": .number(Double(getpid())),
                                                                                      "parent": .string(Self.token(for: page))]),
                  let self, case .object(let fields) = reply,
                  let token = fields["token"]?.string.flatMap({ Data(base64Encoded: $0) }),
                  let pid = fields["pid"]?.number else { return }
            guard let remote = Self.remote(token: token, presenter: pid_t(pid)) else { return }
            remote.setValue(page.window, forKey: "windowUIElement")
            remote.setValue(page.window, forKey: "topLevelUIElement")
            self.helper = pid_t(pid)
            self.element = remote
            if Store.testing, ProcessInfo.processInfo.environment["YAB_PROBE"] != nil {
                NSLog("YAB_AX tree of %@ at %.3f", page.remoteID ?? "-", Date().timeIntervalSince1970)
            }
            if !Self.engaged {
                // Pages already open (a tab made ahead for the next one,
                // tabs behind) are read from now on too, as Chromium's mode
                // covers the web contents it already has.
                Self.engaged = true
                for other in ChromiumProcess.shared.livePages where other !== page { other.accessibilityAttached() }
            }
            // Frames in the tree come from the hidden window, which follows the
            // page wherever it shows (ChromiumPage.placeProducer).
            page.placeProducer()
            NSAccessibility.post(element: page, notification: .layoutChanged)
            page.accessibilityFocusMoved()
        }
    }

    /// The helper went away. A document of another site, which has a view of
    /// its own, needs nothing here: the helper's element for the tab answers
    /// with the view of the moment (accessibility.inc).
    func reset() {
        element = nil; asked = false; helper = 0
    }
}

extension ChromiumPage {
    /// The page has its tab in the helper: its tree is asked for now if an
    /// assistive client has read pages before (`engaged`).
    func accessibilityAttached() {
        if ChromiumRemoteAccessibility.engaged { remoteAccessibility.request(self) }
    }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        guard let element = remoteAccessibility.element else {
            if Store.testing, ProcessInfo.processInfo.environment["YAB_PROBE"] != nil {
                NSLog("YAB_AX children asked before the tree of %@ at %.3f", remoteID ?? "-", Date().timeIntervalSince1970)
            }
            remoteAccessibility.request(self)
            return super.accessibilityChildren()
        }
        return [element]
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        remoteAccessibility.element ?? super.accessibilityHitTest(point)
    }
    /// Dictation and completion apps (Willow, Raycast, Cotypist) ask Yab for
    /// its focused element and type into it with AXSelectedText. The page's
    /// element is in YabCore: AppKit carries the question on to that
    /// process's application, which answers with the focused web field, as
    /// Chromium's app shims and WebKit's web process do. Before the tree is
    /// built this view answers for itself, as Chromium answers nil until its
    /// tree is on; the tree is asked for, and the change posted when it comes.
    override var accessibilityFocusedUIElement: Any? {
        if Store.testing, ProcessInfo.processInfo.environment["YAB_PROBE"] != nil {
            NSLog("YAB_AX focus asked: tree %d, first responder %d", remoteAccessibility.element != nil ? 1 : 0, window?.firstResponder === self ? 1 : 0)
        }
        guard let element = remoteAccessibility.element else {
            remoteAccessibility.request(self)
            return super.accessibilityFocusedUIElement
        }
        return element
    }

    /// The page's focused field changed: clients that follow the app's focus
    /// (Cotypist) ask again. Chromium posts its own change in YabCore, where
    /// no client of Yab listens.
    func accessibilityFocusMoved() {
        guard remoteAccessibility.element != nil, window?.firstResponder === self else { return }
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }
}
