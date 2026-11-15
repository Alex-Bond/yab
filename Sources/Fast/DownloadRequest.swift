import Foundation

/// The context of an explicit save is the page that supplied the file,
/// never the active tab at the time the network replies.
enum DownloadRequest {
    nonisolated static func filename(_ value: String) -> String {
        let leaf = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let name = leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(name)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "download" }
        guard clean.utf8.count > 240 else { return clean }
        let ext = (clean as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count < 24 ? "." + ext : ""
        let stem = suffix.isEmpty ? clean : String(clean.dropLast(suffix.count))
        var shortened = "", bytes = 0
        for character in stem {
            let length = String(character).utf8.count
            guard bytes + length <= 240 - suffix.utf8.count else { break }
            shortened.append(character); bytes += length
        }
        return shortened + suffix
    }

    /// Follow the image's effective policy; the modern default sends only
    /// the origin across sites and nothing on an HTTPS to HTTP downgrade.
    nonisolated static func referrer(from source: URL?, to target: URL, policy: String = "") -> String? {
        guard let source, ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              var clean = URLComponents(url: source, resolvingAgainstBaseURL: false) else { return nil }
        clean.user = nil; clean.password = nil; clean.fragment = nil
        let port: (URL) -> Int? = { $0.port ?? ($0.scheme?.lowercased() == "https" ? 443 : 80) }
        let same = source.scheme?.lowercased() == target.scheme?.lowercased()
            && source.host()?.lowercased() == target.host()?.lowercased() && port(source) == port(target)
        let downgrade = source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http"
        let full = clean.string
        clean.path = "/"; clean.query = nil
        let origin = clean.string
        switch policy.lowercased() {
        case "no-referrer": return nil
        case "unsafe-url": return full
        case "same-origin": return same ? full : nil
        case "origin": return origin
        case "origin-when-cross-origin": return same ? full : origin
        case "strict-origin": return downgrade ? nil : origin
        case "no-referrer-when-downgrade": return downgrade ? nil : full
        default: return downgrade ? nil : (same ? full : origin)
        }
    }

    nonisolated static func resource(_ url: URL, from page: URL?, policy: String = "") -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(referrer(from: page, to: url, policy: policy), forHTTPHeaderField: "Referer")
        return request
    }

    nonisolated static func failure(_ response: URLResponse) -> Error? {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return nil }
        return NSError(domain: "Yab.Download.HTTP", code: http.statusCode,
                       userInfo: [NSLocalizedDescriptionKey: "The server returned HTTP \(http.statusCode)",
                                  NSURLErrorFailingURLErrorKey: http.url as Any])
    }
}

/// Serial destination ownership across windows, before WebKit creates the
/// file. An existence check alone races two responses for the same name.
@MainActor
enum DownloadDestinations {
    private static var held: [UUID: URL] = [:]

    static func reserve(_ name: String, in folder: URL, for id: UUID) -> URL {
        let clean = DownloadRequest.filename(name)
        let stem = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        var next = clean, number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(next).path)
                || held.contains(where: { $0.key != id && $0.value.standardizedFileURL == folder.appendingPathComponent(next).standardizedFileURL }) {
            next = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            number += 1
        }
        let file = folder.appendingPathComponent(next)
        held[id] = file
        return file
    }

    static func release(_ id: UUID) { held[id] = nil }
    static func transfer(from old: UUID, to next: UUID) {
        if let file = held.removeValue(forKey: old) { held[next] = file }
    }
}

@MainActor
final class DownloadReply {
    private var completion: (@MainActor (URL?) -> Void)?
    var pending: Bool { completion != nil }
    init(_ completion: @escaping @MainActor (URL?) -> Void) { self.completion = completion }
    func answer(_ file: URL?) {
        let done = completion
        completion = nil
        done?(file)
    }
}
