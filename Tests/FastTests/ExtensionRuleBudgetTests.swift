import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

/// An extension's rules that match every address, kept under the number
/// WebKit compiles (ExtensionRuleBudget): over it WebKit traps in
/// addUniversalActionsToDFA and Yab goes with it (crash #39).
@MainActor
@Suite(.serialized)
struct ExtensionRuleBudgetTests {
    /// Rules through WebKit's own declarativeNetRequest translator: the
    /// url-filter of each content blocker rule it makes.
    private func filters(_ rules: [[String: Any]]) throws -> [String] {
        let translator = try #require(NSClassFromString("_WKWebExtensionDeclarativeNetRequestTranslator") as? NSObject.Type)
        typealias Translate = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutablePointer<NSArray?>?) -> NSArray
        let selector = NSSelectorFromString("translateRules:errorStrings:")
        let translate = unsafeBitCast(translator.method(for: selector), to: Translate.self)
        var errors: NSArray?
        let out = translate(translator, selector, ["set": rules] as NSDictionary, &errors)
        return out.compactMap { (($0 as? [String: Any])?["trigger"] as? [String: Any])?["url-filter"] as? String }
    }

    private func everywhere(_ filter: String) -> Bool { ExtensionRuleBudget.everything(url: nil, regex: filter) }

    private let cases: [[String: Any]] = [
        // Nothing but initiators: WebKit's ".*" with an if-frame-url.
        ["id": 1, "action": ["type": "block"], "condition": ["initiatorDomains": ["a.example"]]],
        ["id": 2, "action": ["type": "block"], "condition": ["domainType": "thirdParty", "resourceTypes": ["script"]]],
        ["id": 3, "action": ["type": "block"], "condition": ["urlFilter": "*"]],
        ["id": 4, "action": ["type": "block"], "condition": ["urlFilter": "/ads.js"]],
        ["id": 5, "action": ["type": "block"], "condition": ["urlFilter": "||ads.example^"]],
        ["id": 6, "action": ["type": "block"], "condition": ["requestDomains": ["a.example", "b.example"]]],
        ["id": 7, "action": ["type": "block"], "condition": ["regexFilter": ".*"]],
        ["id": 8, "action": ["type": "block"], "condition": ["regexFilter": "^https://x\\.example/"]],
        // Acceptable Ads' shape: one per site, each matching every address.
        ["id": 9, "action": ["type": "allowAllRequests"], "priority": 2,
         "condition": ["urlFilter": "||google.com/afs/", "resourceTypes": ["main_frame"], "requestDomains": ["a.example", "b.example", "c.example"]]],
        ["id": 10, "action": ["type": "allowAllRequests"], "condition": ["resourceTypes": ["sub_frame"]]],
        ["id": 11, "action": ["type": "allow"], "priority": 3, "condition": ["initiatorDomains": ["a.example"], "excludedInitiatorDomains": ["b.a.example"]]],
        ["id": 12, "action": ["type": "upgradeScheme"], "condition": ["initiatorDomains": ["a.example"]]],
        ["id": 13, "action": ["type": "block"], "condition": ["initiatorDomains": ["a.example"], "excludedRequestDomains": ["ok.example"]]],
    ]

    @Test func countedAsWebKitTranslatesThem() throws {
        for rule in cases {
            let made = try filters([rule]).filter(everywhere).count
            #expect(ExtensionRuleBudget.universal(rule) == made, "rule \(rule["id"] ?? "?")")
        }
        #expect(ExtensionRuleBudget.universal(in: cases) == (try filters(cases).filter(everywhere).count))
        // The Acceptable Ads rule: one for every site.
        #expect(ExtensionRuleBudget.universal(cases[8]) == 3)
    }

    /// The shim's own count, for dynamic and session rules, run here: the
    /// same number as the one for shipped sets.
    @Test func shimCountsAsYabDoes() throws {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "    // universal: WebKit compiles"))
        let end = try #require(script.range(of: "    // universal end", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]) + "\n;globalThis.__count = universal;")
        #expect(context.exception == nil)
        let count = try #require(context.objectForKeyedSubscript("__count"))
        for rule in cases {
            #expect(count.call(withArguments: [rule])?.toInt32() == Int32(ExtensionRuleBudget.universal(rule)), "rule \(rule["id"] ?? "?")")
        }
    }

    @Test func setsOverTheLimitStayOff() {
        let sets: [(id: String, enabled: Bool, universal: Int)] = [
            ("easylist", true, 200), ("acceptable", true, 42_023), ("off", false, 90_000),
            ("big", true, 40_000), ("small", true, 300),
        ]
        #expect(ExtensionRuleBudget.over(sets) == ["big"])
        #expect(ExtensionRuleBudget.over([("one", true, ExtensionRuleBudget.limit)]).isEmpty)
        #expect(ExtensionRuleBudget.over([("one", true, ExtensionRuleBudget.limit + 1)]) == ["one"])
        #expect(ExtensionRuleBudget.limit == 65_534)
        #expect(ExtensionRuleBudget.line(0) == nil)
        #expect(ExtensionRuleBudget.line(1) == "A rule list is off: too large to load")
        #expect(ExtensionRuleBudget.line(2) == "2 rule lists are off: too large to load")
    }

    /// A ruleset of `count` rules that each match every address.
    private func everyAddress(_ count: Int, from first: Int = 1) -> [[String: Any]] {
        (0..<count).map { ["id": first + $0, "action": ["type": "block"], "condition": ["initiatorDomains": ["d\(first + $0).example"]]] }
    }

    @Test func preparedManifestKeepsTheListUnderTheLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-budget-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: everyAddress(40_000)).write(to: folder.appendingPathComponent("a.json"))
        try JSONSerialization.data(withJSONObject: everyAddress(30_000, from: 50_000)).write(to: folder.appendingPathComponent("b.json"))
        try JSONSerialization.data(withJSONObject: everyAddress(100, from: 90_000)).write(to: folder.appendingPathComponent("c.json"))
        try JSONSerialization.data(withJSONObject: [["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "/ad"]]])
            .write(to: folder.appendingPathComponent("d.json"))
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Budget", "version": "1", "permissions": ["declarativeNetRequest"],
                                       "declarative_net_request": ["rule_resources": [
                                           ["id": "a", "enabled": true, "path": "a.json"],
                                           ["id": "b", "enabled": true, "path": "b.json"],
                                           ["id": "c", "enabled": true, "path": "c.json"],
                                           ["id": "d", "enabled": false, "path": "d.json"],
                                       ]]]
        let counts = ExtensionRuleMends.mendRuleSets(in: folder, manifest: &manifest)
        #expect(counts == ["a": 40_000, "b": 30_000, "c": 100, "d": 0])
        let sets = try #require((manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]])
        #expect(sets.map { $0["enabled"] as? Bool } == [true, false, true, false])
        #expect(ExtensionRuleBudget.leftOff(in: folder) == ["b"])
        #expect(ExtensionRuleBudget.counts(in: folder) == counts)
        // Prepared again by a later Yab: "b" reads as off by default now,
        // and is still said.
        ExtensionRuleMends.mendRuleSets(in: folder, manifest: &manifest)
        #expect(ExtensionRuleBudget.leftOff(in: folder) == ["b"])
    }

    @Test func rowSaysWhatIsOffAndForgetsWhatTheExtensionTurnedOff() throws {
        let id = "yabbudgettestaaaaaaaaaaaaaaaaaaa"
        let folder = Extensions.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions.shared
        #expect(extensions.rulesLeftOff(id).isEmpty)
        extensions.rulesLeftOff(id, adding: ["big", "bigger"], removing: [])
        #expect(extensions.rulesLeftOff(id) == ["big", "bigger"])
        #expect(ExtensionRuleBudget.leftOff(in: folder) == ["big", "bigger"])
        extensions.rulesLeftOff(id, adding: [], removing: ["big"])
        #expect(extensions.rulesLeftOff(id) == ["bigger"])
        extensions.rulesLeftOff(id, adding: [], removing: ["bigger"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExtensionRuleBudget.leftOffFile).path))
    }

    /// WebKit itself compiles a list at the limit: what Yab keeps on is
    /// never refused for being one too many. (Over it, WebKit traps; the
    /// farm eval evals/extensions/dnr_universal.py shows that one.)
    @Test func webKitCompilesAListAtTheLimit() async throws {
        let rules = everyAddress(ExtensionRuleBudget.limit)
        let translated = try filters(rules)
        #expect(translated.filter(everywhere).count == ExtensionRuleBudget.limit)
        let translator = try #require(NSClassFromString("_WKWebExtensionDeclarativeNetRequestTranslator") as? NSObject.Type)
        typealias Translate = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutablePointer<NSArray?>?) -> NSArray
        let selector = NSSelectorFromString("translateRules:errorStrings:")
        let translate = unsafeBitCast(translator.method(for: selector), to: Translate.self)
        var errors: NSArray?
        let list = translate(translator, selector, ["set": rules] as NSDictionary, &errors)
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: list), encoding: .utf8))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-budget-store-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let compiled: WKContentRuleList? = try await withCheckedThrowingContinuation { done in
            store.compileContentRuleList(forIdentifier: "budget", encodedContentRuleList: json) { list, error in
                if let error { done.resume(throwing: error) } else { done.resume(returning: list) }
            }
        }
        #expect(compiled != nil)
    }
}
