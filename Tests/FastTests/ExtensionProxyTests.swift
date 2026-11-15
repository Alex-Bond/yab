import Foundation
import Testing
@testable import Fast

@MainActor
struct ExtensionProxyTests {
    @Test func anUnsupportedModeCannotBeAcknowledgedAsDirectTraffic() {
        let invalid: [Any] = [NSNull(), [:] as [String: Any], ["mode": "auto_detect"], ["mode": "not-a-mode"]]
        for value in invalid {
            #expect(ExtensionProxy.settingError(value) != nil)
        }
        for mode in ["direct", "system", "fixed_servers", "pac_script"] {
            #expect(ExtensionProxy.settingError(["mode": mode]) == nil)
        }
    }

    @Test func chromesBypassListBecomesDomains() {
        let domains = ExtensionProxy.bypass(["<local>", "*.example.com", ".corp.test", "http://bar.net:8080", "10.0.0.0/8", "*"])
        #expect(domains.contains("localhost"))
        #expect(domains.contains("127.0.0.1"))
        #expect(domains.contains("example.com"))
        #expect(domains.contains("corp.test"))
        #expect(domains.contains("bar.net"))
        #expect(!domains.contains { $0.contains("/") || $0.contains("*") })
    }

    @Test func fixedServersMakeOneProxy() {
        let value: [String: Any] = ["mode": "fixed_servers", "rules": [
            "singleProxy": ["scheme": "https", "host": "node.example.net", "port": 4443], "bypassList": ["<local>"]]]
        #expect(ExtensionProxy.configurations(for: value).count == 1)
        #expect(ExtensionProxy.configurations(for: ["mode": "system"]).isEmpty)
        #expect(ExtensionProxy.configurations(for: ["mode": "direct"]).isEmpty)
    }

    @Test func aPACScriptsDefaultIsItsProxy() {
        let script = "function FindProxyForURL(url, host) { if (isPlainHostName(host) || shExpMatch(host, '*.local')) return 'DIRECT'; return 'HTTPS node.example.net:4443; DIRECT'; }"
        let made = ExtensionProxy.configurations(for: ["mode": "pac_script", "pacScript": ["data": script]])
        #expect(made.count == 1)
        let direct = ExtensionProxy.configurations(for: ["mode": "pac_script", "pacScript": ["data": "function FindProxyForURL() { return 'DIRECT'; }"]])
        #expect(direct.isEmpty)
    }
    @Test func aPacScriptByAddressIsReadFromTheExtensionsOwnFolderOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pac"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = "function FindProxyForURL() { return 'PROXY 127.0.0.1:8080'; }"
        try script.write(to: folder.appendingPathComponent("pac/proxy.pac"), atomically: true, encoding: .utf8)
        #expect(await ExtensionProxy.load("chrome-extension://abc/pac/proxy.pac", id: "abc", folder: folder) == script)
        #expect(await ExtensionProxy.load("chrome-extension://other/pac/proxy.pac", id: "abc", folder: folder) == nil)
        #expect(await ExtensionProxy.load("chrome-extension://abc/../../etc/hosts", id: "abc", folder: folder) == nil)
        let data = "data:application/x-ns-proxy-autoconfig;base64," + Data(script.utf8).base64EncodedString()
        #expect(await ExtensionProxy.load(data, id: "abc", folder: folder) == script)
        #expect(await ExtensionProxy.load("file:///etc/hosts", id: "abc", folder: folder) == nil)
    }
}
