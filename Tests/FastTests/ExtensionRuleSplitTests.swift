import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// The shim's split of a regexFilter WebKit refuses into its alternatives
/// (extension-shims.js, `alternatives`).
@MainActor
struct ExtensionRuleSplitTests {
    private func alternatives(_ regex: String) throws -> [String]? {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "    const alternatives = (source) => {"))
        let end = try #require(script.range(of: "    // The extension's rules for each kind", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("const PARTS = 16;\n" + script[start.lowerBound..<end.lowerBound])
        // A const at the top of a script isn't the global object's: asked by name.
        let made = context.evaluateScript("alternatives")?.call(withArguments: [regex])
        try #require(context.exception == nil, "\(context.exception!)")
        return made?.isNull == true ? nil : made?.toArray() as? [String]
    }

    @Test func tampermonkeysInstallRuleIsFourWebKitTakes() throws {
        let parts = try #require(try alternatives(#"^(?:https?|ftp)://[^\#\?]+/[^\#\?]+\.(?:user|tamper)\.js[^/]*$"#))
        #expect(parts == [
            #"^https?://[^\#\?]+/[^\#\?]+\.user\.js[^/]*$"#, #"^https?://[^\#\?]+/[^\#\?]+\.tamper\.js[^/]*$"#,
            #"^ftp://[^\#\?]+/[^\#\?]+\.user\.js[^/]*$"#, #"^ftp://[^\#\?]+/[^\#\?]+\.tamper\.js[^/]*$"#,
        ])
    }

    @Test func capturingGroupsStaySoSubstitutionsMeanTheSame() throws {
        #expect(try alternatives("a(b|c)?d") == ["a(b)d", "a(c)d", "a()d"])
        #expect(try alternatives(#"^(https?)://x/(.*)$"#) == [#"^(https?)://x/(.*)$"#])
    }

    @Test func whatCantBeSplitIsLeftAlone() throws {
        #expect(try alternatives("(a|b)*") == nil)
        #expect(try alternatives(#"(a)\1|b"#) == nil)
        #expect(try alternatives("(?=a)b|c") == nil)
        #expect(try alternatives("(a|b)(c|d)(e|f)(g|h)(i|j)") == nil)
    }

    @Test func aGetOnlyMethodConditionIsLeftOutOthersStay() throws {
        let get: [String: Any] = ["id": 1, "condition": ["regexFilter": "^https://a\\.test/", "requestMethods": ["get"],
                                                         "resourceTypes": ["main_frame"]], "action": ["type": "block"]]
        let mended = try #require(ExtensionRuleMends.mend(get, file: { _ in nil }))
        #expect((mended["condition"] as? [String: Any])?["requestMethods"] == nil)
        let post: [String: Any] = ["id": 2, "condition": ["urlFilter": "a", "requestMethods": ["post"]], "action": ["type": "block"]]
        #expect(ExtensionRuleMends.mend(post, file: { _ in nil }) == nil)
    }
    @Test func aStaticSetSplitsAsDynamicRulesDoWithIdsOfItsOwn() throws {
        let rules: [Any] = [
            ["id": 1275644158, "condition": ["regexFilter": #"\/(Zodiak_horiz|banner_SV-okna|pravo_by)\.(jpg|gif)"#], "action": ["type": "block"]],
            ["id": 1, "condition": ["urlFilter": "||ads.test^"], "action": ["type": "block"]],
            ["id": 3, "condition": ["regexFilter": "^https://a\\.test/(x|y)"], "action": ["type": "allow"]],
        ]
        let split = try #require(ExtensionRuleMends.split(rules) as? [[String: Any]])
        let regexes = split.compactMap { ($0["condition"] as? [String: Any])?["regexFilter"] as? String }
        #expect(regexes == [
            #"\/Zodiak_horiz\.jpg"#, #"\/Zodiak_horiz\.gif"#, #"\/banner_SV-okna\.jpg"#, #"\/banner_SV-okna\.gif"#,
            #"\/pravo_by\.jpg"#, #"\/pravo_by\.gif"#, "^https://a\\.test/x", "^https://a\\.test/y",
        ])
        let ids = split.compactMap { $0["id"] as? Int }
        #expect(ids == [1275644158, 2, 4, 5, 6, 7, 1, 3, 8])
        #expect(Set(ids).count == ids.count)
        #expect(ExtensionRuleMends.split([["id": 1, "condition": ["regexFilter": "(a|b)*"], "action": ["type": "block"]]]) == nil)
    }
    @Test func aRuleThatSubstitutesNothingSplitsIntoPlainWords() throws {
        #expect(ExtensionRuleMends.uncaptured(#"^http://(www\.)?[^(]+(:|/|$)\(x\)"#) == #"^http://(?:www\.)?[^(]+(?::|/|$)\(x\)"#)
        let duck: [Any] = [["id": 7, "condition": ["regexFilter": #"^http://(www\.)?[^.]+\.[^.]+(:|/|$)"#], "action": ["type": "upgradeScheme"]]]
        let split = try #require(ExtensionRuleMends.split(duck) as? [[String: Any]])
        #expect(split.compactMap { ($0["condition"] as? [String: Any])?["regexFilter"] as? String } == [
            #"^http://(?:www\.)?[^.]+\.[^.]+:"#, #"^http://(?:www\.)?[^.]+\.[^.]+/"#, #"^http://(?:www\.)?[^.]+\.[^.]+$"#,
        ])
    }
}
