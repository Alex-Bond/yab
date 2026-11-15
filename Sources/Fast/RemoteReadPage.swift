import AppKit
import WebKit
import ObjectiveC

/// A task-owned page never inherits Browser's download, application, dialog,
/// popup, sign-in, draft-generation or media permission callbacks.
@MainActor
final class RemoteReadPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: Tab?
    private static var retentionKey: UInt8 = 0
    private var retired = false
    private let isCurrent: () -> Bool
    let refused: (String) -> Void

    init(current: @escaping () -> Bool, refused: @escaping (String) -> Void) {
        self.isCurrent = current; self.refused = refused
    }

    func current() -> Bool { !retired && isCurrent() }

    /// Tab delegates are weak. Keep the restrictive policy with this owned
    /// web view, including after the coordinator or account is gone.
    func attach(to tab: Tab) {
        self.tab = tab
        guard let web = tab.webKitOnly("Restricted iPhone read policy") else {
            retired = true
            tab.builtPage?.retire(call: false, pictureInPicture: false)
            refused("Reading with the iPhone policy is not available on this engine yet.")
            return
        }
        tab.delegate = self
        objc_setAssociatedObject(web, &Self.retentionKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func retire() {
        retired = true
        tab?.builtPage?.stopLoading()
    }

    nonisolated static func permits(_ request: URLRequest, download: Bool = false, newWindow: Bool = false) -> Bool {
        guard !download, !newWindow, request.httpBody == nil, request.httpBodyStream == nil,
              (request.httpMethod ?? "GET") == "GET", let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    nonisolated static func permits(_ response: URLResponse, canShow: Bool) -> Bool {
        guard canShow, let url = response.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if let http = response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Disposition")?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true {
            return false
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = current() && Self.permits(action.request, download: action.shouldPerformDownload,
                                                newWindow: action.targetFrame == nil)
        if !allowed { refused("This iPhone task can only read HTTP pages. The navigation was refused.") }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let allowed = current() && Self.permits(response.response, canShow: response.canShowMIMEType)
        if !allowed { refused("This iPhone task cannot download files. No file was saved.") }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard current() else { webView.stopLoading(); return }
        tab?.navigationStarted(navigation?.pageNavigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard current() else { webView.stopLoading(); return }
        tab?.navigationCommitted(navigation?.pageNavigation)
        tab?.failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard current() else { return }
        tab?.uncover()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.navigationFailedEarly(navigation?.pageNavigation)
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        guard current(), (error as NSError).code != NSURLErrorCancelled else { return }
        tab?.failure = "The page could not be read."
        refused("The page could not be read. No action was performed.")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        refused("This iPhone task cannot open a popup.")
        return nil
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal TLS uses system trust. No client certificates, credentials,
        // saved-password lookup or authentication prompt is exported here.
        if current(), challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            refused("This page needs authentication which the iPhone task cannot approve.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        refused("This iPhone task cannot approve a page dialog."); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        refused("This iPhone task cannot approve a page dialog."); completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        refused("This iPhone task cannot answer a page dialog."); completionHandler(nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
}
