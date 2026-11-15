import Foundation

/// A page's own document asked for, and nothing heard back: no answer, no
/// redirect, no error. Met on YouTube (2026-10-13): its service worker took
/// the navigation, then replaced itself (skipWaiting), the old worker was
/// ended with the fetch still in it, and WebKit waited out the request's
/// whole 60 s on a white page before "The site didn't respond in time".
/// Reload loaded at once, through the new worker. So a GET of the page that
/// has heard nothing for `patience` seconds is asked once more, as Reload
/// would, and only once: a site that is just slow waits as before.
@MainActor
enum QuietLoad {
    static let patience: TimeInterval = 8

    /// The main frame's last request, when asking it again is harmless.
    private static var asked: [ObjectIdentifier: URLRequest] = [:]
    private static var waits: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The address already asked again, until a page comes.
    private static var retried: [ObjectIdentifier: URL] = [:]

    /// From the navigation action: only a GET to the web, not a step back
    /// or forward (asked again, it would be a new history entry).
    static func deciding(_ webView: any PageHandle, _ action: PageAction) {
        guard action.targetIsMainFrame == true else { return }
        let id = ObjectIdentifier(webView)
        let scheme = action.request.url?.scheme?.lowercased()
        if (scheme == "https" || scheme == "http"), (action.request.httpMethod ?? "GET") == "GET",
           action.kind != .backForward {
            asked[id] = action.request
        } else {
            asked[id] = nil
        }
    }

    /// The navigation began, or a redirect sent it on: the wait starts over.
    static func started(_ webView: any PageHandle) {
        let id = ObjectIdentifier(webView)
        waits.removeValue(forKey: id)?.cancel()
        guard var request = asked[id], let url = webView.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if request.url != url {
            // A redirect: the server answered, and the place it sent the page
            // is what is waited for now.
            request.url = url
            asked[id] = request
        }
        waits[id] = Task { @MainActor [weak webView] in
            try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
            guard !Task.isCancelled, let webView else { return }
            askAgain(webView, request)
        }
    }

    /// The server answered (a response) or the navigation ended: no retry.
    static func heard(_ webView: any PageHandle) {
        waits.removeValue(forKey: ObjectIdentifier(webView))?.cancel()
    }

    /// A page came: the next silence may be asked about again.
    static func committed(_ webView: any PageHandle) {
        let id = ObjectIdentifier(webView)
        heard(webView)
        retried[id] = nil
        asked[id] = nil
    }

    /// Ended without a page. A cancel is the stop below (or a redirect, a
    /// second Return) and keeps the mark, so the load it makes isn't asked
    /// a third time.
    static func failed(_ webView: any PageHandle, _ error: Error) {
        let id = ObjectIdentifier(webView)
        heard(webView)
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        retried[id] = nil
        asked[id] = nil
    }

    private static func askAgain(_ webView: any PageHandle, _ request: URLRequest) {
        let id = ObjectIdentifier(webView)
        waits[id] = nil
        guard let url = request.url, webView.isLoading, webView.url == url, retried[id] != url else { return }
        retried[id] = url
        DebugLog.note("quiet-load-retry", ["host": url.host ?? "", "seconds": patience])
        webView.stopLoading()
        webView.navigate(to: request)
    }
}
