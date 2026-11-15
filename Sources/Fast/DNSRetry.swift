import Foundation

/// A failed, uncommitted GET may be replayed once per restored network path.
/// No timers or probes: keep the browser's resolver, cookies and trust policy.
struct DNSRetry {
    private(set) var request: URLRequest?
    var target: URL? { request?.url }
    private(set) var pending = false
    private(set) var ready = false

    mutating func begin(_ request: URLRequest?) {
        self.request = nil
        pending = false
        ready = false
        guard let request, (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !ChromiumOAuthRedirect.matches(url) else { return }
        self.request = request
    }

    mutating func wait(code: Int, failed: URL?, domain: String) {
        pending = false
        guard domain == NSURLErrorDomain,
              [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
               NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(code),
              let target, let failed, WWWRetry.key(target) == WWWRetry.key(failed) else { return }
        pending = true
    }

    // The path event can arrive before WebKit delivers the old load's error.
    mutating func networkRestored() { if request != nil { ready = true } }
    mutating func networkUnavailable() { ready = false }

    mutating func take(visible: Bool) -> URLRequest? {
        guard pending, ready, visible else { return nil }
        pending = false
        ready = false
        return request
    }
}
