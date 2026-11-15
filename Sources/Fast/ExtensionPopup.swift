import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions, but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate, WKScriptMessageHandler {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    private var staging: NSViewController?
    private weak var anchor: NSView?
    private var firstSize: NSSize?
    private var measuringFirst = false
    private var pendingEvents: Any?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window, Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private var measuring: Timer?
    private(set) var extensionID: String?
    /// The sign-in's extensions it is of (ExtensionSignIns): their
    /// controller is told of it, and its links open where they run.
    private(set) weak var owner: Extensions?
    private var controller: WKWebExtensionController { (owner ?? .shared).controller }
    static let closeHandler = "yabExtensionPopupClose"
    private var closeController: WKUserContentController?
    /// The popup whose handler the shared controller holds now.
    private static weak var handlerOwner: ExtensionPopup?
    private var closeOrigin: URL?
    private var closeFor: String?
    private var closeToken: String?
    /// The extension's own button, when the popup hangs from it.
    private weak var button: NSView?
    /// The sliders the popup hangs from instead: an unpinned extension's,
    /// pressed in the list, or a pin's with no pin on screen to hang from.
    private weak var door: NSView?
    /// The popup a click on its own button just closed: the popover goes on
    /// that click's mouse-down, and the button's press comes after, on its
    /// mouse-up, which would open it again.
    private var closedByButton: (id: String, at: Date)?

    /// The popup's web view, while one is up, for the bench.
    var view: WKWebView? { web }
    /// A popup is up: the column it hangs from stays out (Lights.hanging).
    var isShown: Bool { staging != nil || popover?.isShown == true }
    /// A popup is up from the sliders: they stay on screen under it, as a
    /// pin does under its own (SidePlate, SiteControlsDoor).
    var fromDoor: Bool { isShown && door != nil }
    /// The popup is up from these sliders, one door's of several.
    func hangs(from view: NSView?) -> Bool { fromDoor && view != nil && door === view }
    /// Where the popup stands on screen and what it hangs from, for the bench.
    var frames: (popup: NSRect, from: NSRect)? {
        guard shown, popover?.isShown == true, let window = popover?.contentViewController?.view.window,
              let from = button ?? door, let home = from.window else { return nil }
        return (window.frame, home.convertToScreen(from.convert(from.bounds, to: nil)))
    }

    /// `taken`: the extensions list's popover, already up, which the popup
    /// takes over in place of opening one of its own (ExtensionPanel).
    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?, reusing taken: NSPopover? = nil) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        let initialSize = ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)
        // Start at the popover's usable viewport while measuring unseen.
        // A tiny temporary viewport lets a popup's scripts retain wrapped
        // content heights before its eventual width is known (Bitwarden's
        // carousel measures its tallest slide only once).
        // It has to be in the window meanwhile: WebKit suspends a page
        // that is in none.
        AppleWritingTools.configure(configuration)
        let web = WKWebView(frame: NSRect(origin: .zero, size: initialSize), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        // WebKit lets script close a page it didn't open only while the
        // page has a single history entry (DOMWindow::close), and a popup
        // routed by its hash (Bitwarden's #/tabs/vault) has several by the
        // time it fills, so window.close() was refused and webViewDidClose
        // never came. Chrome closes a popup either way: window.close() is
        // carried here instead. Only this popup's own main document may ask.
        closeController = configuration.userContentController
        PasskeyRelay.install(in: configuration.userContentController)
        // The page's EyeDropper in its pages (EyeDropper.swift).
        EyeDropperRelay.install(in: configuration.userContentController)
        // Extension pages share this controller: a name already taken
        // would raise, so a stale handler goes first.
        closeController?.removeScriptMessageHandler(forName: Self.closeHandler)
        closeController?.add(self, name: Self.closeHandler)
        Self.handlerOwner = self
        closeOrigin = context.baseURL
        closeFor = context.uniqueIdentifier
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over the popover's dark
        // material would vanish.
        web.alphaValue = 0
        let request = URLRequest(url: Extensions.unpopped(url))

        let stage = NSView(frame: NSRect(origin: .zero, size: initialSize))
        stage.alphaValue = 0
        stage.addSubview(web)
        let host = NSViewController()
        host.view = stage
        // The popover takes its size from its view controller: left at
        // zero, it came in as a sliver and grew to the size it was given,
        // rather than standing at it from the start.
        host.preferredContentSize = stage.frame.size
        let popover = taken ?? NSPopover()
        if taken == nil {
            popover.contentSize = stage.frame.size
            popover.behavior = .transient
            popover.animates = true
        }
        popover.delegate = self

        self.web = web
        self.popover = popover
        staging = host
        self.anchor = anchor
        extensionID = context.uniqueIdentifier
        let owner = Extensions.owner(of: context)
        self.owner = owner
        button = anchor != nil && anchor === owner.anchors[context.uniqueIdentifier]?.view ? anchor : nil
        door = anchor != nil && anchor === owner.anchors[Extensions.menuAnchor]?.view ? anchor : nil
        let page = PopupPage(web: web, owner: owner)
        self.page = page
        controller.didOpenTab(page)

        shown = false
        // Keep WebKit in an awake window for its first layout, without
        // putting a guessed-size popover on screen. The list, if this came
        // from it, stays in place until the page has its own size.
        let content = anchor?.window?.contentView ?? (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView
        content?.addSubview(stage)
        // Until there is a transient popover to dismiss, a click or Escape
        // cancels the pending opening just as it would close that popover.
        pendingEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.staging != nil else { return event }
                if event.type == .keyDown && event.keyCode != 53 { return event }
                if let id = self.extensionID, let button = self.button, event.window === button.window,
                   button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                    self.closedByButton = (id, Date())
                }
                self.close()
                return event
            }
        }
        web.load(request)
        // What it hangs from stays out under it, the pin or the sliders
        // (SidePlate, SiteControlsDoor), which read this popup but don't
        // watch it: told once it is up, as on close. The list handing its
        // popover over had told them first, before there was a popup, and
        // the sliders went with the list.
        DispatchQueue.main.async {
            owner.objectWillChange.send()
            SiteControlsState.shared.objectWillChange.send()
        }
        // A manager Yab unlocks, showing its lock screen: unlocked in place.
        ManagerKeep.inPlace(web, url: url)
        // A slow or broken page must not keep its action waiting forever.
        // Normal pages open after two matching layouts, before this limit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak popover] in
            self?.settle(popover, since: Date())
        }
    }

    /// The limit on waiting for the first layout. A page that has laid out
    /// nothing wider than a strip by then is given until `patience` to
    /// grow, as it would be shown as that strip and expand a second or two
    /// later otherwise (feedback #957).
    private static let patience: TimeInterval = 3
    private static let strip: CGFloat = 100

    static func waitsForSize(_ size: NSSize?, elapsed: TimeInterval) -> Bool {
        guard let size, size.width > 0 else { return false }
        return size.width < strip && elapsed < patience - 0.75
    }

    private func settle(_ opened: NSPopover?, since start: Date) {
        guard let opened, opened === popover else { return }
        if !shown {
            if Self.waitsForSize(firstSize, elapsed: Date().timeIntervalSince(start)) {
                firstMeasure()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak opened] in
                    self?.settle(opened, since: start)
                }
                return
            }
            if let size = firstSize { apply(size) }
            reveal()
        }
        follow()
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let popover, let host = staging else { return }
        stopPendingEvents()
        let stage = host.view
        stage.removeFromSuperview()
        stage.alphaValue = 1
        if popover.isShown {
            ExtensionPanel.replace(in: popover, with: host)
            popover.contentSize = host.preferredContentSize
        } else {
            popover.contentViewController = host
            popover.contentSize = host.preferredContentSize
            if let anchor, anchor.window != nil {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
                let spot = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 40, width: 1, height: 1)
                popover.show(relativeTo: spot, of: content, preferredEdge: .minY)
            }
        }
        if let id = extensionID { Self.lastSize[id] = popover.contentSize }
        staging = nil
        shown = true
        web.frame = NSRect(origin: .zero, size: popover.contentSize)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
        owner?.objectWillChange.send()
        SiteControlsState.shared.objectWillChange.send()
    }

    /// From the page's first load: sized, then followed as it grows, a
    /// list filled in by a reply from the worker, for a few seconds.
    private func follow() {
        guard measuring == nil else { return }
        if !shown { firstMeasure() }
        ticks = 0
        var ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                ticks += 1
                self?.grow()
                if ticks > 24 { timer.invalidate() }
            }
        }
    }

    /// `lingering`: closed by its own page's window.close(). The popover
    /// goes at once; the page, and WebKit's tab for it, a moment later, so
    /// what it asked for just before still gets done. MetaMask's popup opens
    /// its onboarding with tabs.create and closes in the same breath, as
    /// Chrome lets it, and a popup let go at once lost that tab now and then
    /// (evals/extensions/wallet_tabs.py, relaunched).
    func close(lingering: Bool = false) {
        measuring?.invalidate()
        measuring = nil
        let closing = popover
        let lingers = lingering ? page.map { ($0, web) } : nil
        if lingers != nil { page = nil }
        forget()
        closing?.performClose(nil)
        if let (page, web) = lingers {
            let controller = controller
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                controller.didCloseTab(page, windowIsClosing: false)
                withExtendedLifetime(web) {}
            }
        }
    }

    /// Gives the popover up to the extensions list, which puts itself in
    /// the page's place (⌘E on an open popup). The page is closed; its view
    /// stays in the popover only while it fades. Nil when no popup is up.
    func handOver() -> NSPopover? {
        if staging != nil { close(); return nil }
        guard let popover, popover.isShown else { return nil }
        measuring?.invalidate()
        measuring = nil
        forget()
        return popover
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        stopPendingEvents()
        staging?.view.removeFromSuperview()
        staging = nil
        anchor = nil
        firstSize = nil
        measuringFirst = false
        shown = false
        held = 0
        closeToken = nil
        closeFor = nil
        closeOrigin = nil
        // Only while the shared controller's handler is still this popup's:
        // one pressed open as this one closes has put its own there.
        if Self.handlerOwner === self {
            closeController?.removeScriptMessageHandler(forName: Self.closeHandler)
            Self.handlerOwner = nil
        }
        closeController = nil
        if let page { controller.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
        door = nil
    }

    private func stopPendingEvents() {
        if let pendingEvents { NSEvent.removeMonitor(pendingEvents) }
        pendingEvents = nil
    }

    /// A press on the button of an extension whose popup is up closes it, as
    /// in Chrome: whether the popover is still there (a click on the view it
    /// hangs from doesn't close it) or went on this click's mouse-down.
    /// Closed, it is not opened again.
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }


    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still unseen: the width the page names for itself if it
    /// names one, else its narrowest (min-content, what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    static let preferred = """
    () => {
      const d = document.documentElement;
      if (!d) return null;
      const m = window.__yabSizing || (window.__yabSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      // A width the page sets for itself shows as one the view doesn't
      // have; one equal to the view is either filling it or the width it
      // was given last time, remembered.
      let w;
      if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w)));
      d.style.setProperty("width", w + "px", "important");
      // A requested minimum is still binding when it happens to equal
      // the cached viewport. Removing it for the auto-height measurement
      // must not shrink a freshly reopened popup below that minimum.
      const minimum = getComputedStyle(d).minHeight;
      const minHeight = minimum.endsWith("px") ? parseFloat(minimum) : 0;
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(Math.max(h, minHeight))))];
    }
    """

    /// The document is built, DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Proton
    /// Pass takes whatever size it finds then for good). WebKit tells a
    /// navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        installClose(in: webView)
        firstMeasure()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web else { return }
        closeToken = nil
    }

    private func owns(_ url: URL?) -> Bool {
        guard let url, let closeOrigin, extensionID == closeFor else { return false }
        return url.scheme == closeOrigin.scheme && url.host == closeOrigin.host
    }

    private func installClose(in webView: WKWebView) {
        guard owns(webView.url), let scheme = closeOrigin?.scheme, let host = closeOrigin?.host else { return }
        let token = UUID().uuidString
        guard let source = Self.closeBridge(scheme: scheme, host: host, token: token) else { return }
        closeToken = token
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    /// The page's window.close(), carried to the native side with this
    /// document's token. Any other window, origin or frame keeps WebKit's
    /// own close.
    static func closeBridge(scheme: String, host: String, token: String, handler: String = closeHandler) -> String? {
        // Scheme/host come from WebKit's extension base URL; serialize
        // them rather than interpolating an extension-provided string.
        guard let data = try? JSONSerialization.data(withJSONObject: [scheme + ":", host, token, handler]),
              let values = String(data: data, encoding: .utf8) else { return nil }
        return """
        (() => {
          const [scheme, host, token, handler] = \(values);
          if (window.top !== window || location.protocol !== scheme || location.host !== host) return;
          // The extension's shim made close before the page's scripts ran,
          // ahead of a sandbox that takes globals away (MetaMask's
          // LavaMoat): it is only told where to carry the call.
          const made = Object.getOwnPropertyDescriptor(window, "__yabPopupClose");
          if (made && typeof made.set === "function") { made.set.call(window, [handler, token]); return; }
          const original = window.close;
          window.close = function(...args) {
            if (this !== window || window.top !== window || location.protocol !== scheme || location.host !== host)
              return Reflect.apply(original, this, args);
            // The handler gone (a popup closing as this one came up takes
            // the shared controller's handler with it): WebKit's own close,
            // rather than a throw that left AdBlock's popup up after
            // "Pause on this site" and blank at the next press.
            const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler];
            if (!bridge) return Reflect.apply(original, this, args);
            bridge.postMessage(token);
          };
        })();
        """
    }

    /// Whether a close request is the popup's own: its document's current
    /// token, from its main frame, on the extension's origin.
    nonisolated static func acceptsClose(body: Any, token: String?, mainFrame: Bool,
                                         scheme: String, host: String, base: URL?) -> Bool {
        guard let token, (body as? String) == token, mainFrame, let base else { return false }
        return scheme == base.scheme && host == base.host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.closeHandler, userContentController === closeController,
              let current = web, message.webView === current,
              Self.acceptsClose(body: message.body, token: closeToken, mainFrame: message.frameInfo.isMainFrame,
                                scheme: message.frameInfo.securityOrigin.protocol,
                                host: message.frameInfo.securityOrigin.host, base: closeOrigin),
              let token = closeToken, let id = extensionID, id == closeFor, owns(current.url) else { return }
        // Leave WebKit's message callback before notifying it that its tab
        // closed. A replaced popup or document invalidates this request.
        DispatchQueue.main.async { [weak self, weak current] in
            guard let self, let current, self.web === current, self.closeToken == token,
                  self.extensionID == id, self.owns(current.url) else { return }
            if Store.testing {
                FileHandle.standardError.write(Data("YAB_POPUP_SCRIPT_CLOSE window=\(current.window?.windowNumber ?? -1)\n".utf8))
            }
            self.close(lingering: true)
        }
    }

    /// Measured while still unseen, then shown at
    /// the size found.
    private func firstMeasure() {
        guard let web, !shown, !measuringFirst else { return }
        measuringFirst = true
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.shown else { return }
                self.measuringFirst = false
                if let pair = value as? [Double], pair.count == 2 {
                    let size = NSSize(width: pair[0], height: pair[1])
                    let previous = self.firstSize
                    self.firstSize = size
                    self.apply(size)
                    if previous == size {
                        self.reveal()
                        return
                    }
                }
                // Let the page lay out at its measured width before it is
                // shown. A second navigation or a close discards this work.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak web] in
                    guard let self, let web, web === self.web else { return }
                    self.firstMeasure()
                }
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if let staging {
            staging.preferredContentSize = size
            staging.view.setFrameSize(size)
            web?.setFrameSize(size)
            return
        }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            // The popover takes its size from its view controller, and goes
            // back to it: both are told.
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID { ExtensionPopup.lastSize[id] = size }
    }

    /// How far the page reaches, as a function of "width" or "height":
    /// its own width if it names one wider than the view, else its
    /// narrowest (min-content, what is positioned off to the side doesn't
    /// count, as in Chrome's measure), else, for a page that only fills the
    /// view and has next to no width of its own, what its content spans.
    /// Height: all it spans.
    static let reach = """
    ((key) => {
      const d = document.documentElement;
      if (!d) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width;
      if (own > innerWidth + 1) return own;
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    })
    """

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows, so a page that settles doesn't set
    /// it rocking.
    private var ticks = 0
    private func grow() {
        guard shown, let web, let popover else { return }
        ticks += 1
        if ticks <= 8 {
            web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, web === self.web, popover === self.popover,
                          let pair = value as? [Double], pair.count == 2 else { return }
                    let wanted = NSSize(width: pair[0], height: pair[1])
                    let now = popover.contentSize
                    if abs(wanted.width - now.width) > 2 || abs(wanted.height - now.height) > 2 { self.apply(wanted) }
                }
            }
            return
        }
        web.evaluateJavaScript("[\(ExtensionPopup.reach)('width'), (() => { const d = document.documentElement; return d && d.scrollHeight > d.clientHeight ? d.scrollHeight : 0; })()]") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, popover === self.popover,
                      let pair = value as? [Double], pair.count == 2 else { return }
                let now = popover.contentSize
                let wanted = NSSize(width: min(800, max(now.width, pair[0])), height: min(600, max(now.height, pair[1])))
                if wanted != now { self.apply(wanted) }
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === web else { return }
        close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    /// A link that asks for a new window becomes a tab, and the popup goes,
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { (owner ?? .shared).opening()?.open(url, foreground: true) }
        close()
        return nil
    }

    /// Passkey requests from this popup still waiting on the Mac's sheet.
    private var held = 0

    /// Kept up while its page waits on the Mac's passkey sheet, which takes
    /// the focus a transient popover closes on (Bitwarden's unlock with a
    /// passkey). What comes back lets it go again; nil for any other page.
    static func hold(_ page: WKWebView) -> (() -> Void)? {
        let popup = shared
        guard popup.web === page, let popover = popup.popover else { return nil }
        popup.held += 1
        return { [weak popup, weak popover] in
            guard let popup, popover === popup.popover else { return }
            popup.held = max(0, popup.held - 1)
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover !== self.popover || held == 0
    }

    /// Closing on a mouse-down over the popup's own button.
    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let spot = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    /// Only for the popover that is up: closing the last one animates, and
    /// its notification can land after the next one has opened.
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        measuring?.invalidate()
        measuring = nil
        forget()
        // The pin it kept out beside the address may go now, and the
        // sliders it hung from (the tab's door reads SiteControlsState).
        (owner ?? .shared).objectWillChange.send()
        SiteControlsState.shared.objectWillChange.send()
    }
}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs, which is where Chrome puts a popup too.
@available(macOS 15.4, *)
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    unowned let owner: Extensions

    init(web: WKWebView, owner: Extensions) {
        self.web = web
        self.owner = owner
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    /// Said at the stand-in's address WebKit knows the popup by
    /// (ExtensionShims.mendPopup), not the page's own, as it was said at the
    /// copy's before: Chrome lists no tab for a popup, and an extension
    /// that looks for its page among the tabs, as Bitwarden does for its
    /// pop-outs, finds none. At the page's own address, Bitwarden's popup
    /// didn't open a second time (scripts/runs/bitwarden_feedback_check.sh).
    func url(for context: WKWebExtensionContext) -> URL? {
        guard let url = web?.url, !url.path.contains(Extensions.popupCopy),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return web?.url }
        parts.path = ExtensionShims.standIn(url.path)
        return parts.url ?? url
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}
