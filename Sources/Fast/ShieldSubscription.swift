import Foundation

/// A user-added list uses the same cookie-free downloader and compiler as
/// built-in lists. Its stable cache name contains no URL or path component.
struct ShieldSubscription: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    static let key = "shield.custom-sources"
    /// A test run may add a list an eval serves on this Mac over plain
    /// http (127.0.0.1 only); a person's yab takes https alone.
    static var loopback: Bool { Store.testing }

    init?(_ raw: String, loopback: Bool = ShieldSubscription.loopback) {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" || (loopback && url.scheme?.lowercased() == "http" && url.host() == "127.0.0.1"),
              url.host()?.isEmpty == false,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        self.id = UUID()
        self.url = url
    }

    var source: ShieldLists.Source {
        .init(name: "custom-" + id.uuidString.lowercased(), url: url, least: 16)
    }

    static func read(in store: UserDefaults) -> [Self] {
        guard let data = store.data(forKey: key), let decoded = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        var urls = Set<URL>()
        return decoded.filter { Self($0.url.absoluteString) != nil && urls.insert($0.url).inserted }.prefix(16).map { $0 }
    }

    static func save(_ items: [Self], in store: UserDefaults) {
        store.set(try? JSONEncoder().encode(items), forKey: key)
    }

    static func accepts(_ data: Data) -> Bool {
        // Bytes, not characters: in a list saved with CRLF (AdGuard's are)
        // "\r\n" is one Character, and a String holds no "\n" of its own.
        guard data.contains(UInt8(ascii: "\n")), let text = String(data: data, encoding: .utf8) else { return false }
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (!start.hasPrefix("<") && !start.hasPrefix("{") && !start.hasPrefix("[")) || start.hasPrefix("[adblock")
    }
}
