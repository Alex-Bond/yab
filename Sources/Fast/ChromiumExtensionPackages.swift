import Foundation
import CryptoKit

/// Keep original packages separate from WebKit's rewritten extension folders.
enum ChromiumExtensionPackages {
    static func prepare(_ crx: Data, id: String, root: URL) throws -> URL {
        guard ChromiumExtensions.validID(id), root.isFileURL else { throw Crx.Refused.notAnID }
        let package = try Crx.verifiedPackage(crx, id: id)
        let digest = SHA256.hash(data: crx).map { String(format: "%02x", $0) }.joined()
        let parent = root.appendingPathComponent(id, isDirectory: true)
        let destination = parent.appendingPathComponent(digest, isDirectory: true)
        let receipt = destination.appendingPathComponent(".yab-native-package")
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard try String(contentsOf: receipt, encoding: .utf8) == digest else { throw Crx.Refused.unpack }
            return destination
        }
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".staged-" + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try Crx.unpack(package.zip, into: staging)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        manifest["key"] = package.publicKey.base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        try digest.write(to: staging.appendingPathComponent(".yab-native-package"), atomically: true, encoding: .utf8)
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    static func fetch(_ id: String) async throws -> Data {
        guard ChromiumExtensions.validID(id) else { throw Crx.Refused.notAnID }
        var parts = URLComponents(url: Crx.downloadURL(for: id), resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.map { $0.name == "prodversion" ? URLQueryItem(name: "prodversion", value: "156.0.8078.48") : $0 }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw Crx.Refused.download((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard !data.isEmpty else { throw Crx.Refused.empty }
        return data
    }
}
