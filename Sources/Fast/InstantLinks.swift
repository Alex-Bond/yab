import Foundation
import WebKit

/// The words ⇧↩ opens, in their original order. No model or account is needed.
enum InstantLinks {
    static let limit = 5
    struct Request: Equatable {
        let words: String
        let count: Int
    }

    static func requests(_ text: String) -> [Request] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        // A URL may itself contain commas. It always stays one address.
        if Address.url(from: words) != nil { return [Request(words: words, count: 1)] }
        if let re = try? NSRegularExpression(pattern: #"^(?:open\s+)?(?:the\s+)?top\s+([0-9]+)\s+(.+)$"#, options: .caseInsensitive),
           let hit = re.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
           let number = Range(hit.range(at: 1), in: words), let query = Range(hit.range(at: 2), in: words),
           let n = Int(words[number]), n > 0 {
            return [Request(words: String(words[query]), count: min(n, limit))]
        }
        return words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(limit).map { Request(words: $0, count: 1) }
    }

    /// Web destinations or known organic-result redirects, never engine controls.
    static func destinations(_ strings: [String], from search: URL, count: Int) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for string in strings {
            guard var url = URL(string: string, relativeTo: search)?.absoluteURL else { continue }
            let host = url.host?.lowercased() ?? ""
            var resultRedirect = false
            if host == search.host?.lowercased(), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let items = parts.queryItems ?? []
                // Google also serves opaque /goto links. Their signed token
                // is followed by the destination tab as an ordinary link.
                resultRedirect = (host == "www.google.com" || host == "google.com") && url.path == "/goto"
                    && items.contains { $0.name == "url" && !($0.value ?? "").isEmpty }
                if url.path == "/url", let target = items.first(where: { $0.name == "q" || $0.name == "url" })?.value,
                   let unwrapped = URL(string: target) { url = unwrapped }
                else if let target = items.first(where: { $0.name == "uddg" })?.value, let unwrapped = URL(string: target) { url = unwrapped }
                else if url.path.hasPrefix("/ck/"), let encoded = items.first(where: { $0.name == "u" })?.value, encoded.hasPrefix("a1") {
                    var b64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
                    guard let bytes = Data(base64Encoded: b64), let target = String(data: bytes, encoding: .utf8), let decoded = URL(string: target) else { continue }
                    url = decoded
                }
            }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let targetHost = url.host, !targetHost.isEmpty, url.user == nil, url.password == nil,
                  (targetHost.lowercased() != search.host?.lowercased() || resultRedirect),
                  !targetHost.lowercased().hasPrefix("consent."),
                  seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
            if urls.count >= max(1, min(count, limit)) { break }
        }
        return urls
    }

    /// Read only organic result rows. Unknown custom engines fall back to their results page.
    static func script(engine: Engine) -> String? {
        let selector: String
        switch engine {
        case .google: selector = "#search a:has(h3), #rso a:has(h3)"
        case .duckduckgo: selector = "a[data-testid='result-title-a'], .result__a"
        case .bing: selector = ".b_algo h2 a"
        case .ecosia: selector = ".result--web a.result__link, [data-test-id='web-result'] a.result__link"
        case .startpage: selector = "a.w-gl__result-title"
        case .kagi: selector = ".__sri_title_link"
        case .brave: selector = ".snippet[data-type='web'] a.heading-serpresult"
        case .qwant: selector = "a[data-testid='webResult-title']"
        case .custom: return nil
        }
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [selector]), encoding: .utf8)!
        return """
        (() => {
          const result = [];
          for (const a of document.querySelectorAll(\(quoted)[0])) {
            if (!a.getClientRects().length || a.closest('#tads, #bottomads, .uEierd, [data-text-ad], [data-ad], [data-ad-slot], .ads-ad, .b_ad, .result--ad, [data-testid="ad"]')) continue;
            if (a.href) result.push(a.href);
          }
          return result;
        })()
        """
    }
}

/// A quiet results page, in the source tab's store but outside tabs and app history.
/// It has no Tab callbacks, extensions, popup UI or download path.
@MainActor
final class InstantLinksSearch: NSObject, WKNavigationDelegate {
    private(set) static var diagnostics: [String] = []
    private var failed = false
    private var reading = false
    private var results: [String] = []
    private let web: WKWebView
    private let search: URL
    private let engine: Engine

    init(search: URL, engine: Engine, store: WKWebsiteDataStore) {
        self.search = search
        self.engine = engine
        let config = Web.configuration(store: store, extensions: false)
        // This is a bounded search the user just asked for, even while pages save power.
        config.preferences.inactiveSchedulingPolicy = .none
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        super.init()
        web.navigationDelegate = self
        if Store.testing { Self.diagnostics = [] }
    }

    func resolve(count: Int) async -> [URL] {
        guard let script = InstantLinks.script(engine: engine) else { return [search] }
        web.load(URLRequest(url: search))
        defer { web.stopLoading(); web.navigationDelegate = nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !Task.isCancelled, !failed, ContinuousClock.now < deadline {
            let urls = InstantLinks.destinations(results, from: search, count: count)
            if !urls.isEmpty { note("resolved \(urls.count)"); return urls }
            if !reading {
                reading = true
                web.evaluateJavaScript(script, in: nil, in: Web.world) { [weak self] result in
                    guard let self else { return }
                    self.reading = false
                    self.results = (try? result.get()) as? [String] ?? []
                }
            }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return [] }
        }
        note(Task.isCancelled ? "cancelled" : "fallback failed=\(failed)")
        return Task.isCancelled ? [] : [search]
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              navigationAction.targetFrame != nil else {
            note("blocked \(navigationAction.request.url?.scheme ?? "none") main=\(navigationAction.targetFrame?.isMainFrame == true)")
            // Search engines use empty and data frames too. Blocking a child
            // or a popup does not mean their main results page failed.
            if navigationAction.targetFrame?.isMainFrame == true { failed = true }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    private func note(_ message: String) {
        guard Store.testing else { return }
        Self.diagnostics.append(message)
        if Self.diagnostics.count > 32 { Self.diagnostics.removeFirst() }
    }
    private func navigationFailed(_ error: Error) {
        let error = error as NSError
        note("navigation \(error.domain) \(error.code)")
        // A replacement navigation cancels the previous one normally.
        if error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled { failed = true }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { note("process terminated"); failed = true }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
