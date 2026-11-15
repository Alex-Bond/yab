import Foundation
import Testing
@testable import Fast

struct ChromiumNativeMessagingTests {
    private let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    private func withFiles(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-host-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("source.json"), root.appendingPathComponent("cef"))
    }

    private func write(_ source: URL, name: String = "com.yab.fixture", origins: [String]? = nil) throws {
        let manifest: [String: Any] = ["name": name, "description": "Fixture, never launched",
                                       "type": "stdio", "path": "/usr/bin/true",
                                       "allowed_origins": origins ?? ["chrome-extension://" + id + "/"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source)
    }

    @Test func registersInCEFRootAndPreservesTheManifest() throws {
        try withFiles { source, root in
            try write(source)
            let host = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root, installed: [id])
            #expect(host.path == root.appendingPathComponent("NativeMessagingHosts/com.yab.fixture.json"))
            #expect(try Data(contentsOf: host.path) == Data(contentsOf: source))
            #expect(try FileManager.default.attributesOfItem(atPath: host.path.path)[.posixPermissions] as? Int == 0o600)
            #expect(try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root, installed: [id]) == host)
        }
    }

    @Test func refusesForeignOriginsAndNeverOverwritesAHost() throws {
        try withFiles { source, root in
            try write(source)
            let host = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root, installed: [id])
            let original = try Data(contentsOf: host.path)
            for (name, origins, installed) in [
                ("../outside", ["chrome-extension://" + id + "/"], Set([id])),
                ("com.yab.fixture", ["chrome-extension://*/"], Set([id])),
                ("com.yab.fixture", ["chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"], Set([id])),
                ("com.yab.fixture", ["chrome-extension://" + id + "/"], Set<String>())
            ] {
                try write(source, name: name, origins: origins)
                do {
                    _ = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root, installed: installed)
                    Issue.record("An invalid registration was accepted")
                } catch { }
            }
            try write(source)
            var changed = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
            changed["description"] = "A different registration"
            try JSONSerialization.data(withJSONObject: changed).write(to: source)
            do {
                _ = try ChromiumNativeMessaging.register(manifestAt: source, dataRoot: root, installed: [id])
                Issue.record("An existing host was overwritten")
            } catch { }
            #expect(try Data(contentsOf: host.path) == original)
        }
    }
}
