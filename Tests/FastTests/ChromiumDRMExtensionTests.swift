import Foundation
import JavaScriptCore
import Testing
import WebKit
import YabCoreClient
@testable import Fast

@Suite @MainActor
struct ChromiumDRMExtensionTests {
    @Test func grantAndManifestGuardsComposeWithoutLexicalRedeclarations() throws {
        let grant = try ChromiumDRMExtensionScripts.guardSource(matches: ["http://127.0.0.1/*"], excludes: [], globs: [], excludeGlobs: [])
        let manifest = try ChromiumDRMExtensionScripts.guardSource(matches: ["<all_urls>"], excludes: ["https://private.test/*"], globs: [], excludeGlobs: [])
        let context = try #require(JSContext())
        // Parse the exact composition used by declarative JS and CSS injection.
        // Browser globals are deliberately not evaluated by this parser check.
        _ = context.evaluateScript("new Function(" + (try ChromiumDRMExtensionScripts.json(grant + manifest + "globalThis.witness=true;")) + ")")
        #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
    }
    /// What a page's content script passes can hold what JSON can't (a Date,
    /// NaN, Infinity). The call fails with a Swift error. On 0.46.18
    /// JSONSerialization raised an Objective-C exception out of the task
    /// instead, which left the main actor's executor record dangling (and
    /// would abort this test process).
    @Test func pageValuesJSONCannotHoldFailTheCallWithoutRaising() async throws {
        let session = ChromiumDRMExtensionSession(profile: "json-test", privateMode: true, store: .nonPersistent())
        let unserializable: [Any] = [[Date()], [Double.nan], ["deep": [Double.infinity]]]
        for args in unserializable {
            await #expect(throws: YabCoreError.self) {
                _ = try await session.request("ext.bridge.invoke", ["op": "runtime.sendMessage", "args": args])
            }
        }
        let plain = try ChromiumDRMExtensionSession.json(["args": ["text", 1, true, NSNull()]])
        #expect(String(decoding: plain, as: UTF8.self).contains("text"))
    }
    @Test func matchPatternsKeepDNSBoundariesSchemeAndPath() {
        for url in ["https://spotify.com/play", "https://open.spotify.com/play?x=1"] {
            #expect(ChromiumDRMExtensionScripts.matches("https://*.spotify.com/play*", url: URL(string: url)!))
        }
        for url in ["https://evilspotify.com/play", "https://spotify.com.evil.test/play", "http://spotify.com/play", "https://spotify.com/account", "file:///play"] {
            #expect(!ChromiumDRMExtensionScripts.matches("https://*.spotify.com/play*", url: URL(string: url)!))
        }
        #expect(ChromiumDRMExtensionScripts.matches("http://127.0.0.1/*", url: URL(string: "http://127.0.0.1:1234/")!))
    }
    @Test func dnrUsesOnlyEnabledRuleSetsAndRejectsUnsupportedSemantics() throws {
        let rule: [String: Any] = ["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "/blocked.js", "resourceTypes": ["script"]]]
        let source = try ChromiumDRMExtensionScripts.json([rule])
        let entry: [String: Any] = ["manifest": ["declarative_net_request": ["rule_resources": [["id": "on", "path": "on.json"], ["id": "off", "path": "off.json"]]]], "files": ["on.json": source, "off.json": source], "grants": ["http://127.0.0.1/*"]]
        let result = try ChromiumDRMExtensionRules.rules(entry: entry, snapshot: ["enabled": ["on"]])
        #expect(result.count == 1)
        let trigger = try #require(result.first?["trigger"] as? [String: Any])
        #expect(trigger["resource-type"] as? [String] == ["script"])
        #expect((trigger["if-top-url"] as? [String])?.count == 1)
        let unsupported: [String: Any] = ["id": 2, "action": ["type": "modifyHeaders"], "condition": [:]]
        #expect(throws: (any Error).self) { try ChromiumDRMExtensionRules.rules(entry: entry, snapshot: ["dynamic": [unsupported]]) }
    }
    @Test func dnrAnchorsAndSeparatorsRemainDistinct() {
        let pattern = ChromiumDRMExtensionRules.urlFilter("||ads.example^")
        #expect("https://ads.example/script.js".range(of: pattern, options: .regularExpression) != nil)
        #expect("https://ads.example.evil/script.js".range(of: pattern, options: .regularExpression) == nil)
        #expect("https://evilads.example/script.js".range(of: pattern, options: .regularExpression) == nil)
    }
    @Test func reusedWireTabIDCannotRouteIntoThePreviousHelpersProfile() {
        let oldHelper = NSObject(), activeHelper = NSObject()
        let endpoints: [(profile: String, control: String, core: AnyObject)] = [
            ("old-profile", "tab-1", oldHelper), ("active-profile", "tab-1", activeHelper)
        ]
        let owner = endpoints.first {
            ChromiumDRMExtensionSession.owns(control: $0.control, core: $0.core,
                eventTab: "tab-1", activeCore: activeHelper)
        }
        #expect(owner?.profile == "active-profile")
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: oldHelper,
            eventTab: "tab-1", activeCore: activeHelper))
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: activeHelper,
            eventTab: "tab-2", activeCore: activeHelper))
        #expect(!ChromiumDRMExtensionSession.owns(control: "tab-1", core: nil,
            eventTab: "tab-1", activeCore: activeHelper))
    }

}
