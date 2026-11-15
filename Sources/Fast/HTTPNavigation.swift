import Foundation

/// Only HTTPS chosen for a schemeless field address may fall back to HTTP.
/// Explicit URLs, links, history choices and server redirects keep their scheme.
struct HTTPNavigation {
    private var destination: URL?
    private var fallback: URL?
    let keepsHTTP: Bool

    init(input: String?, destination: URL?) {
        self.destination = destination
        keepsHTTP = destination?.scheme?.lowercased() == "http"
        guard let input, !input.contains("://"), let destination,
              destination.scheme?.lowercased() == "https",
              destination.user == nil, destination.password == nil,
              let guessed = Address.url(from: input), WWWRetry.key(guessed) == WWWRetry.key(destination),
              let host = destination.host?.lowercased(), !Address.isLocal(host),
              var parts = URLComponents(url: destination, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = "http"
        if parts.port == 443 { parts.port = nil }
        fallback = parts.url
    }

    mutating func claim(_ failed: URL, code: Int) -> URL? {
        guard let destination, WWWRetry.key(destination) == WWWRetry.key(failed),
              Self.failures.contains(code), let fallback else { return nil }
        clearFallback()
        return fallback
    }

    mutating func clearFallback() {
        destination = nil
        fallback = nil
    }

    private static let failures: Set<Int> = [
        NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
        // A failed TLS handshake can mean a server only speaks HTTP. A
        // certificate refusal means HTTPS answered: never bypass its trust
        // check by replaying the request and query over cleartext.
        NSURLErrorSecureConnectionFailed,
    ]
}
