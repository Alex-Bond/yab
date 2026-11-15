import CryptoKit
import Foundation

/// A probe borrows its selected account's sign-in, but keeps every Codex
/// conversation and index in the probe world. Accounts can carry a probe
/// conversation on through the world's shared session folders.
enum CodexProbe {
    enum SetupError: LocalizedError {
        case unsafePath
        case authUnavailable

        var errorDescription: String? {
            switch self {
            case .unsafePath: return "The test history folder points outside this probe world."
            case .authUnavailable: return "This probe needs the selected account's file sign-in; its Keychain sign-in belongs to the original Codex folder."
            }
        }
    }

    static func home(root: URL, source: URL) -> URL {
        let id = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    static func environment(base: [String: String], root: URL, source: URL) throws -> [String: String] {
        let root = root.standardizedFileURL
        let source = source.standardizedFileURL
        guard root.path != source.path,
              !root.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(root.path + "/") else { throw SetupError.unsafePath }
        let manager = FileManager.default
        let auth = source.appendingPathComponent("auth.json")
        guard manager.fileExists(atPath: auth.path) else { throw SetupError.authUnavailable }
        let home = home(root: root, source: source)
        try privateDirectory(root)
        try privateDirectory(root.appendingPathComponent("accounts", isDirectory: true))
        try privateDirectory(home)
        for name in ["sessions", "archived_sessions"] {
            let shared = root.appendingPathComponent(name, isDirectory: true)
            try privateDirectory(shared)
            try link(home.appendingPathComponent(name), to: shared)
        }

        let ownAuth = home.appendingPathComponent("auth.json")
        try link(ownAuth, to: auth)
        let config = source.appendingPathComponent("config.toml")
        if manager.fileExists(atPath: config.path) {
            let ownConfig = home.appendingPathComponent("config.toml")
            if let existing = try attributes(ownConfig), existing[.type] as? FileAttributeType != .typeRegular {
                throw SetupError.unsafePath
            }
            try Data(contentsOf: config).write(to: ownConfig, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownConfig.path)
        }
        var env = base
        env["CODEX_HOME"] = home.path
        return env
    }

    private static func privateDirectory(_ folder: URL) throws {
        let manager = FileManager.default
        if let existing = try attributes(folder) {
            guard existing[.type] as? FileAttributeType == .typeDirectory else { throw SetupError.unsafePath }
        } else {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private static func link(_ location: URL, to target: URL) throws {
        let manager = FileManager.default
        if let existing = try attributes(location) {
            guard existing[.type] as? FileAttributeType == .typeSymbolicLink,
                  try manager.destinationOfSymbolicLink(atPath: location.path) == target.path else {
                throw SetupError.unsafePath
            }
        } else {
            try manager.createSymbolicLink(at: location, withDestinationURL: target)
        }
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain, error.code == CocoaError.Code.fileReadNoSuchFile.rawValue else { throw error }
            return nil
        }
    }
}
