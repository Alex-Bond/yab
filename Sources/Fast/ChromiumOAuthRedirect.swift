import Foundation

/// identity.getRedirectURL() reserves this HTTPS origin for an extension.
/// A navigation there delivers its URL to native tabs.onUpdated; it is not a
/// website to repair with a DNS retry or cover with Yab's load-error card.
enum ChromiumOAuthRedirect {
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = host.dropLast(".chromiumapp.org".count)
        return id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }
}
