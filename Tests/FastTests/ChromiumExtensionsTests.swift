import Foundation
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumExtensionsTests {
    @Test func rejectsPathsAndInjectedIDs() {
        #expect(ChromiumExtensions.validID("aeblfdkhhhdcdjpifhhbdiojplfjncoa"))
        for id in ["../manifest.json", "local-fixture", String(repeating: "z", count: 32),
                   String(repeating: "a", count: 31), "a');throw Error('injected')//"] {
            #expect(!ChromiumExtensions.validID(id))
        }
    }

    @Test func unknownStatesAreDisabledAndOptionsStayInTheExtension() throws {
        let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        var row: [String: JSONValue] = ["id": .string(id), "name": .string("Fixture"),
                                      "state": .string("FUTURE_STATE"), "optionsURL": .string("https://example.com")]
        let unknown = try ChromiumExtensions.Item(.object(row))
        #expect(!unknown.enabled)
        #expect(unknown.optionsURL == nil)
        row["state"] = .string("ENABLED")
        row["optionsURL"] = .string("chrome-extension://" + id + "/options.html")
        let enabled = try ChromiumExtensions.Item(.object(row))
        #expect(enabled.enabled)
        #expect(enabled.optionsURL?.host == id)
        row["optionsURL"] = .string("chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/options.html")
        #expect(try ChromiumExtensions.Item(.object(row)).optionsURL == nil)
    }

    @Test func privateAndInvalidOperationsFailBeforeStartingCEF() async {
        let manager = ChromiumExtensions(profile: "not-opened", privateMode: false)
        let secret = ChromiumExtensions(profile: "not-opened-private", privateMode: true)
        let operations: [(ChromiumExtensions, String, [String: JSONValue])] = [
            (secret, "extension.list", [:]),
            (manager, "shutdown", [:]),
            (manager, "extension.review", ["manifest": .string("not JSON")]),
            (manager, "extension.review", ["manifest": .string("[]")]),
            (manager, "extension.review", ["manifest": .string(String(repeating: " ", count: 1_000_001))]),
            (manager, "extension.setEnabled", ["extension": JSONValue.string("../bad")]),
            (manager, "extension.setEnabled", ["extension": .string(String(repeating: "a", count: 32))]),
            (manager, "extension.remove", ["extension": .string("../bad")]),
            (manager, "extension.remove", ["extension": .string(String(repeating: "a", count: 32))]),
            (manager, "extension.remove", ["extension": .string(String(repeating: "a", count: 32)), "userApproved": .bool(false)])
        ]
        for (target, method, params) in operations {
            do {
                _ = try await target.request(method, params: params)
                Issue.record("Invalid operation reached CEF")
            } catch { #expect(error is YabCoreError) }
        }
    }

    @Test func storeBridgeRequiresTheSecureStoreOrigin() {
        #expect(ChromiumStoreBridge.accepts(URL(string: "https://chromewebstore.google.com/detail/name/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
        for address in ["http://chromewebstore.google.com/", "https://chromewebstore.google.com:444/", "https://chromewebstore.google.com.evil.test/", "https://evil.test/chromewebstore.google.com"] {
            #expect(!ChromiumStoreBridge.accepts(URL(string: address)))
        }
    }

    @Test func profilesDoNotShareAnInstalledListWithPrivateTabs() {
        let normal = ChromiumExtensions.shared(profile: "fixture-profile")
        #expect(normal === ChromiumExtensions.shared(profile: "fixture-profile"))
        #expect(normal !== ChromiumExtensions.shared(profile: "fixture-profile", privateMode: true))
        #expect(normal !== ChromiumExtensions.shared(profile: "another-fixture-profile"))
    }

    @Test func nativeImportIncludesChromeOnlyGrantsAndContentScriptSites() {
        let manifest: [String: Any] = [
            "permissions": ["storage", "proxy", "history"],
            "host_permissions": ["https://example.com/*"],
            "content_scripts": [["matches": ["https://other.test/*"]]],
            "optional_permissions": ["debugger"],
            "optional_host_permissions": ["<all_urls>"]
        ]
        let required = ChromiumExtensionGrants.required(in: manifest)
        let old = ChromiumExtensionGrants.normalized(["storage", "yab:history", "site:https://example.com/*"])
        #expect(required.subtracting(old) == ["permission:proxy", "site:https://other.test/*"])
        #expect(!required.contains("permission:debugger"))
        #expect(!required.contains("site:<all_urls>"))
        #expect(ChromiumExtensionGrants.normalized(["<all_urls>", "https://example.com/*"]) == ["site:<all_urls>", "site:https://example.com/*"])
    }
}
