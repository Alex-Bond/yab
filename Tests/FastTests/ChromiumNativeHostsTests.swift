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

        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome, edge]) == ["com.yab.manager"])
        let placed = cef.appendingPathComponent("NativeMessagingHosts/com.yab.manager.json")
        #expect(try Data(contentsOf: placed) == Data(contentsOf: chrome.appendingPathComponent("com.yab.manager.json")))
        #expect(!FileManager.default.fileExists(atPath: cef.appendingPathComponent("NativeMessagingHosts/com.yab.other.json").path))

        // The app changed its file: the copy Yab made follows it.
        try manifest("com.yab.manager", path: "/bin/echo").write(to: chrome.appendingPathComponent("com.yab.manager.json"))
        ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome])
        #expect(try Data(contentsOf: placed) == Data(contentsOf: chrome.appendingPathComponent("com.yab.manager.json")))
    }

    @Test func neverReplacesAHostPlacedByHand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("Chrome"), cef = root.appendingPathComponent("cef"), chosen = root.appendingPathComponent("chosen.json")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try manifest("com.yab.manager", path: "/bin/cat").write(to: chosen)
        let placed = try ChromiumNativeMessaging.register(manifestAt: chosen, dataRoot: cef, installed: [id])
        try manifest("com.yab.manager").write(to: chrome.appendingPathComponent("com.yab.manager.json"))
        #expect(ChromiumNativeHosts.adopt(installed: [id], dataRoot: cef, folders: [chrome]).isEmpty)
        #expect(try Data(contentsOf: placed.path) == Data(contentsOf: chosen))
    }
}
