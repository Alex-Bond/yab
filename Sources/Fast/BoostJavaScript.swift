import WebKit

@MainActor
enum BoostJavaScript {
    static func evaluate(_ source: String, on web: WKWebView, world: WKContentWorld = .page) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: world) { result in continuation.resume(with: result) }
        }
    }
    static func call(_ source: String, arguments: [String: Any] = [:], on web: WKWebView, world: WKContentWorld = .page, timeout: TimeInterval = 35) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var answered = false
            web.callAsyncJavaScript(source, arguments: arguments, in: nil, in: world) { result in
                guard !answered else { return }; answered = true; continuation.resume(with: result)
            }
            // A JS timer cannot interrupt a synchronous loop. Bound how long
            // the native caller waits independently of the JS event loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak web] in
                guard !answered else { return }; answered = true
                web?.stopLoading()
                continuation.resume(throwing: BoostPackage.Invalid("Plugin JavaScript timed out; any effect may be unknown."))
            }
        }
    }
}

/// CSP does not block top-level location.href. Scratch plugin realms must
/// never navigate after their initial empty document or acquire another page.
@MainActor
final class BoostNavigation: NSObject, WKNavigationDelegate {
    private var initial = true
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if initial, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.absoluteString == "about:blank" {
            initial = false; decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }
}
