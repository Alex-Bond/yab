import AppKit
import WebKit

// A window an extension opens for a page of its own, as Chrome opens one for
// chrome.windows.create with type "popup": Bitwarden's passkey prompt, its
// item and vault pop-outs. A small window, focused, where the extension asked
// for it, with nothing in it but the page.
//
// yab opens no window for an extension's ordinary windows.create, whose pages
// become tabs in the window in front (Extensions). This one can't: the
// extension keeps it by the window's id. Bitwarden opens its passkey prompt
// for each request, finds it again with tabs.query by its address, closes it
// with windows.remove, and takes windows.onRemoved for "no, the browser's
// own". As a tab it was none of those: it had the browser's window id, an
// address of yab's popup copy (Extensions.popupCopy), and WebKit wouldn't let
// it close itself, so each passkey request left another Bitwarden tab, six
// on one sign-in (a tester, 8 Oct 2026).
//
// Its page's window.close() closes it, as Chrome lets an extension's page
// close itself whatever its history (allow_scripts_to_close_windows).

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopout: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    /// Open ones, oldest first.
    private(set) static var open: [ExtensionPopout] = []

    let window: NSWindow
    let web: WKWebView
    let extensionID: String
    /// What WebKit knows it as: the window and the one tab in it.
    let frame = PopoutWindow()
    let page = PopoutTab()
    /// The extension's own origin: the only one whose window.close() is
    /// carried here.
    private let base: URL
    private var closeToken: String?
    private var titled: NSKeyValueObservation?
    private var closed = false
    /// The controller its extension is loaded in, Yab's own but for a test's.
    private weak var owner: WKWebExtensionController?
    var controller: WKWebExtensionController { owner ?? Extensions.shared.controller }

    static let closeHandler = "yabExtensionPopoutClose"
    private static let router = CloseRouter()

    static func owning(_ window: NSWindow?) -> ExtensionPopout? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    static func owning(page web: WKWebView?) -> ExtensionPopout? {
        guard let web else { return nil }
        return open.first { $0.web === web }
    }

    /// Whether a windows.create is one of these: a popup with one page, the
    /// extension's own. A site in a popup still becomes a tab, with all a
    /// tab has (its sign-ins, passwords, blocking), as does a window moving
    /// tabs that are already open.
    ///
    /// A "panel", which Chrome opens as a popup, WebKit reads as "normal"
    /// (and an extension's script can't change that on the way: WebKit's
    /// windows.create can't be written over). LINE opens its whole app so,
    /// one page of its own at 800 × 580, and keeps the window's id: as a
    /// tab it had the browser's window, a second press only brought that
    /// forward, and closing the tab never told LINE its window was gone, so
    /// the button did nothing from then on (#395). A normal window asked
    /// for at a size of its own, for one page of the extension's, is a
    /// window of its own too: what Chrome draws for it.
    static func wanted(_ configuration: WKWebExtension.WindowConfiguration, for context: WKWebExtensionContext) -> URL? {
        let sized = configuration.frame.width.isFinite && configuration.frame.width > 0
            && configuration.frame.height.isFinite && configuration.frame.height > 0
        guard configuration.windowType == .popup || (configuration.windowType == .normal && sized),
              configuration.tabs.isEmpty, configuration.tabURLs.count == 1,
              let url = configuration.tabURLs.first.map(Extensions.current),
              url.scheme == context.baseURL.scheme, url.host == context.baseURL.host
        else { return nil }
        return url
    }

    /// Opened, told to WebKit and loading; nil when the extension has no
    /// configuration for a page.
    static func present(_ url: URL, for context: WKWebExtensionContext, configuration: WKWebExtension.WindowConfiguration,
                     over parent: NSWindow?) -> ExtensionPopout? {
        guard let views = context.webViewConfiguration else { return nil }
        PasskeyRelay.install(in: views.userContentController)
        // The page's EyeDropper in its pages (EyeDropper.swift).
        EyeDropperRelay.install(in: views.userContentController)
        let popout = ExtensionPopout(context: context, configuration: views)
        open.append(popout)
        popout.controller.didOpenWindow(popout.frame)
        popout.controller.didOpenTab(popout.page)
        popout.window.setFrame(place(configuration.frame, over: parent), display: false)
        if configuration.shouldBeFocused {
            NSApp.activate()
            popout.window.makeKeyAndOrderFront(nil)
        } else {
            popout.window.orderFront(nil)
        }
        // From yab's popup copy, which an extension's page needs to be sent
        // its events (Extensions.popupCopy); WebKit is told the address asked for.
        popout.web.load(URLRequest(url: Browser.page(url)))
        if Store.testing {
            let asked = configuration.frame, made = popout.window.frame
            FileHandle.standardError.write(Data("YAB_EXTENSION_POPOUT open window=\(popout.window.windowNumber) asked=\([asked.minX, asked.minY, asked.width, asked.height]) frame=\([made.minX, made.minY, made.width, made.height])\n".utf8))
        }
        return popout
    }

    /// Where the extension asked, in the screen's coordinates (WebKit has
    /// turned Chrome's top-left ones round), whatever it left out taken
    /// from the top right of the window it came from, and kept on the screen.
    private static func place(_ asked: CGRect, over parent: NSWindow?) -> NSRect {
        let width = asked.width.isFinite && asked.width > 0 ? asked.width : 380
        let height = asked.height.isFinite && asked.height > 0 ? asked.height : 600
        let from = parent?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var rect = NSRect(x: asked.minX.isFinite ? asked.minX : from.maxX - width - 15,
                          y: asked.minY.isFinite ? asked.minY : from.maxY - 90 - height,
                          width: width, height: height)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? parent?.screen ?? NSScreen.main
        if let room = screen?.visibleFrame {
            rect.size.width = min(max(rect.width, 240), room.width)
            rect.size.height = min(max(rect.height, 200), room.height)
            rect.origin.x = min(max(rect.minX, room.minX), room.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, room.minY), room.maxY - rect.height)
        }
        return rect.integral
    }

    private init(context: WKWebExtensionContext, configuration: WKWebViewConfiguration) {
        extensionID = context.uniqueIdentifier
        base = context.baseURL
        owner = context.webExtensionController
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        AppleWritingTools.configure(configuration)
        web = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
        super.init()
        frame.popout = self
        page.popout = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Over a browser window in full screen, as the prompt it is.
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.minSize = NSSize(width: 240, height: 200)
        // White behind the page until it paints, as Chrome's popup window.
        window.backgroundColor = .white
        window.title = context.webExtension.displayName ?? ""
        window.delegate = self
        web.autoresizingMask = [.width, .height]
        web.uiDelegate = self
        web.navigationDelegate = self
        window.contentView = web
        titled = web.observe(\.title, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let title = web.title, !title.isEmpty else { return }
                self.window.title = title
            }
        }
        // Extension pages share their controller: the one router answers
        // every popout's close, by the page it comes from.
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.closeHandler)
        controller.add(Self.router, name: Self.closeHandler)
        Self.listen()
    }

    /// Gone, for good: WebKit is told, and the extension hears
    /// windows.onRemoved, the way it does when Chrome's closes.
    /// `closing`: the window is already on its way, closed by hand.
    func close(closing: Bool = false) {
        guard !closed else { return }
        closed = true
        closeToken = nil
        titled = nil
        Self.open.removeAll { $0 === self }
        controller.didCloseTab(page, windowIsClosing: true)
        controller.didCloseWindow(frame)
        if Store.testing {
            FileHandle.standardError.write(Data("YAB_EXTENSION_POPOUT closed window=\(window.windowNumber)\n".utf8))
        }
        window.delegate = nil
        if !closing { window.close() }
        web.stopLoading()
        Extensions.all.forEach { $0.focusChanged() }
    }

    /// Every one an extension has open, as it goes.
    /// `in`: only the ones of that controller, one sign-in's.
    static func close(extension id: String, in controller: WKWebExtensionController? = nil) {
        for popout in open where popout.extensionID == id && (controller == nil || popout.controller === controller) { popout.close() }
    }

    func focus() {
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - its window

    func windowWillClose(_ notification: Notification) { close(closing: true) }

    func windowDidBecomeKey(_ notification: Notification) {
        controller.didFocusWindow(frame)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Once the next window is key.
        DispatchQueue.main.async { Extensions.shared.focusChanged() }
    }

    /// ⌘W closes it, here and not in the browser: the menu's close is the
    /// browser's tab's.
    private static var keys: Any?
    private static func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let popout = owning(event.window), Keymap.shared.action(for: event)?.action == .closeTab else { return event }
            popout.window.performClose(nil)
            return nil
        }
    }

    // MARK: - its page

    /// The page's window.close(), carried here (ExtensionPopup.closeBridge):
    /// WebKit refuses it to a page with more than one history entry, and a
    /// page routed by its hash, Bitwarden's #/fido2, always has more.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard let url = webView.url, url.scheme == base.scheme, url.host == base.host,
              let scheme = base.scheme, let host = base.host else { return }
        let token = UUID().uuidString
        guard let source = ExtensionPopup.closeBridge(scheme: scheme, host: host, token: token, handler: Self.closeHandler) else { return }
        closeToken = token
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        closeToken = nil
    }

    fileprivate func closeAsked(_ message: WKScriptMessage) {
        guard let token = closeToken, ExtensionPopup.acceptsClose(
            body: message.body, token: token, mainFrame: message.frameInfo.isMainFrame,
            scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host, base: base)
        else { return }
        // Out of WebKit's callback before telling it the window closed; a
        // page loaded since has another token.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.closeToken == token else { return }
            if Store.testing {
                FileHandle.standardError.write(Data("YAB_EXTENSION_POPOUT script-close window=\(self.window.windowNumber)\n".utf8))
            }
            self.close()
        }
    }

    func webViewDidClose(_ webView: WKWebView) { close() }

    /// A link to a new window goes to a tab in the browser in front, as one
    /// from Chrome's popup window goes to its last ordinary window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            (Extensions.all.first { $0.controller === controller } ?? .shared).opening()?.open(url, foreground: true)
        }
        return nil
    }
}

/// The popout's page's window.close(), to the popout showing it.
@available(macOS 15.4, *)
@MainActor
private final class CloseRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == ExtensionPopout.closeHandler,
                  let popout = ExtensionPopout.owning(page: message.webView) else { return }
            popout.closeAsked(message)
        }
    }
}

/// The popout as WebKit knows a window: a popup, with its one page.
@available(macOS 15.4, *)
@MainActor
final class PopoutWindow: NSObject, WKWebExtensionWindow {
    fileprivate(set) weak var popout: ExtensionPopout?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { popout.map { [$0.page] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { popout?.page }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = popout?.window else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }

    func frame(for context: WKWebExtensionContext) -> CGRect { popout?.window.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        popout?.window.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard let window = popout?.window, frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite else { return }
        window.setFrame(frame.integral, display: true)
    }

    func focus(for context: WKWebExtensionContext) async throws { popout?.focus() }
    func close(for context: WKWebExtensionContext) async throws { popout?.close() }
}

/// The popout's page as WebKit knows a tab.
@available(macOS 15.4, *)
@MainActor
final class PopoutTab: NSObject, WKWebExtensionTab {
    fileprivate(set) weak var popout: ExtensionPopout?

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { popout?.frame }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { popout == nil ? NSNotFound : 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { popout?.web }
    func title(for context: WKWebExtensionContext) -> String? { popout?.web.title }
    /// The address the extension opened, not yab's popup copy of it.
    func url(for context: WKWebExtensionContext) -> URL? { popout?.web.url.map(Extensions.popped) }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(popout?.web.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { popout != nil }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        popout?.web.load(URLRequest(url: Browser.page(url)))
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin { popout?.web.reloadFromOrigin() } else { popout?.web.reload() }
    }
    func goBack(for context: WKWebExtensionContext) async throws { popout?.web.goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { popout?.web.goForward() }
    func activate(for context: WKWebExtensionContext) async throws { popout?.focus() }
    func close(for context: WKWebExtensionContext) async throws { popout?.close() }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext) async throws -> NSImage? {
        guard let web = popout?.web else { return nil }
        return try await web.takeSnapshot(configuration: configuration)
    }
}
