import Foundation
import Combine
import YabCoreClient
import WebKit

/// Native Chrome extensions belong to a CEF profile, never a WebKit controller.
/// The management document is temporary and never replaces the selected page.
@MainActor
final class ChromiumExtensions: ObservableObject {
    private static var profiles: [String: ChromiumExtensions] = [:]
    static func shared(profile: String, privateMode: Bool = false, store: WKWebsiteDataStore? = nil) -> ChromiumExtensions {
        let scope = store.map { $0.isPersistent ? ($0.identifier?.uuidString ?? "default") : String(describing: ObjectIdentifier($0)) } ?? "unbound"
        let key = (privateMode ? "private:" : "regular:") + profile + ":" + scope
        if let value = profiles[key] { return value }
        let value = ChromiumExtensions(profile: profile, privateMode: privateMode)
        value.associationStore = store
        profiles[key] = value
        return value
    }

    static func retirePrivate(_ profile: String) {
        profiles = profiles.filter { !$0.key.hasPrefix("private:" + profile + ":") }
    }

    struct Item: Equatable, Identifiable {
        let id: String
        let name: String
        let version: String
        let state: String
        let optionsURL: URL?
        let about: String
        let iconData: Data?
        var enabled: Bool { state == "ENABLED" }

        init(_ value: JSONValue) throws {
            guard let id = value["id"].string, ChromiumExtensions.validID(id),
                  let name = value["name"].string, let state = value["state"].string else {
                throw YabCoreError.protocolViolation("Malformed Chromium extension")
            }
            self.id = id; self.name = name; self.state = state
            version = value["version"].string ?? ""
            about = value["description"].string ?? ""
            let image = value["iconData"].string ?? ""
            iconData = image.hasPrefix("data:image/png;base64," ) && image.count < 200_000
                ? Data(base64Encoded: String(image.dropFirst("data:image/png;base64,".count))) : nil
            let options = value["optionsURL"].string.flatMap(URL.init(string:))
            optionsURL = options?.scheme == "chrome-extension" && options?.host == id ? options : nil
        }
    }

    let profile: String
    let privateMode: Bool
    private var associationStore: WKWebsiteDataStore?
    @Published private(set) var items: [Item] = []
    @Published var failure: String?
    @Published var busy = false
    var importing = false
    /// The column's pin order (ChromiumExtensionImport), cached off disk.
    /// Filled silently on first read; saveMigration announces changes.
    var pinCache: [String]?
    /// The enabled set the other browsers' host files were last adopted for.
    var hostsAdoptedFor: Set<String> = []
    private var tail: Task<JSONValue, Error>?

    init(profile: String, privateMode: Bool) {
        self.profile = profile; self.privateMode = privateMode
    }

    nonisolated static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
    }

    func list(connectedTo core: YabCoreClient? = nil) async throws -> [Item] {
        let result = try await request("extension.list", connectedTo: core)
        guard case .array(let rows) = result else { throw YabCoreError.protocolViolation("Expected an extension list") }
        let found = try rows.map(Item.init)
        if items != found { items = found }
        adoptNativeHosts()
        return found
    }

    /// Chrome computes its own install warnings before the package is loaded.
    func permissionWarnings(folder: URL) async throws -> [String] {
        guard folder.isFileURL else { throw Crx.Refused.unpack }
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard data.count <= 1_000_000, let manifest = String(data: data, encoding: .utf8) else { throw Crx.Refused.unpack }
        let result = try await request("extension.review", params: ["manifest": .string(manifest)])
        guard case .array(let rows) = result, rows.allSatisfy({ $0.string != nil }) else {
            throw YabCoreError.protocolViolation("Expected Chrome permission warnings")
        }
        return rows.compactMap(\.string)
    }

    /// The caller has already chosen the folder or approved an import.
    func load(folder: URL) async throws {
        guard folder.isFileURL else { throw YabCoreError.remote("Choose a local extension folder") }
        _ = try await request("extension.load", params: ["path": .string(folder.path)])
    }

    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        _ = try await request("extension.setEnabled", params: ["extension": .string(id), "enabled": .bool(enabled)])
        _ = try await list()
    }

    /// Forward only the native Settings confirmation, never a page request.
    func remove(_ id: String, userApproved: Bool) async throws {
        _ = try await request("extension.remove", params: ["extension": .string(id), "userApproved": .bool(userApproved)])
        _ = try await list()
    }

    func registerNativeHost(manifestAt source: URL) async throws -> ChromiumNativeMessaging.Registration {
        let installed = Set(try await list().map(\.id))
        return try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: Store.file("Chromium"), installed: installed)
    }

    /// Call after the install review has approved the package.
    func install(_ crx: Data, id: String) async throws -> Item {
        guard !privateMode else { throw YabCoreError.remote("Extension management is unavailable in private profiles") }
        let root = Store.file("ChromiumPackages")
        let folder = try await Task.detached(priority: .userInitiated) {
            try ChromiumExtensionPackages.prepare(crx, id: id, root: root)
        }.value
        try await load(folder: folder)
        guard let installed = try await list().first(where: { $0.id == id }) else {
            throw YabCoreError.remote("Chromium did not install the verified store ID")
        }
        return installed
    }

    func installFromStore(_ id: String) async throws -> Item {
        let data = try await ChromiumExtensionPackages.fetch(id)
        return try await install(data, id: id)
    }

    func request(_ method: String, params: [String: JSONValue] = [:], connectedTo expected: YabCoreClient? = nil) async throws -> JSONValue {
        guard !privateMode else { throw YabCoreError.remote("Extension management is unavailable in private profiles") }
        guard ["extension.list", "extension.review", "extension.load", "extension.setEnabled", "extension.remove"].contains(method) else {
            throw YabCoreError.remote("Unknown extension operation")
        }
        if method == "extension.review" {
            guard let manifest = params["manifest"]?.string, manifest.utf8.count <= 1_000_000,
                  let data = manifest.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw YabCoreError.remote("A valid extension manifest is required")
            }
        }
        if method == "extension.setEnabled" {
            guard let id = params["extension"]?.string, Self.validID(id), case .bool? = params["enabled"] else {
                throw YabCoreError.remote("A Chrome extension ID and enabled value are required")
            }
        }
        if method == "extension.remove" {
            guard let id = params["extension"]?.string, Self.validID(id) else {
                throw YabCoreError.remote("A Chrome extension ID is required")
            }
            guard params["userApproved"] == .bool(true) else {
                throw YabCoreError.remote("Confirm removal in Yab first")
            }
        }
        let previous = tail
        let store = associationStore
        let task = Task { @MainActor [profile, store, privateMode] () throws -> JSONValue in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard let store else { throw ChromiumPersistentProfiles.Refused.unverifiedAssociation }
            try ChromiumPrivateProfiles.authorize(profile, store: store, privateMode: privateMode)
            let core: YabCoreClient
            if let expected {
                guard ChromiumProcess.shared.isCurrent(expected) else { throw YabCoreError.disconnected }
                core = expected
            } else { core = try await ChromiumProcess.shared.connection() }
            try await core.openProfile(profile, privateMode: privateMode)
            let created = try await core.request("extension.open", params: ["profile": .string(profile)])
            guard let tab = created["tab"].string else { throw YabCoreError.protocolViolation("Missing management tab") }
            do {
                _ = try await core.waitForDocument(tab: tab, profile: profile, url: "chrome://extensions/")
                var arguments = params; arguments["tab"] = .string(tab)
                let result = try await core.request(method, params: arguments)
                if method == "extension.remove", let extensionID = params["extension"]?.string {
                    // A native confirmation is outstanding, not a hung
                    // uninstallation. Its card times out after two minutes.
                    let deadline = Date().addingTimeInterval(result["nativeConsent"] == .bool(true) ? 130 : 15)
                    while true {
                        let status = try await core.request("extension.removalState", params: ["tab": .string(tab), "extension": .string(extensionID)])
                        if let error = status["error"].string { throw YabCoreError.remote(error) }
                        let list = try await core.request("extension.list", params: ["tab": .string(tab)])
                        guard case .array(let rows) = list else { throw YabCoreError.protocolViolation("Expected an extension list") }
                        if !rows.contains(where: { $0["id"].string == extensionID }) { break }
                        guard Date() < deadline else { throw YabCoreError.remote("Chrome did not finish removing the extension") }
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                try await core.closeTab(tab)
                return result
            } catch {
                try? await core.closeTab(tab)
                throw error
            }
        }
        tail = task
        return try await task.value
    }
}
