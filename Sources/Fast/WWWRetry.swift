import Foundation

// A site that answers at only one of its two names. portaldasfinancas.gov.pt
// has no address at all in DNS, only www.portaldasfinancas.gov.pt has one,
// so the bare name typed in the field ended on "Nothing answers at this
// address" where Chrome opened the portal (register 1023). Some sites are
// the other way round, or have a certificate for one name only.
//
// So an address typed in the field that fails because its name finds no
// server, refuses the connection, or shows a certificate for another name,
// gets one quiet look at its other name: www. put on, or taken off. The
// look asks the server for its answer with the system's own trust, nothing
// excused; something answering, the tab goes there and the site's working
// name is kept, so the next time it is typed it goes there at once. A link
// in a page is the page's word and is never rewritten; nor is an address
// with a port, an IP address or a name on this Mac's network.
enum WWWRetry {
    /// The failures that say the name, not the page, is wrong.
    private static let failures: Set<Int> = [
        NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorSecureConnectionFailed,
    ]

    /// How long after Return a failure still counts as the typed address's.
    static let patience: TimeInterval = 90

    private static let key = "typedHostAnswers"

    /// Addresses the field just sent, waiting to load or fail, by their key.
    @MainActor private static var waiting: [String: Date] = [:]

    // MARK: Deciding

    /// The other name for `url`: www.host for host, host for www.host. Only
    /// a web address of a public name, with no port of its own.
    static func other(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.port == nil, let host = url.host?.lowercased(), !host.isEmpty,
              !Address.isLocal(host), !host.contains(":"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              labels.last.map({ $0.allSatisfy(\.isLetter) }) == true else { return nil }
        if host.hasPrefix("www.") {
            // www.com is a name of its own, not www. on nothing.
            guard labels.count >= 3 else { return nil }
            parts.host = String(host.dropFirst(4))
        } else {
            parts.host = "www." + host
        }
        return parts.url
    }

    /// Whether failing with `code` is one to look at the other name for.
    static func retries(_ code: Int) -> Bool { failures.contains(code) }

    /// The key an address is waited for under: its scheme, host, path and
    /// query, with an empty path read as /, as WebKit sends it.
    static func key(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        return "\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")\(path)" + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    // MARK: The field's addresses

    /// An address the field sent: one failure of it, soon, gets a look at
    /// its other name.
    @MainActor static func typed(_ url: URL, at now: Date = Date()) {
        guard other(url) != nil, let key = key(url) else { return }
        waiting = waiting.filter { now.timeIntervalSince($0.value) < patience }
        waiting[key] = now
    }

    /// The other name to look at for `failed`, if the field sent it and it
    /// failed with `code`. Asked once: a second failure is the page's own.
    @MainActor static func claim(_ failed: URL, code: Int, at now: Date = Date()) -> URL? {
        guard retries(code), let key = key(failed), let sent = waiting.removeValue(forKey: key),
              now.timeIntervalSince(sent) < patience else { return nil }
        return other(failed)
    }

    // MARK: Kept names

    /// The name the site answered at when `host` was typed, if it did.
    static func preferred(_ url: URL, in settings: UserDefaults = Store.settings) -> URL {
        guard other(url) != nil, let host = url.host?.lowercased(),
              let answers = (settings.dictionary(forKey: key) as? [String: String])?[host],
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = answers
        return parts.url ?? url
    }

    /// `typed` failed and `answered` worked: typed is sent there from now.
    /// The other way round is forgotten, so a site that moves back is
    /// followed back, never sent in a circle.
    static func keep(_ typed: URL, answered: URL, in settings: UserDefaults = Store.settings) {
        guard let from = typed.host?.lowercased(), let to = answered.host?.lowercased(), from != to else { return }
        var answers = settings.dictionary(forKey: key) as? [String: String] ?? [:]
        answers[to] = nil
        answers[from] = to
        // A few hundred sites at most; the oldest ones are not in order, so
        // past that the list starts again rather than growing without end.
        if answers.count > 500 { answers = [from: to] }
        settings.set(answers, forKey: key)
    }

    // MARK: Looking

    /// Whether `url` answers, within `seconds`: any response from its
    /// server, over a connection the system trusts. Its cookies are not
    /// sent and nothing it says is kept.
    static func answers(_ url: URL, within seconds: TimeInterval = 5) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
