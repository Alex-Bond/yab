import Foundation

/// A mailto: link (RFC 6068) as a new mail to write: whom to, Cc and Bcc,
/// its subject and its words, as the link asks. An address that doesn't
/// read as one is left out; a link that names nobody still gives a mail,
/// its To left to fill.
public struct MailtoLink: Equatable {
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let rest = String(url.absoluteString.dropFirst("mailto:".count))
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var to = MailtoLink.addresses(parts.first ?? "")
        var cc: [String] = [], bcc: [String] = []
        var subject = "", body = ""
        for field in (parts.count > 1 ? parts[1] : "").split(separator: "&") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].removingPercentEncoding ?? pair[1]
            switch pair[0].lowercased() {
            case "to": to += MailtoLink.addresses(pair[1])
            case "cc": cc += MailtoLink.addresses(pair[1])
            case "bcc": bcc += MailtoLink.addresses(pair[1])
            // One line: a break in it could start a header of its own.
            case "subject":
                subject = value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).joined(separator: " ")
            case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
            default: break
            }
        }
        func once(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { seen.insert($0.lowercased()).inserted }
        }
        self.to = once(to)
        self.cc = once(cc)
        self.bcc = once(bcc)
        self.subject = subject.trimmingCharacters(in: .whitespaces)
        self.body = body
    }

    /// Everyone it is to, Cc and Bcc too: what the same link again finds
    /// its draft by.
    public var people: [String] { (to + cc + bcc).map { $0.lowercased() } }

    /// "a@x.com,b@y.com", percent-encoded or not, as the addresses that read as one.
    static func addresses(_ list: String) -> [String] {
        list.split(separator: ",").compactMap { part in
            let address = (String(part).removingPercentEncoding ?? String(part)).trimmingCharacters(in: .whitespaces)
            return MailAddress.valid(address) ? address : nil
        }
    }
}
