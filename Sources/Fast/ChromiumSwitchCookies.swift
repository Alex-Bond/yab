import CryptoKit
import Foundation

/// A restart must distinguish a sign-out from a cookie that has never been
/// imported. Persist only fingerprints, never a second copy of sign-in values.
struct ChromiumSwitchCookieLedger: Codable, Equatable {
    var webKit: [String: String]
    var chromium: [String: String]

    static func fingerprint(_ cookies: [String: ChromiumDRMCookie]) -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return cookies.mapValues { cookie in
            // All fields have a fixed Codable representation.
            let bytes = (try? encoder.encode(cookie)) ?? Data()
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func file(profile: String, store: UUID?) -> URL {
        let identity = profile + ":" + (store?.uuidString ?? "default")
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Store.file("engine-cookies").appendingPathComponent(name + ".json")
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
