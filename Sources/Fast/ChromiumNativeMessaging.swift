import Foundation
import CryptoKit
import YabCoreClient

/// Register an existing host with CEF's user-data root. Chromium still owns
/// origin checks, process launch and framing. Registration launches nothing.
enum ChromiumNativeMessaging {
    struct Registration: Equatable {
        let name: String
        let path: URL
    }

    static func register(manifestAt source: URL, dataRoot: URL, installed: Set<String>, launcher: URL? = Bundle.main.executableURL) throws -> Registration {
        guard source.isFileURL, dataRoot.isFileURL else {
            throw YabCoreError.remote("Native messaging manifests must be local files")
        }
        let data = try Data(contentsOf: source)
        guard data.count <= 1024 * 1024,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String,
              name.range(of: "^[a-z0-9_]+(?:\\.[a-z0-9_]+)*$", options: .regularExpression) != nil,
              manifest["description"] is String,
              manifest["type"] as? String == "stdio",
              let path = manifest["path"] as? String, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path),
              let origins = manifest["allowed_origins"] as? [String], !origins.isEmpty,
              origins.allSatisfy(validOrigin),
              installed.contains(where: { origins.contains("chrome-extension://" + $0 + "/") }) else {
            throw YabCoreError.remote("Host must allow an installed extension and name an existing executable")
        }
        let folder = dataRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let destination = folder.appendingPathComponent(name + ".json")
        let registered = try registration(of: manifest, data: data, source: source, folder: folder, launcher: launcher)
        if let wrapper = Self.wrapper(name: name, data: data, source: source, folder: folder, launcher: launcher) {
            try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = Data(ChromiumNativeHostLauncher.script(executable: launcher!, manifest: source).utf8)
            try script.write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        }
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == registered else {
                throw YabCoreError.remote("A different native messaging host is already registered")
            }
        } else {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try registered.write(to: destination, options: .withoutOverwriting)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return Registration(name: name, path: destination)
    }

    /// Where a routed host's wrapper goes (ChromiumNativeHostLauncher.routed):
    /// keyed by the manifest, its place and the browser, so a moved app or a
    /// changed host gets a new one. Nil for hosts Chromium launches itself.
    static func wrapper(name: String, data: Data, source: URL, folder: URL, launcher: URL?) -> URL? {
        guard ChromiumNativeHostLauncher.routed.contains(name), let launcher else { return nil }
        let key = SHA256.hash(data: data + Data((source.path + "\n" + launcher.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(".yab-launchers", isDirectory: true).appendingPathComponent(name + "-" + key)
    }

    /// The bytes `register` writes for this manifest: the manifest itself,
    /// or for a routed host the same with its path on the wrapper.
    static func registration(of manifest: [String: Any], data: Data, source: URL, folder: URL, launcher: URL? = Bundle.main.executableURL) throws -> Data {
        guard let name = manifest["name"] as? String,
              let wrapper = Self.wrapper(name: name, data: data, source: source, folder: folder, launcher: launcher) else { return data }
        var routed = manifest
        routed["path"] = wrapper.path
        return try JSONSerialization.data(withJSONObject: routed, options: .sortedKeys)
    }

    /// What `register` would place for the manifest at `source`, nil when
    /// it can't be read.
    static func expected(manifestAt source: URL, dataRoot: URL, launcher: URL? = Bundle.main.executableURL) -> Data? {
        guard let data = try? Data(contentsOf: source),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let folder = dataRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        return try? registration(of: manifest, data: data, source: source, folder: folder, launcher: launcher)
    }

    private static func validOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), url.scheme == "chrome-extension",
              let id = url.host, ChromiumExtensions.validID(id) else { return false }
        return origin == "chrome-extension://" + id + "/"
    }
}
