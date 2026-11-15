import AppKit
import ImageIO
import WebKit

/// One warm page, in the source's cookie store. It is not in the browser's
/// tabs, history or session until a click actually opens it. Dialogs,
/// downloads, popups and capture requests from a hover are never offered.
@MainActor
final class LinkCardLoad: NSObject, WKNavigationDelegate, WKUIDelegate {
    let page: Tab
    let url: URL
    fileprivate(set) var finished = false
    fileprivate(set) var failed = false
    private var handedOver = false
    /// Set when Chromium draws the page: it hears its engine's events here.
    private var remote: LinkCardRemote?

    init(url: URL, source: Tab) {
        self.url = url
        let config = Web.configuration(shy: source.shy, store: source.store)
        config.mediaTypesRequiringUserActionForPlayback = .all
        // In the engine of the tab it was hovered in, so the click that keeps
        // it finds its cookies, and a Chromium tab's history can hold it.
        let remotely = source.engineKind == .chromium
        page = remotely ? Tab(shy: source.shy, configuration: config, engine: .chromium)
            : Tab(shy: source.shy, configuration: config, factory: .webKitOnly)
        super.init()
        page.from = source.id
        if remotely {
            // The same warm page, in the source's Chromium profile: no
            // dialogs, downloads, popups or permission asks from a hover
            // (LinkCardRemote answers no), and no sound.
            let events = LinkCardRemote(owner: self)
            remote = events
            page.warmProfile = source.chromiumProfile
            page.delegate = events
            let view = page.page
            view.frame = CGRect(x: 0, y: 0, width: 1000, height: 720)
            (view as? any PageAudioControl)?.setAudioMuted(true)
            page.go(to: url)
            return
        }
        page.delegate = self
        page.page.frame = CGRect(x: 0, y: 0, width: 1000, height: 720)
        page.go(to: url)
    }

    func cancel() {
        guard !handedOver else { return }
        page.close()
    }

    func take() -> Tab? {
        guard !failed, !handedOver else { return nil }
        handedOver = true
        page.delegate = nil
        if remote != nil {
            // Sound and the permission asks are the window's from here on.
            page.warmProfile = nil
            (page.builtPage as? any PageAudioControl)?.setAudioMuted(page.muted)
            remote = nil
        }
        return page
    }

    func read() async throws -> LinkSummary.Page {
        if remote != nil { return try await readRemote() }
        // Wait for a committed document, then read its rendered DOM, which
        // includes descriptions and text supplied by a site's own scripts.
        // A short link's page (t.co) finishes, then sends itself on by
        // script or a refresh: settled is finished with nothing loading
        // after a moment, so its few words are never the card's.
        var settled = 0
        for _ in 0..<100 {
            try Task.checkCancellation()
            if failed { throw URLError(.cannotLoadFromNetwork) }
            settled = finished && !page.page.isLoading ? settled + 1 : 0
            if settled >= 3 { break }
            try await Task.sleep(for: .milliseconds(120))
        }
        guard finished, !failed else { throw URLError(.timedOut) }
        // PageView's callback overload intentionally shadows WKWebView's
        // async convenience overload. Bridge its Result explicitly.
        let html: String = try await withCheckedThrowingContinuation { done in
            page.page.run("document.documentElement.outerHTML.slice(0,600000)", in: .yab) { result in
                switch result {
                case .success(let value): done.resume(returning: value as? String ?? "")
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return LinkSummary.read(html)
    }

    /// The same read for a Chromium page: committed, settled, then its
    /// rendered DOM, with the status and kind of the document it came from.
    private func readRemote() async throws -> LinkSummary.Page {
        var settled = 0
        for _ in 0..<100 {
            try Task.checkCancellation()
            if failed { throw URLError(.cannotLoadFromNetwork) }
            settled = finished && !page.page.isLoading ? settled + 1 : 0
            if settled >= 3 { break }
            try await Task.sleep(for: .milliseconds(120))
        }
        guard finished, !failed, page.builtPage?.engine == .chromium else { throw URLError(.timedOut) }
        let reply = try await page.page.run("""
        (function () {
          var nav = performance.getEntriesByType('navigation')[0] || {};
          return JSON.stringify({ status: nav.responseStatus || 0, kind: document.contentType || '',
            html: document.documentElement.outerHTML.slice(0, 600000) });
        })()
        """, in: .yab, gesture: false)
        try Task.checkCancellation()
        guard let text = reply as? String, let data = text.data(using: .utf8),
              let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        if let status = found["status"] as? Int, status >= 400 { failed = true; throw URLError(.badServerResponse) }
        let kind = (found["kind"] as? String ?? "").lowercased()
        guard kind.isEmpty || kind.hasPrefix("text/html") || kind.hasPrefix("application/xhtml") else {
            failed = true
            throw URLError(.cannotParseResponse)
        }
        return LinkSummary.read(found["html"] as? String ?? "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url.map(LinkCardRules.web) == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame else {
            decisionHandler(response.canShowMIMEType ? .allow : .cancel)
            return
        }
        if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 { failed = true }
        if !response.canShowMIMEType { failed = true }
        decisionHandler(failed ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { finished = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    /// Decode only a small thumbnail; an og:image can be many megapixels.
    static func image(_ address: String, relativeTo url: URL, store: WKWebsiteDataStore) async -> NSImage? {
        guard !address.isEmpty, let target = URL(string: address, relativeTo: url)?.absoluteURL,
              LinkCardRules.web(target), !Task.isCancelled,
              let answer = try? await LiveReader.get(target, accept: "image/*", store: store),
              answer.status == 200, answer.data.count <= 2_000_000, !Task.isCancelled,
              let source = CGImageSourceCreateWithData(answer.data as CFData, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: picture, size: CGSize(width: CGFloat(picture.width), height: CGFloat(picture.height)))
    }
}

/// What a hover card's Chromium page may do: load and say when it has. Every
/// ask a page can make of a window, a popup, a dialog, a file, a download, a
/// sign-in or a permission, is the engine's default refusal (PageEvents).
@MainActor
final class LinkCardRemote: NSObject, WKNavigationDelegate, WKUIDelegate, PageEvents {
    private weak var owner: LinkCardLoad?

    init(owner: LinkCardLoad) { self.owner = owner }

    func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
        switch event {
        case .started: owner?.finished = false
        case .finished: owner?.finished = true
        case .failed(_, let error, _):
            if (error as NSError).code != NSURLErrorCancelled { owner?.failed = true }
        case .redirected, .committed: break
        }
    }

    func page(_ page: any PageHandle, ended reason: PageEnd?) { owner?.failed = true }

    func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool) { owner?.failed = true }

    func page(_ page: any PageHandle, decide action: PageAction,
              reply: @escaping @MainActor (PagePolicy) -> Void) {
        reply(action.request.url.map(LinkCardRules.web) == true ? .allow : .cancel)
    }

    func page(_ page: any PageHandle, decide response: PageDocumentResponse,
              reply: @escaping @MainActor (PagePolicy) -> Void) {
        if response.isMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 { owner?.failed = true }
        reply(owner?.failed == true ? .cancel : .allow)
    }
}
