import Foundation

// The addresses an account sends as (docs/mail.md, Writing, From and
// signature): Gmail's send-as list, `users.settings.sendAs.list`, which
// gmail.modify reads, one unit, kept in the store's `send_as` once a day
// and at the first sync after Connect (MailSync.keepSendAs). Each has the
// name its From says, a Reply-To, and its signature in HTML; one is the
// default, one the account's own. Its addresses other than the account's
// own are meta `aliases`, so a reply to all leaves them out with `me`.
//
// A mail goes from the address the mail it answers came to, when that is
// one of yours, else from the default; ⇧⌘F picks another (MailDesk.choose).
// The signature is Gmail's for that address, or yours, written in
// Settings › Mail (`signatures`); a new mail carries it, a reply or a
// forward as Settings says.

public struct MailSendAs: Equatable, Sendable {
    public var address: String
    /// What its From says before the address: "" lets the address stand alone.
    public var name = ""
    /// A Reply-To its mail carries; "" for none.
    public var replyTo = ""
    /// Its signature as Gmail keeps it, HTML; "" for none.
    public var signature = ""
    /// The account's own address, and the one a new mail goes from.
    public var primary = false
    public var isDefault = false

    /// Gmail's answer read: every address it may send as, the account's own
    /// first, a custom one only once verified ("accepted"; Gmail sends from
    /// a pending one as the account's own).
    public static func list(_ json: [String: Any]) -> [MailSendAs] {
        let all = (json["sendAs"] as? [[String: Any]] ?? []).compactMap { one -> MailSendAs? in
            guard let address = (one["sendAsEmail"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), address.contains("@") else {
                return nil
            }
            let status = one["verificationStatus"] as? String ?? "accepted"
            let primary = one["isPrimary"] as? Bool ?? false
            guard primary || status == "accepted" || status.isEmpty else { return nil }
            return MailSendAs(address: address, name: (one["displayName"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                              replyTo: (one["replyToAddress"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                              signature: one["signature"] as? String ?? "", primary: primary, isDefault: one["isDefault"] as? Bool ?? false)
        }
        return all.filter(\.primary) + all.filter { !$0.primary }
    }

    /// The address a new mail goes from: Gmail's default, else the account's own.
    public static func defaultAddress(_ all: [MailSendAs], me: String) -> String {
        all.first(where: \.isDefault)?.address ?? all.first(where: \.primary)?.address ?? me
    }

    /// The address a reply to or a forward of `message` goes from: the one
    /// of yours it came from (your own mail), or it went to, To before Cc;
    /// none of yours on it, the default.
    public static func address(answering message: MailMessage?, _ all: [MailSendAs], me: String) -> String {
        let mine = all.map(\.address) + [me.lowercased()]
        guard let message else { return defaultAddress(all, me: me) }
        for person in [message.from] + message.to + message.cc {
            let address = person.address.lowercased()
            if mine.contains(address) { return address }
        }
        return defaultAddress(all, me: me)
    }

    /// Who a mail from `address` says it is from: its send-as name (an
    /// alias with none takes the account's own, as Gmail does), or the
    /// address alone.
    public static func person(_ address: String, _ all: [MailSendAs], me: String) -> MailPerson {
        let address = address.isEmpty ? defaultAddress(all, me: me) : address.lowercased()
        let named = all.first { $0.address == address }?.name ?? ""
        return MailPerson(name: named.isEmpty ? all.first(where: \.primary)?.name ?? "" : named, address: address)
    }
}

extension MailGmail {
    /// The addresses the account sends as, with their names and signatures
    /// (`users.settings.sendAs.list`, gmail.modify, 1 unit).
    public func sendAs() async throws -> [MailSendAs] {
        MailSendAs.list(try await call("settings/sendAs"))
    }
}

/// A signature as a mail carries it: its HTML as it goes in the HTML part,
/// and its words for the plain one.
public struct MailSignature: Equatable, Sendable {
    public var html: String
    public var text: String

    public init(html: String) {
        self.html = html
        text = MailRich.text(html: html)
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Its words as a draft shows them under its own: a link as its words alone.
    public var shown: String { MailRich.text(MailRich.trimmed(MailRich.doc(html: html)), links: false) }

    /// It needs HTML to go as it is: a mark plain text can't carry, or a picture.
    public var marked: Bool {
        MailRich.formatted(MailRich.trimmed(MailRich.doc(html: html))) || html.range(of: "<img", options: .caseInsensitive) != nil
    }

    /// A piece of it as a draft shows it under its words: words, a picture
    /// by its address (one Gmail's signature draws from the web, or carries
    /// in itself as data:), at the size its tag gives where it gives one,
    /// or one that can't be shown here: by cid:, whose bytes Gmail gives a
    /// signature no way to fetch.
    public enum Piece: Equatable, Hashable {
        case words(String)
        case picture(URL, width: Double?, height: Double?)
        case unshown
    }

    /// Its words and pictures in their order. A picture Block tracking
    /// pixels leaves out of mail (a pixel square, hidden) is left out here
    /// too, as it would be of any mail shown.
    public var pieces: [Piece] {
        var out: [Piece] = []
        func words(_ fragment: String) {
            let said = MailRich.text(MailRich.trimmed(MailRich.doc(html: fragment)), links: false).trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { out.append(.words(said)) }
        }
        let whole = html as NSString
        var at = 0
        for match in Self.image.matches(in: html, range: NSRange(location: 0, length: whole.length)) {
            words(whole.substring(with: NSRange(location: at, length: match.range.location - at)))
            at = NSMaxRange(match.range)
            let tag = whole.substring(with: match.range)
            if MailHTML.blocksPixels, MailHTML.pixels(tag).isEmpty { continue }
            out.append(Self.picture(tag))
        }
        words(whole.substring(from: at))
        return out
    }

    private static let image = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    /// A picture's tag as a piece: its address when it is one to fetch or
    /// carries its bytes, else unshown.
    public static func picture(_ tag: String) -> Piece {
        func attribute(_ name: String) -> String? {
            guard let found = tag.range(of: #"\b"# + name + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: [.regularExpression, .caseInsensitive])
            else { return nil }
            let value = tag[found].split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).replacingOccurrences(of: "&amp;", with: "&")
        }
        guard let source = attribute("src"), let url = URL(string: source),
              ["https", "http", "data"].contains(url.scheme?.lowercased() ?? "") else { return .unshown }
        return .picture(url, width: attribute("width").flatMap(Double.init), height: attribute("height").flatMap(Double.init))
    }
}
