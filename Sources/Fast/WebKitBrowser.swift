import WebKit
import ObjectiveC

// WebKit's navigation identity never crosses the event boundary. Associate
// a value with the navigation itself so programmatic Back and its callbacks
// agree without a registry that keeps finished navigations alive.
private var navigationIdentity: UInt8 = 0
private final class WebKitNavigationIdentity: NSObject {
    let value = PageNavigation()
}

@MainActor
extension WKNavigation {
    var pageNavigation: PageNavigation {
        if let kept = objc_getAssociatedObject(self, &navigationIdentity) as? WebKitNavigationIdentity { return kept.value }
        let made = WebKitNavigationIdentity()
        objc_setAssociatedObject(self, &navigationIdentity, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made.value
    }
}

extension PageAction {
    @MainActor init(_ action: WKNavigationAction) {
        self.init(action, request: action.request)
    }

    @MainActor init(_ action: WKNavigationAction, request: URLRequest) {
        let source = WindowGate.source(action).map { frame in
            let origin = frame.securityOrigin
            return Source(isMainFrame: frame.isMainFrame, scheme: origin.protocol, host: origin.host, port: origin.port)
        }
        self.init(request: request, kind: Kind(rawValue: action.navigationType.rawValue),
                  targetIsMainFrame: action.targetFrame?.isMainFrame, source: source,
                  modifierFlags: action.modifierFlags, buttonNumber: action.buttonNumber,
                  shouldPerformDownload: action.shouldPerformDownload, userInitiated: WindowGate.gesture(action))
    }
}

extension PagePolicy {
    var webKitAction: WKNavigationActionPolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }

    var webKitResponse: WKNavigationResponsePolicy {
        switch self {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }
}

/// Owned by PageView, with a weak listener. Remaining private callbacks
/// are forwarded to the WebKit-specific Browser extension. Asking
/// responds(to:) first preserves WebKit's defaults for absent callbacks.
@MainActor
final class WebKitPageEvents: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var listener: (any PageEvents)?
    var routeSiteEngine: ((URLRequest) async throws -> Bool)?
    var prepareChromiumCookies: ((URL) async throws -> Void)?
    var popups: [UUID: WebKitPopup] = [:]

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (listener as? NSObject)?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let legacy = listener as? NSObject, legacy.responds(to: selector) { return legacy }
        return super.forwardingTarget(for: selector)
    }

    @objc(_webView:handleAutoplayEvent:withFlags:)
    func webView(_ webView: WKWebView, autoplayEvent event: Int, flags: UInt) {
        (webView as? PageView)?.videoPlaybackPrevented(event: event, flags: flags)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.targetFrame?.isMainFrame == true { CallSound.allow(preferences, for: action.request.url) }
        self.webView(webView, decidePolicyFor: action) { decisionHandler($0, preferences) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        LastingSignIns.whenReady(webView.configuration.websiteDataStore) { [weak self, weak webView] in
            guard let self, let webView else { decisionHandler(.cancel); return }
            guard let page = webView as? PageView, let listener = self.listener else { decisionHandler(.allow); return }
            var answered = false
            listener.page(page, decide: PageAction(action)) { policy in
                guard !answered else { return }
                answered = true
                if policy == .allow, action.targetFrame?.isMainFrame == true,
                   let url = action.request.url, let prepare = self.prepareChromiumCookies {
                    Task { @MainActor [weak self, weak page] in
                        do {
                            if let route = self?.routeSiteEngine, try await route(action.request) {
                                decisionHandler(.cancel)
                                return
                            }
                            try await prepare(url)
                            guard self?.listener != nil, page?.events != nil else { decisionHandler(.cancel); return }
                            decisionHandler(.allow)
                        } catch { decisionHandler(.cancel) }
                    }
                } else { decisionHandler(policy.webKitAction) }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .started(navigation?.pageNavigation))
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .redirected(navigation?.pageNavigation))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .committed(navigation?.pageNavigation))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .finished(navigation?.pageNavigation))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .failed(navigation?.pageNavigation, error, provisional: false))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, navigation: .failed(navigation?.pageNavigation, error, provisional: true))
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let page = webView as? PageView, let listener else { decisionHandler(.allow); return }
        var answered = false
        listener.page(page, decide: PageDocumentResponse(response: response.response,
                      isMainFrame: response.isForMainFrame, canShowMIMEType: response.canShowMIMEType)) { policy in
            guard !answered else { return }
            answered = true
            decisionHandler(policy.webKitResponse)
        }
    }
}

// Compatibility entry points for separate WebKit surfaces and fixtures.
// Tab pages install WebKitPageEvents instead of calling these.
extension Browser: WKNavigationDelegate, WKUIDelegate {
    @objc(_webView:handleAutoplayEvent:withFlags:)
    func webView(_ webView: WKWebView, autoplayEvent event: Int, flags: UInt) {
        (webView as? PageView)?.videoPlaybackPrevented(event: event, flags: flags)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.targetFrame?.isMainFrame == true { CallSound.allow(preferences, for: action.request.url) }
        self.webView(webView, decidePolicyFor: action) { decisionHandler($0, preferences) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        LastingSignIns.whenReady(webView.configuration.websiteDataStore) { [weak self, weak webView] in
            guard let self, let webView else { decisionHandler(.cancel); return }
            guard let page = webView as? PageView else { decisionHandler(.allow); return }
            var answered = false
            self.page(page, decide: PageAction(action)) { policy in
                guard !answered else { return }
                answered = true
                decisionHandler(policy.webKitAction)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .started(navigation?.pageNavigation))
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .redirected(navigation?.pageNavigation))
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .committed(navigation?.pageNavigation))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .finished(navigation?.pageNavigation))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .failed(navigation?.pageNavigation, error, provisional: false))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let view = webView as? PageView else { return }
        page(view, navigation: .failed(navigation?.pageNavigation, error, provisional: true))
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let view = webView as? PageView else { decisionHandler(.allow); return }
        page(view, decide: PageDocumentResponse(response: response.response, isMainFrame: response.isForMainFrame,
                                               canShowMIMEType: response.canShowMIMEType)) { decisionHandler($0.webKitResponse) }
    }

    /// WebKit's word that a content rule list acted on a load (private
    /// API, WKNavigationDelegatePrivate): a block, for the blocker to learn
    /// what a site needs (QuietSites), or a page held back from this Mac or
    /// the network, which may be asked about (LocalNetwork).
    /// What is under the pointer in a page, as it moves or a key changes:
    /// a link's address for the pill at its bottom left (LinkStatus).
    @objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)
    func webView(_ webView: WKWebView, mouseDidMoveOverElement hit: AnyObject?, withFlags flags: NSEvent.ModifierFlags, userInfo: AnyObject?) {
        let element = hit as? NSObject
        let hitURL = element?.value(forKey: "absoluteLinkURL") as? URL
        let url = hitURL.flatMap { Self.extensionFragment($0, on: webView.url) ? nil : $0 }
        // The link's words, for the corner's "Opened … in a new tab".
        let label = url == nil ? nil : element.flatMap { element in
            element.responds(to: NSSelectorFromString("linkLabel")) ? element.value(forKey: "linkLabel") as? String : nil
        }
        if LinkGap.cut("hover") { return }
        LinkStatus.shared.pointed(at: url, in: tab(for: webView)?.id, keys: flags, label: label)
    }

    /// The window a page is in, as WebKit asks for it (private API,
    /// WKUIDelegatePrivate) to tell the page its outerWidth, outerHeight,
    /// screenX and screenY. Unanswered, WebKit told every page a window of
    /// 0 by 0 at 0, 0, the tab in front in its window too: every feedback
    /// report's page said outerWidth 0. Google Docs on Safari before 26.4
    /// sizes its page canvases by devicePixelRatio times the zoom level
    /// nearest outerWidth / innerWidth, and keeps it: 0 is nearest its
    /// smallest, a quarter, and on macOS 26.1 and 26.2 every document's
    /// words were drawn at a quarter of the screen's pixels, blurry while
    /// Docs' buttons were sharp (feedback #57, #134, #155).
    ///
    /// Now a page is told its own rectangle on the screen: outerWidth is
    /// its width, so outerWidth / innerWidth is its zoom, all Docs wanted,
    /// and its canvases hold one pixel for each of the screen's. Not the
    /// whole window: beside Yab's column, in Split View or
    /// a small window, the window is wider than the page by more than any
    /// zoom, and Docs drew its pages at up to twice the screen's pixels
    /// each way, four times the memory; scripts that take a window much
    /// wider than its page for docked developer tools would think them
    /// open. A page behind the tab in front, in no window, is told its own
    /// size where the window its tab is shown in stands.
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func _webView(_ webView: WKWebView, getWindowFrameWithCompletionHandler done: @escaping (CGRect) -> Void) {
        done(Self.windowFrame(of: webView, shownIn: BrowserWindows.shared.window(for: self)))
    }

    /// A page's own window.print(), its Print button (private API,
    /// WKUIDelegatePrivate). Unanswered, WebKit dropped it: a site's Print
    /// or Save as PDF did nothing while ⌘P worked (feedback #216). The
    /// system's sheet over the page's window, for the frame that asked;
    /// one at a time, as a page asking again behind a sheet is ignored.
    @objc(_webView:printFrame:)
    func _webView(_ webView: WKWebView, printFrame frame: AnyObject?) {
        // After WebKit's answer: the page waits on it, and the sheet
        // needs the page to draw its pages.
        DispatchQueue.main.async { [weak self, weak webView] in
            MainActor.assumeIsolated {
                guard let webView, let window = webView.window ?? self.flatMap({ BrowserWindows.shared.window(for: $0) }),
                      window.attachedSheet == nil
                else { return }
                Self.printSheet(webView, frame: frame, in: window)
            }
        }
    }

    /// The Download button on WebKit's own PDF viewer, the bar along the
    /// bottom of a PDF (private API, WKUIDelegatePrivate). Unanswered,
    /// WebKit dropped the file and the button did nothing (a tester,
    /// 2026-10-22). WebKit hands over the document as it is shown; it is
    /// kept as a download is: in Downloads, or where the panel says when
    /// you're asked, with where it came from, and in the stack.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func _webView(_ webView: WKWebView, saveDataToFile data: Data, suggestedFilename: String, mimeType: String?, originatingURL: URL?) {
        let page = webView.url ?? originatingURL
        let source = originatingURL ?? page
        let named = suggestedFilename.isEmpty ? (source?.lastPathComponent ?? "") : suggestedFilename
        var name = named.isEmpty || named == "/" ? "document" : named
        if (mimeType ?? "application/pdf") == "application/pdf", (name as NSString).pathExtension.isEmpty { name += ".pdf" }
        let owner = (webView as? any PageHandle).flatMap { tab(owning: $0) }
        let folder = downloadFolder(for: owner)
        let file: URL
        if prefs.asksWhereToSave {
            guard let url = chooseDownloadLocation(name, folder) else { return }
            file = url
        } else {
            file = Browser.free(name, in: folder)
        }
        guard (try? data.write(to: file, options: .atomic)) != nil else {
            toaster.pop("Couldn’t save the file", mark: "exclamationmark.triangle")
            return
        }
        Browser.writeWhereFrom(file, [source, page].compactMap { $0 })
        SiteDownloads.quarantine(file, from: source, page: page)
        hoard.lifting()
        loot.add(Keep(
            name: file.lastPathComponent,
            from: source?.host() ?? "",
            path: file.path,
            date: Date(),
            page: page,
            pageTitle: webView.title.flatMap { $0.isEmpty ? nil : $0 },
            source: source
        ))
        hoard.touched(file.lastPathComponent)
    }

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func _webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard action.responds(to: NSSelectorFromString("blockedLoad")), action.value(forKey: "blockedLoad") as? Bool == true
        else { return }
        if identifier.hasPrefix(LocalNetwork.prefix) { return localNetworkBlocked(url, in: webView) }
        guard identifier.hasPrefix("shield-") else { return }
        Shield.shared.blocked(url, on: webView.configuration.userContentController, quietly: identifier.hasPrefix("shield-quiet-"))
        // For the corner that offers the page its ads back (Unbreak).
        if let tab = tab(for: webView) { Unbreak.shared.blocked(tab, on: webView.url) }
    }

}

extension Browser {
    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.builtPage === webView } ?? outside.first { $0.builtPage === webView }
            ?? parkedTabs.first { $0.builtPage === webView }
            ?? DocumentPiP.owner(of: webView)
    }

}
