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

    /// Chrome's open views decide whether the action hook's reload may run:
    /// only its worker open, or nothing said, it may (register 2358).
    @Test func aPageOfItsOwnHoldsTheHooksReload() throws {
        let id = "oejgccbfbmkkpaidnkphaiaecficdnfn"
        func item(_ views: [String]?) throws -> ChromiumExtensions.Item {
            var row: [String: JSONValue] = ["id": .string(id), "name": .string("Toggl Track"), "state": .string("ENABLED")]
            if let views { row["views"] = .array(views.map(JSONValue.string)) }
            return try ChromiumExtensions.Item(.object(row))
        }
        #expect(try item(nil).views == nil)
        #expect(try !item(nil).hasOpenPages)
        #expect(try !item([]).hasOpenPages)
        #expect(try !item(["EXTENSION_SERVICE_WORKER_BACKGROUND"]).hasOpenPages)
        #expect(try item(["EXTENSION_SERVICE_WORKER_BACKGROUND", "TAB_CONTENTS"]).hasOpenPages)
        #expect(try item(["OFFSCREEN_DOCUMENT"]).hasOpenPages)
        #expect(try item(["EXTENSION_SIDE_PANEL"]).hasOpenPages)
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

    /// "Allow in private tabs" is Chrome's per-extension "Allow in Incognito"
    /// for each one that can change: only those that differ are written,
    /// so a second read writes nothing (feedback #1894).
    @Test func privateTabsSwitchSetsEachChangeableExtension() throws {
        func row(_ id: String, incognito: Bool, changeable: Bool) throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("Fixture"), "state": .string("ENABLED"),
                                                 "incognito": .bool(incognito), "incognitoChangeable": .bool(changeable)]))
        }
        let off = try row(String(repeating: "a", count: 32), incognito: false, changeable: true)
        let on = try row(String(repeating: "b", count: 32), incognito: true, changeable: true)
        let fixed = try row(String(repeating: "c", count: 32), incognito: false, changeable: false)
        #expect(off.incognitoChangeable && !off.incognito && on.incognito && !fixed.incognitoChangeable)
        #expect(ChromiumExtensions.incognitoChanges([off, on, fixed], allowed: true) == [off.id])
        #expect(ChromiumExtensions.incognitoChanges([off, on, fixed], allowed: false) == [on.id])
        #expect(ChromiumExtensions.incognitoChanges([on], allowed: true).isEmpty)
        // An old helper's rows say nothing of it: nothing is written.
        let old = try ChromiumExtensions.Item(.object(["id": .string(off.id), "name": .string("Fixture"), "state": .string("ENABLED")]))
        #expect(ChromiumExtensions.incognitoChanges([old], allowed: true).isEmpty)
    }

    @Test func incognitoOperationIsValidatedBeforeStartingCEF() async {
        let manager = ChromiumExtensions(profile: "not-opened", privateMode: false)
        for params: [String: JSONValue] in [["extension": .string("../bad"), "enabled": .bool(true)],
                                            ["extension": .string(String(repeating: "a", count: 32))]] {
            do {
                _ = try await manager.request("extension.incognito", params: params)
                Issue.record("Invalid operation reached CEF")
            } catch { #expect(error is YabCoreError) }
        }
    }

    /// Chrome's "Allow User Scripts" (Chrome 138+) follows the one list's
    /// choice for an extension that asks for userScripts; one the list
    /// hasn't chosen for is left as Chromium has it.
    @Test func userScriptsSwitchFollowsTheOneList() throws {
        func row(on: Bool, changeable: Bool) throws -> ChromiumExtensions.Item {
            try ChromiumExtensions.Item(.object(["id": .string(String(repeating: "d", count: 32)), "name": .string("Tampermonkey"),
                                                 "state": .string("ENABLED"), "userScripts": .bool(on), "userScriptsChangeable": .bool(changeable)]))
        }
        let off = try row(on: false, changeable: true), on = try row(on: true, changeable: true)
        #expect(off.userScriptsChangeable && !off.userScripts && on.userScripts)
        #expect(ChromiumExtensions.userScriptsChange(off, wanted: true) == true)
        #expect(ChromiumExtensions.userScriptsChange(on, wanted: false) == false)
        #expect(ChromiumExtensions.userScriptsChange(on, wanted: true) == nil)
        #expect(ChromiumExtensions.userScriptsChange(off, wanted: nil) == nil)
        // One that doesn't ask for userScripts (or an old helper's row) has no switch.
        #expect(ChromiumExtensions.userScriptsChange(try row(on: false, changeable: false), wanted: true) == nil)
        let old = try ChromiumExtensions.Item(.object(["id": .string(off.id), "name": .string("Fixture"), "state": .string("ENABLED")]))
        #expect(!old.userScriptsChangeable && ChromiumExtensions.userScriptsChange(old, wanted: true) == nil)
        // The choice is kept in the list file; a list written before it reads as unchosen.
        var entry = Installed(id: off.id, name: "Tampermonkey", version: "5.5.1", enabled: true, fromStore: true, permissions: ["userScripts"])
        #expect(try JSONDecoder().decode(Installed.self, from: JSONEncoder().encode(entry)).userScripts == nil)
        entry.userScripts = true
        #expect(try JSONDecoder().decode(Installed.self, from: JSONEncoder().encode(entry)).userScripts == true)
    }

    @Test func userScriptsOperationIsValidatedBeforeStartingCEF() async {
        let manager = ChromiumExtensions(profile: "not-opened", privateMode: false)
        for params: [String: JSONValue] in [["extension": .string("../bad"), "enabled": .bool(true)],
                                            ["extension": .string(String(repeating: "a", count: 32))]] {
            do {
                _ = try await manager.request("extension.userScripts", params: params)
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
