import Foundation

// A device on the network that answers only https: a phone's own page, a
// router's, a printer's, a NAS's. An address typed without a scheme goes to
// http when it is local (Address.url), since a server on this Mac or the
// network almost never has a certificate; a device listening only on 443
// then refused, and the tab said "The site won't accept connections" where
// Arc, remembering the https address, opened it (feedback #82).
//
// So a local http address that can't be connected to gets one quiet look at
// https on the same host, and the tab goes there if something answers. The
// look asks only whether TLS is spoken there: no page is fetched and no
// certificate trusted, so a device's self-signed one still meets the tab's
// own Untrusted page with its way through. Nothing answering, the tab keeps
// the http address and its failure, and Try Again tries http.
enum LocalHTTPS {
    /// The failures that mean nothing took http there: refused, or a port
    /// that hung up on plain http or answered it in TLS's bytes. A timeout
    /// or an unknown name says nothing about https.
    private static let refusals: Set<Int> = [
        NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotParseResponse, NSURLErrorBadServerResponse,
    ]

    /// The https address to look at after `url` failed with `code`, if any:
    /// the same host, port and path. An explicit :80 is http's own port, so
    /// https is looked for on its own, 443.
    static func candidate(for url: URL, code: Int) -> URL? {
        guard refusals.contains(code), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), !host.isEmpty,
              Address.isLocal(host.contains(":") ? "[\(host)]" : host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    /// Whether `url`'s host and port speak TLS, within `seconds`: true as
    /// soon as the server shows a certificate, trusted or not.
    static func answers(_ url: URL, within seconds: TimeInterval = 3) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let handshake = Handshake()
        _ = try? await session.data(for: request, delegate: handshake)
        return handshake.met
    }

    /// The server's certificate arriving is the answer; the request goes no
    /// further.
    private final class Handshake: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var shown = false
        var met: Bool { lock.withLock { shown } }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
                return (.performDefaultHandling, nil)
            }
            lock.withLock { shown = true }
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}
