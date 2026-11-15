import Foundation
import Testing
@testable import Fast

struct ChromiumNativeHostsTests {
    private let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    private func manifest(_ name: String, path: String = "/usr/bin/true", origins: [String]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["name": name, "description": "Fixture, never launched", "type": "stdio",
                                                    "path": path, "allowed_origins": origins ?? ["chrome-extension://" + id + "/"]])
    }

    @Test func adoptsOtherBrowsersHostsForInstalledExtensionsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), edge = root.appendingPathComponent("Edge"), cef = root.appendingPathComponent("cef")
        for folder in [chrome, edge] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try manifest("com.yab.manager").write(to: chrome.appendingPathComponent("com.yab.manager.json"))
        // The first folder's file wins, as in Chromium's own order.
        try manifest("com.yab.manager", path: "/bin/cat").write(to: edge.appendingPathComponent("com.yab.manager.json"))
        try manifest("com.yab.other", origins: ["chrome-extension://" + String(repeating: "b", count: 32) + "/"])
            .write(to: chrome.appendingPathComponent("com.yab.other.json"))
        try manifest("com.yab.mismatch").write(to: chrome.appendingPathComponent("com.yab.renamed.json"))

        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome, edge], onePasswordHelper: nil) == ["com.yab.manager"])
        let placed = cef.appendingPathComponent("NativeMessagingHosts/com.yab.manager.json")
        #expect(try Data(contentsOf: placed) == Data(contentsOf: chrome.appendingPathComponent("com.yab.manager.json")))
        #expect(!FileManager.default.fileExists(atPath: cef.appendingPathComponent("NativeMessagingHosts/com.yab.other.json").path))

        // The app changed its file: the copy Yab made follows it.
        try manifest("com.yab.manager", path: "/bin/echo").write(to: chrome.appendingPathComponent("com.yab.manager.json"))
        ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome], onePasswordHelper: nil)
        #expect(try Data(contentsOf: placed) == Data(contentsOf: chrome.appendingPathComponent("com.yab.manager.json")))
    }

    @Test func bitwardenDesktopManifestKeepsItsExecutableAndExactOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitwarden-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), cef = root.appendingPathComponent("cef")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        let bitwarden = "nngceckbapebfimnlniiiahkandclblb"
        let source = chrome.appendingPathComponent("com.8bit.bitwarden.json")
        try manifest("com.8bit.bitwarden", origins: ["chrome-extension://" + bitwarden + "/"]).write(to: source)
        #expect(ChromiumNativeHosts.adopt(installed: [bitwarden], dataRoot: cef, folders: [chrome], onePasswordHelper: nil) == ["com.8bit.bitwarden"])
        let destination = cef.appendingPathComponent("NativeMessagingHosts/com.8bit.bitwarden.json")
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: root.appendingPathComponent("foreign"), folders: [chrome], onePasswordHelper: nil).isEmpty)
    }

    @Test func neverReplacesAHostPlacedByHand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), cef = root.appendingPathComponent("cef"), chosen = root.appendingPathComponent("chosen.json")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try manifest("com.yab.manager", path: "/bin/cat").write(to: chosen)
        let placed = try ChromiumNativeMessaging.register(manifestAt: chosen, dataRoot: cef, installed: [id])
        try manifest("com.yab.manager").write(to: chrome.appendingPathComponent("com.yab.manager.json"))
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome], onePasswordHelper: nil).isEmpty)
        #expect(try Data(contentsOf: placed.path) == Data(contentsOf: chosen))
    }

    @Test func discoversOnePasswordWithoutAnotherBrowsersManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onepassword-host-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cef = root.appendingPathComponent("cef")
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [], onePasswordHelper: URL(fileURLWithPath: "/usr/bin/true")) == [ChromiumNativeHosts.onePasswordName])
        let file = cef.appendingPathComponent("NativeMessagingHosts/" + ChromiumNativeHosts.onePasswordName + ".json")
        let kept = cef.appendingPathComponent("NativeMessagingHosts/.yab-launchers/" + ChromiumNativeHosts.onePasswordName + ".json")
        let data = try Data(contentsOf: file)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(row["allowed_origins"] as? [String] ?? []) == Set(ChromiumNativeHosts.onePasswordIDs.map { "chrome-extension://" + $0 + "/" }))
        // Chromium starts the browser's signed door, which starts the helper
        // as its child: 1Password checks its parent's signature.
        let script = try String(contentsOfFile: try #require(row["path"] as? String), encoding: .utf8)
        #expect(script.contains(ChromiumNativeHostLauncher.flag) && script.contains(kept.path))
        let source = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: kept)) as? [String: Any])
        #expect(source["path"] as? String == "/usr/bin/true")
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [], onePasswordHelper: URL(fileURLWithPath: "/usr/bin/true")).isEmpty)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func onePasswordHostOfOlderYabMovesBehindTheSignedDoor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onepassword-legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), cef = root.appendingPathComponent("cef")
        let hosts = cef.appendingPathComponent("NativeMessagingHosts")
        for folder in [chrome, hosts] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let source = chrome.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json")
        try manifest(ChromiumNativeHosts.onePasswordName).write(to: source)
        // 0.46.24 copied the file as it was and noted it in its ledger.
        try Data(contentsOf: source).write(to: hosts.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json"))
        try JSONEncoder().encode([ChromiumNativeHosts.onePasswordName]).write(to: hosts.appendingPathComponent(ChromiumNativeHosts.adoptedList))
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome], onePasswordHelper: nil) == [ChromiumNativeHosts.onePasswordName])
        let row = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: hosts.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json"))) as? [String: Any])
        let path = try #require(row["path"] as? String)
        #expect(path.contains("/.yab-launchers/"))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains(source.path))
        // Current now: nothing to redo.
        let placed = try Data(contentsOf: hosts.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json"))
        ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome], onePasswordHelper: nil)
        #expect(try Data(contentsOf: hosts.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json")) == placed)
    }

    @Test func onePasswordFallbackRequiresItsExtensionAndExecutableAndNoManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onepassword-refusal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("chrome"), cef = root.appendingPathComponent("cef")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        #expect(ChromiumNativeHosts.adopt(installed: [String(repeating: "b", count: 32)], dataRoot: cef, folders: [], onePasswordHelper: URL(fileURLWithPath: "/usr/bin/true")).isEmpty)
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [], onePasswordHelper: root.appendingPathComponent("missing")).isEmpty)
        let source = chrome.appendingPathComponent(ChromiumNativeHosts.onePasswordName + ".json")
        for data in [Data("invalid".utf8), try manifest(ChromiumNativeHosts.onePasswordName, origins: ["chrome-extension://" + String(repeating: "b", count: 32) + "/"])] {
            try data.write(to: source)
            #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome], onePasswordHelper: URL(fileURLWithPath: "/usr/bin/true")).isEmpty)
        }
        try FileManager.default.removeItem(at: source)
        try manifest(ChromiumNativeHosts.onePasswordName, path: "/bin/cat").write(to: source)
        _ = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: cef, installed: [id])
        let placed = cef.appendingPathComponent("NativeMessagingHosts/" + ChromiumNativeHosts.onePasswordName + ".json")
        let chosen = try Data(contentsOf: placed)
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [], onePasswordHelper: URL(fileURLWithPath: "/usr/bin/true")).isEmpty)
        #expect(try Data(contentsOf: placed) == chosen)
    }
}
