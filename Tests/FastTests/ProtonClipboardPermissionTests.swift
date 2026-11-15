import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct ProtonClipboardPermissionTests {
    @Test func declaredClipboardReadIsOfferedAndGrantedOnlyWhenChosen() async throws {
        // Exact optional permission names from Proton Pass1.42.0; no code,
        // clipboard access, extension context load, native host or account.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Proton contract fixture", "version": "1.42.0",
            "optional_permissions": ["clipboardRead", "clipboardWrite", "nativeMessaging", "notARealPermission"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let extras = Extensions.extras(of: found)
        #expect(extras.contains { $0.key == "clipboardRead" && $0.words == "Read your clipboard" && !$0.site })
        #expect(extras.contains { $0.key == "clipboardWrite" })
        #expect(extras.contains { $0.key == "nativeMessaging" })
        #expect(!extras.contains { $0.key == "notARealPermission" })
        let id = "test-proton-clipboard-permission-886"
        let keys = ["extensions.optional.\(id)", "extensions.granted.\(id)"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) } }
        keys.forEach { Store.settings.removeObject(forKey: $0) }
        #expect(Extensions.choices(id).isEmpty)
        #expect(Store.settings.stringArray(forKey: keys[1]) == nil)
        Extensions.choose(["clipboardRead": false], for: id)
        #expect(Extensions.choices(id)["clipboardRead"] == false)
        #expect(Store.settings.stringArray(forKey: keys[1]) == nil)
        Extensions.choose(["clipboardRead": true, "notARealPermission": true], for: id)
        #expect(Extensions.choices(id)["clipboardRead"] == true)
        #expect(Store.settings.stringArray(forKey: keys[1]) == ["clipboardRead"])
    }
}
