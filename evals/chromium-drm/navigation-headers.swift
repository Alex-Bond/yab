import AppKit
import WebKit

// A nonpersistent, windowless WebKit diagnostic. No accounts or header values.
@MainActor
final class Probe: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let label: String
    let done: ([String: Any]) -> Void

    init(label: String, url: URL, customAgent: Bool, done: @escaping ([String: Any]) -> Void) {
        self.label = label
        self.done = done
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        if customAgent { web.customUserAgent = "Yab synthetic navigation probe" }
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.path == "/eme" { webView.evaluateJavaScript("location.href='/route-chromium'") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame == true, action.request.url?.path == "/route-chromium" else {
            decisionHandler(.allow); return
        }
        let request = action.request
        done(["label": label, "headers": (request.allHTTPHeaderFields ?? [:]).keys.sorted(),
              "method": request.httpMethod ?? "", "body": request.httpBody != nil,
              "stream": request.httpBodyStream != nil])
        decisionHandler(.cancel)
    }
}

@main
struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let url = URL(string: CommandLine.arguments[1])!
        var results: [[String: Any]] = []
        let done: ([String: Any]) -> Void = { value in
            results.append(value)
            if results.count == 2 {
                let data = try! JSONSerialization.data(withJSONObject: ["probes": results], options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                DispatchQueue.main.async { exit(0) }
            }
        }
        let plain = Probe(label: "plain", url: url, customAgent: false, done: done)
        let custom = Probe(label: "custom-agent", url: url, customAgent: true, done: done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
        withExtendedLifetime((plain, custom)) { app.run() }
    }
}
