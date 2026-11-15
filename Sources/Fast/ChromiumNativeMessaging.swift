import Foundation
import YabCoreClient

/// Register an existing host with CEF's user-data root. Chromium still owns
/// origin checks, process launch and framing. Registration launches nothing.
enum ChromiumNativeMessaging {
    struct Registration: Equatable {
        let name: String
        let path: URL
    }

    static func register(manifestAt source: URL, dataRoot: URL, installed: Set<String>) throws -> Registration {
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
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw YabCoreError.remote("A different native messaging host is already registered")
            }
        } else {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: destination, options: .withoutOverwriting)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return Registration(name: name, path: destination)
    }

    private static func validOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), url.scheme == "chrome-extension",
              let id = url.host, ChromiumExtensions.validID(id) else { return false }
        return origin == "chrome-extension://" + id + "/"
    }
}
