import AppKit
import WebKit
import YabCoreClient

/// A page-created document window. Unlike Floater, this holds a second live
/// document whose DOM remains accessible to the page that opened it.
@MainActor
final class DocumentPiP: NSObject, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    static let marker = "__yab_document_pip"
    static let resizeHandler = "documentPiP"

    private static var live: [DocumentPiP] = []
    private static var placements: [Tab.ID: NSRect] = [:]
    private static var placementOrder: [Tab.ID] = []
    private static var keys: Any?
    private static let tracing = ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1"

    weak var source: Tab?
    private weak var browser: Browser?
    private(set) var web: WKWebView?
    private(set) var panel: NSPanel?
    private var chromiumChild: Tab?
    var showing: Bool { web != nil || chromiumChild != nil }
    /// The window's own page on Chromium, for the bench.
    var chromiumPage: ChromiumPage? { chromiumChild?.builtPage as? ChromiumPage }

    private var request: URL?
    private var bootstrapping = false
    private var closing = false
    private var released = false
    private var epoch = 0
    private var returnButton: NSTitlebarAccessoryViewController?
    /// What the page asked for. Only Chrome's window knows it, and it comes
    /// once, before or after the panel is up.
    private var askedSize: NSSize?

    private func trace(_ event: String, extra: [String: Any] = [:], caller: Bool = false) {
        guard Self.tracing else { return }
        var record: [String: Any] = [
            "event": event, "time": ProcessInfo.processInfo.systemUptime,
            "manager": String(describing: ObjectIdentifier(self)), "epoch": epoch,
            "source": source?.id.uuidString ?? "", "request": request?.absoluteString ?? "",
            "web": web.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "url": web?.url?.absoluteString ?? "", "panel": panel?.windowNumber ?? 0,
            "bootstrapping": bootstrapping, "closing": closing, "released": released,
        ]
        record.merge(extra) { _, value in value }
        if caller { record["caller"] = Array(Thread.callStackSymbols.dropFirst(1).prefix(8)) }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(Data("YAB_DOCUMENT_PIP_TRACE ".utf8) + data + Data("\n".utf8))
    }

    static func isRequest(_ url: URL?) -> Bool {
        guard let url = canonical(url), url.scheme?.lowercased() == "about", url.path == "blank",
              let token = options(url)[marker], !token.isEmpty else { return false }
        return true
    }

    /// WebKit's NSURL bridge can escape the delimiter of an opaque about
    /// URL even though the child Window reports the ordinary fragment URL.
    /// Normalize only that exact about:blank representation, not URL data.
    ///
    /// Read again from its text first: a URL bridged from WebKit's NSURL
    /// (a navigation action's request) answers an empty path and no
    /// fragment for an opaque about: URL, where one made from the same text
    /// has "blank" and the marker. Every request WebKit sent was taken for
    /// an ordinary window and opened as a tab.
    static func canonical(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let parsed = URL(string: url.absoluteString) ?? url
        let prefix = "about:blank%23"
        guard parsed.fragment == nil, parsed.absoluteString.hasPrefix(prefix) else { return parsed }
        return URL(string: "about:blank#" + String(parsed.absoluteString.dropFirst(prefix.count))) ?? parsed
    }

    static func excluded(_ url: URL?) -> Bool {
        Players.knows(url) || CallLink.isCall(url)
    }

    static func owning(page: WKWebView) -> DocumentPiP? {
        live.first { $0.web === page }
    }

    static func owning(_ window: NSWindow?) -> DocumentPiP? {
        guard let window else { return nil }
        return live.first { $0.panel === window }
    }

    @discardableResult
    static func closeKeyWindow() -> Bool {
        guard let document = owning(NSApp.keyWindow) else { return false }
        document.close()
        return true
    }

    static func owner(of page: WKWebView) -> Tab? {
        owning(page: page)?.source
    }

    private static func options(_ url: URL?) -> [String: String] {
        guard let fragment = canonical(url)?.fragment,
              fragment.hasPrefix(marker + "="),
              let pieces = URLComponents(string: "https://invalid.local/?" + fragment)?.queryItems else { return [:] }
        var result: [String: String] = [:]
        for piece in pieces where result[piece.name] == nil { result[piece.name] = piece.value ?? "" }
        return result
    }

    private static func listen() {
        guard keys == nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let document = owning(event.window) else { return event }
            return document.take(event) ? nil : event
        }
    }

    /// Closing this window must not fall through to the browser's tab menu.
    /// Editing and every other shortcut keep their normal responder path.
    func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let panel, event.window === panel,
              Keymap.shared.matches(event, .closeTab) || Keymap.shared.matches(event, .closeWindow) else { return false }
        close()
        return true
    }

    /// WebKit loads its initial about:blank document after this returns.
    /// Its supplied configuration is what preserves access from the opener.
    func open(configuration: WKWebViewConfiguration, action: WKNavigationAction, request navigationRequest: URLRequest? = nil,
              features: WKWindowFeatures, source: Tab, browser: Browser) -> WKWebView? {
        let navigationRequest = navigationRequest ?? action.request
        trace("open_attempt", extra: [
            "action_url": navigationRequest.url?.absoluteString ?? "", "source": source.id.uuidString,
            "source_url": (source.webKitOnly("WebKit document PiP callbacks", build: false)?.url ?? RelayGuard.top(of: source))?.absoluteString ?? "",
            "frame_origin": "\(action.sourceFrame.securityOrigin.protocol)://\(action.sourceFrame.securityOrigin.host):\(action.sourceFrame.securityOrigin.port)",
            "frame_main": action.sourceFrame.isMainFrame,
        ])
        guard Self.isRequest(navigationRequest.url), !showing, source.webKitOnly("WebKit document PiP callbacks", build: false) != nil,
              action.sourceFrame.isMainFrame,
              Self.matches(action.sourceFrame.securityOrigin, url: source.webKitOnly("WebKit document PiP callbacks", build: false)?.url ?? RelayGuard.top(of: source)),
              !source.asleep, !source.floating, !source.onCall, !Self.excluded(source.address) else {
            trace("open_declined", extra: [
                "request_valid": Self.isRequest(navigationRequest.url), "has_child": web != nil,
                "source_built": source.webKitOnly("WebKit document PiP callbacks", build: false) != nil, "frame_main": action.sourceFrame.isMainFrame,
                "origin_matches": Self.matches(action.sourceFrame.securityOrigin, url: source.webKitOnly("WebKit document PiP callbacks", build: false)?.url ?? RelayGuard.top(of: source)),
                "asleep": source.asleep, "floating": source.floating, "on_call": source.onCall,
                "excluded": Self.excluded(source.address),
            ])
            return nil
        }
        self.source = source
        self.browser = browser
        request = Self.canonical(navigationRequest.url)
        released = false
        closing = false
        bootstrapping = true
        epoch += 1

        // An opener's controller is shared by the configuration WebKit gives
        // us. A document window must never take its handlers off the opener.
        let controller = WKUserContentController()
        configuration.userContentController = controller
        LocalNetwork.protect(controller)
        controller.add(self, contentWorld: Web.world, name: Self.resizeHandler)
        controller.addUserScript(WKUserScript(source: Self.resizeBridge, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: Web.world))
        configuration.preferences = Self.withoutFullscreen(configuration.preferences)

        AppleWritingTools.configure(configuration)
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.uiDelegate = browser
        page.navigationDelegate = self
        page.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { page.isInspectable = true }
        web = page

        present(page, source: source, title: Self.originLabel(action.sourceFrame.securityOrigin),
                width: Self.dimension(features.width, fallback: 480), height: Self.dimension(features.height, fallback: 320),
                preferences: Self.options(navigationRequest.url))
        trace("open_accepted")
        return page
    }

    /// Adopt the actual native PiP child. The helper's native disposition
    /// authenticates its type; an about:blank URL never authorizes a panel.
    ///
    /// Calls and known players are not refused here as `open` refuses them on
    /// WebKit. There the API is Yab's own script, withheld from those sites so
    /// they keep their fallbacks. Chromium's is always there and has already
    /// handed the page its window: refusing closes it under the page, which
    /// is how Meet's floating window died 30 ms after it opened.
    func openChromium(_ event: YabCoreEvent, source: Tab, browser: Browser) -> Bool {
        trace("chromium_open_attempt", extra: [
            "receipt": String(describing: event.params), "showing": showing,
            "source_url": source.builtPage?.url?.absoluteString ?? "",
        ])
        guard !showing, !source.gone, !source.asleep, !source.floating,
              let parent = source.builtPage as? ChromiumPage,
              let id = event.tab, let parentID = parent.remoteID, event.params["opener"] == .string(parentID),
              event.params["creationPurpose"] == .string("popup"),
              event.params["profile"] == .string(parent.profile),
              event.params["private"] == .bool(source.shy),
              let receipt = event.params["source"]?.object,
              receipt["documentPiP"] == .bool(true), receipt["main"] == .bool(true),
              receipt["gesture"] == .bool(true),
              let origin = receipt["url"]?.string.flatMap(URL.init(string:)),
              let current = parent.committedURL ?? parent.url,
              Self.sameOrigin(origin, current) else { return false }
        let child = Tab(shy: source.shy, bench: source.bench, engine: .chromium)
        child.delegate = browser
        guard let page = child.prepareChromiumPageForAdoption(profile: parent.profile) else { child.close(); return false }
        // The child is retained here, never inserted into a sidebar or parked
        // space. Keep its live WebContents and opener relationship intact.
        page.events = nil
        page.stateEvents = nil
        self.source = source; self.browser = browser
        released = false; closing = false; epoch += 1
        askedSize = nil
        chromiumChild = child
        page.onDocumentClosed = { [weak self] in self?.didClose() }
        page.onDocumentSize = { [weak self] size in self?.asked(size) }
        page.autoresizingMask = [.width, .height]
        page.adoptRemote(id)
        // attach() drains early native events, including a child that closed
        // while tab.adopt was in flight. Never resurrect that panel.
        guard chromiumChild === child else { return true }
        func size(_ key: String, fallback: CGFloat) -> CGFloat {
            guard let value = receipt[key]?.number, value.isFinite, value > 0 else { return fallback }
            return CGFloat(value)
        }
        trace("chromium_open_accepted", extra: ["native_child": id])
        present(page, source: source, title: origin.host ?? "Local document",
                width: askedSize?.width ?? size("width", fallback: 480),
                height: askedSize?.height ?? size("height", fallback: 320), preferences: [:])
        return true
    }

    /// Takes the size from the bottom right corner it opened at. A window the
    /// person has placed stays as they left it.
    private func asked(_ size: NSSize) {
        askedSize = size
        guard let panel, let source, Self.placements[source.id] == nil else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let corner = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        panel.setContentSize(clamped(size, in: visible))
        var frame = panel.frame
        frame.origin = NSPoint(x: corner.x - frame.width, y: corner.y)
        panel.setFrame(Self.fitted(frame, in: visible), display: true)
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let scheme = first.scheme?.lowercased(), ["https", "http"].contains(scheme),
              scheme == second.scheme?.lowercased(),
              let host = first.host, !host.isEmpty, bareHost(host) == bareHost(second.host ?? "") else { return false }
        let standard = scheme == "https" ? 443 : 80
        return (first.port ?? standard) == (second.port ?? standard)
    }

    private func present(_ content: NSView, source: Tab, title: String,
                         width: CGFloat, height: CGFloat, preferences: [String: String]) {
        let screen = source.builtPage?.window?.screen
            ?? browser.flatMap { BrowserWindows.shared.window(for: $0)?.screen } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = DocumentPiPPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel = window
        window.delegate = self
        window.title = title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = content
        window.contentMinSize = NSSize(width: min(200, max(1, visible.width)),
                                       height: min(120, max(1, visible.height - chromeHeight)))
        window.maxSize = visible.size

        if preferences["disallowReturnToOpener"] != "1" { installReturnButton(on: window) }
        let size = clamped(NSSize(width: width,
                                  height: height), in: visible)
        window.setContentSize(size)
        var frame = window.frame
        frame.origin = NSPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24)
        if preferences["preferInitialWindowPlacement"] != "1", let remembered = Self.placements[source.id] {
            frame = remembered
        }
        window.setFrame(Self.fitted(frame, in: visible), display: false)
        Self.live.append(self)
        Self.listen()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
    }

    /// Let WebKit deliver the real pagehide event before dropping its view.
    /// A stalled web process still has a bounded route to native cleanup.
    func close() {
        guard showing, !closing, !released else { return }
        trace("close_requested", caller: true)
        closing = true
        rememberPlacement()
        let ending = epoch
        web?.evaluateJavaScript("window.close()", completionHandler: nil)
        chromiumChild?.builtPage?.run("window.close()", in: .page, gesture: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.epoch == ending else { return }
            self.trace("close_fallback")
            self.didClose()
        }
    }

    /// Called by Browser's WKUIDelegate when the child closes itself.
    func didClose() {
        guard !released, showing || panel != nil else { return }
        trace("did_close", caller: true)
        released = true
        closing = true
        rememberPlacement()
        Self.live.removeAll { $0 === self }
        let child = chromiumChild
        chromiumChild = nil
        (child?.builtPage as? ChromiumPage)?.onDocumentClosed = nil
        (child?.builtPage as? ChromiumPage)?.onDocumentSize = nil
        child?.close()
        let page = web
        web = nil
        page?.configuration.userContentController.removeScriptMessageHandler(forName: Self.resizeHandler, contentWorld: Web.world)
        page?.configuration.userContentController.removeAllUserScripts()
        page?.setAllMediaPlaybackSuspended(true, completionHandler: {})
        page?.stopLoading()
        page?.navigationDelegate = nil
        page?.uiDelegate = nil
        page?.removeFromSuperview()
        if let page { Tab.end(page) }
        panel?.delegate = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
        returnButton = nil
        request = nil
        source = nil
        browser = nil
        trace("disposed")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        trace("window_should_close")
        if released { return true }
        close()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        trace("window_will_close")
        didClose()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let destination = Self.canonical(action.request.url)
        trace("navigation_action", extra: [
            "action_url": action.request.url?.absoluteString ?? "",
            "canonical_url": destination?.absoluteString ?? "",
            "type": action.navigationType.rawValue, "source_main": action.sourceFrame.isMainFrame,
            "target_main": action.targetFrame?.isMainFrame ?? false,
            "target_present": action.targetFrame != nil,
        ])
        // A new-window link still belongs to Browser's ordinary popup path.
        guard let target = action.targetFrame, target.isMainFrame else {
            trace("navigation_allow_subframe_or_popup")
            decisionHandler(.allow)
            return
        }
        // Only the initial document may be loaded. A PiP is a document the
        // opener owns, not a window in which a site can replace that origin.
        if bootstrapping, destination == request || destination?.absoluteString == "about:blank" {
            bootstrapping = false
            trace("navigation_allow_initial")
            decisionHandler(.allow)
        } else if action.navigationType != .reload,
                  let destination, destination.fragment != nil,
                  let current = Self.canonical(webView.url), Self.withoutFragment(destination) == Self.withoutFragment(current) {
            // Anchors keep this same live document. Only a navigation that
            // replaces the document must close its Picture-in-Picture.
            trace("navigation_allow_fragment")
            decisionHandler(.allow)
        } else {
            trace("navigation_close_cancel")
            close()
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        trace("navigation_commit")
        bootstrapping = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        trace("process_terminated")
        didClose()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.resizeHandler, message.webView === web, message.frameInfo.isMainFrame,
              !closing, let body = message.body as? [String: Any],
              let width = body["width"] as? NSNumber, let height = body["height"] as? NSNumber,
              CFGetTypeID(width) != CFBooleanGetTypeID(), CFGetTypeID(height) != CFBooleanGetTypeID(),
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              let window = panel else { return }
        let current = window.contentView?.bounds.size ?? .zero
        let relative = body["relative"] as? Bool ?? false
        let asked = NSSize(width: relative ? current.width + CGFloat(width.doubleValue) : CGFloat(width.doubleValue),
                           height: relative ? current.height + CGFloat(height.doubleValue) : CGFloat(height.doubleValue))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setContentSize(clamped(asked, in: visible))
        window.setFrame(Self.fitted(window.frame, in: visible), display: false)
    }

    private var chromeHeight: CGFloat {
        guard let panel else { return 28 }
        return panel.frame.height - panel.contentRect(forFrameRect: panel.frame).height
    }

    private func clamped(_ size: NSSize, in visible: NSRect) -> NSSize {
        let width = max(1, visible.width)
        let height = max(1, visible.height - chromeHeight)
        return NSSize(width: min(width, max(min(200, width), size.width)),
                      height: min(height, max(min(120, height), size.height)))
    }

    private static func dimension(_ number: NSNumber?, fallback: CGFloat) -> CGFloat {
        guard let value = number?.doubleValue, value.isFinite, value > 0 else { return fallback }
        return CGFloat(value)
    }

    private static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var frame = frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(visible.minX, frame.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(visible.minY, frame.minY), visible.maxY - frame.height)
        return frame
    }

    private static func matches(_ origin: WKSecurityOrigin, url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), !origin.protocol.isEmpty,
              scheme == origin.protocol.lowercased(),
              bareHost(url.host() ?? "") == bareHost(origin.host) else { return false }
        let standard = scheme == "https" ? 443 : (scheme == "http" ? 80 : 0)
        return (url.port ?? standard) == (origin.port == 0 ? standard : origin.port)
    }

    private static func originLabel(_ origin: WKSecurityOrigin) -> String {
        guard !origin.host.isEmpty else { return "Local document" }
        let standard = origin.protocol == "https" ? 443 : (origin.protocol == "http" ? 80 : 0)
        let port = origin.port == 0 || origin.port == standard ? "" : ":\(origin.port)"
        let host = bareHost(origin.host)
        return (host.contains(":") ? "[\(host)]" : host) + port
    }

    private static func bareHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func withoutFragment(_ url: URL) -> URL? {
        guard let url = canonical(url) else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url
    }

    private static func withoutFullscreen(_ original: WKPreferences) -> WKPreferences {
        // WKPreferences is NSSecureCoding, but does not promise NSCopying.
        // Copy its encoded settings before changing a child-only preference.
        let copied: WKPreferences
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true),
           let restored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: WKPreferences.self, from: data) {
            copied = restored
        } else {
            copied = WKPreferences()
            copied.minimumFontSize = original.minimumFontSize
            copied.javaScriptCanOpenWindowsAutomatically = original.javaScriptCanOpenWindowsAutomatically
            copied.isFraudulentWebsiteWarningEnabled = original.isFraudulentWebsiteWarningEnabled
            copied.shouldPrintBackgrounds = original.shouldPrintBackgrounds
            copied.tabFocusesLinks = original.tabFocusesLinks
            copied.isTextInteractionEnabled = original.isTextInteractionEnabled
            copied.isSiteSpecificQuirksModeEnabled = original.isSiteSpecificQuirksModeEnabled
            copied.inactiveSchedulingPolicy = original.inactiveSchedulingPolicy
        }
        copied.isElementFullscreenEnabled = false
        return copied
    }

    private func rememberPlacement() {
        guard let source, let panel else { return }
        Self.placements[source.id] = panel.frame
        Self.placementOrder.removeAll { $0 == source.id }
        Self.placementOrder.append(source.id)
        if Self.placementOrder.count > 128 {
            Self.placements[Self.placementOrder.removeFirst()] = nil
        }
    }

    private func installReturnButton(on window: NSWindow) {
        let button = FirstPressButton(title: "Back to Tab", target: self, action: #selector(returnToSource))
        button.bezelStyle = .rounded
        button.keyTip("Return to the tab that opened this window")
        button.sizeToFit()
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 16, height: 28))
        button.setFrameOrigin(NSPoint(x: 8, y: max(0, (28 - button.frame.height) / 2)))
        accessory.view.addSubview(button)
        window.addTitlebarAccessoryViewController(accessory)
        returnButton = accessory
    }

    @objc private func returnToSource() {
        guard !closing, let source, let browser else { return }
        // A document opened by Little Yab returns to that same small window.
        if let page = source.webKitOnly("WebKit document PiP callbacks", build: false), let link = LinkWindow.owning(page: page) {
            link.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            close()
            return
        }
        // Switching spaces leaves the live opener in its parked row. Bring
        // that row back before selecting; an absent id cannot be selected.
        if !browser.tabs.contains(where: { $0 === source }), let home = browser.spaceHolding(source.id) {
            browser.switchSpace(to: home)
        }
        guard browser.tabs.contains(where: { $0 === source }) else {
            close()
            return
        }
        browser.select(source)
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        close()
    }

    private static let resizeBridge = """
    (function () {
      function resize(event) {
        // This navigator belongs to Yab's isolated world. A page-world
        // replacement of navigator.userActivation cannot vouch for a resize.
        if (!navigator.userActivation || !navigator.userActivation.isActive) return;
        var detail = event.detail;
        if (typeof detail === 'string') {
          try { detail = JSON.parse(detail); } catch (_) { return; }
        }
        if (!detail || typeof detail.width !== 'number' || typeof detail.height !== 'number' ||
            !Number.isFinite(detail.width) || !Number.isFinite(detail.height)) return;
        window.webkit.messageHandlers.documentPiP.postMessage({
          width: detail.width, height: detail.height, relative: detail.relative === true
        });
      }
      function ended() {
        observer.disconnect();
        window.removeEventListener('__yab_document_pip_resize', resize);
      }
      function arm() {
        window.removeEventListener('__yab_document_pip_resize', resize);
        window.addEventListener('__yab_document_pip_resize', resize);
        window.removeEventListener('pagehide', ended);
        window.addEventListener('pagehide', ended, {once:true});
      }
      // document.open replaces markup and erases Window listeners, while
      // retaining this Document and its mutation observers.
      var observer = new MutationObserver(arm);
      observer.observe(document, {childList:true});
      arm();
    })();
    """
}

final class DocumentPiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A window that floats is usually not the key one, and its button still works
/// on the first press.
private final class FirstPressButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
