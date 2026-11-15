import AppKit
import Testing
import WebKit
@testable import Fast

/// Dynamic rules Chrome takes and WebKit refuses, as AdBlock 6.49 adds them
/// (evals/extensions/adblock_dnr.py found both on 2026-10-14):
///
///     {"id":11,"priority":2005,"action":{"type":"modifyHeaders","requestHeaders":
///      [{"header":"x-acceptable-ads","operation":"set","value":"1"}]},
///      "condition":{"urlFilter":"||services.fandom.com/aa-signal","resourceTypes":[…]}}
///     {"id":36,"action":{"type":"redirect","redirect":{"url":"data:video/mp4;base64,…"}},…}
///
/// WebKit refuses the whole change for either ("The header `x-acceptable-ads`
/// is not recognized", "`redirect` specified a non-HTTP `url`"). With the shim
/// the extension sees no error and reads its rules back as it made them; the
/// redirect goes to a file of the same bytes, the header rule stands in as one
/// that matches nothing, and the good rules beside them are taken.
// In ExtensionRulesTests' serialized suite: run beside it, a worker here went
// quiet for good as that suite loaded and unloaded its own extensions.
extension ExtensionRulesTests {
    @MainActor
    final class RefusalAnswers: NSObject, WKWebExtensionControllerDelegate {
        let folder: URL
        var said: [String] = []
        var errors: [String] = []
        var steps: [String] = []
        init(folder: URL) { self.folder = folder }
        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
            if let text = message as? String, text.hasPrefix("rules ") { said.append(text) }
            if let text = message as? String, text.hasPrefix("step ") { steps.append(text) }
            // The browser's side of what the shim asks here.
            if let body = message as? [String: Any], let api = body["api"] as? String {
                let first = (body["args"] as? [Any])?.first
                if api == "debug.error" { errors.append(first as? String ?? "?") }
                if api == "dnr.redirect", let url = first as? String {
                    return ["value": ExtensionRuleMends.redirectFile(url, in: folder) as Any]
                }
            }
            return NSNull()
        }
    }

    private static let acceptableAds = #"{id: 11, priority: 2005, action: {type: 'modifyHeaders', requestHeaders: [{header: 'x-acceptable-ads', operation: 'set', value: '1'}]}, condition: {urlFilter: '||services.fandom.com/aa-signal', resourceTypes: ['other', 'script', 'image', 'main_frame']}}"#
    private static let blankMP4 = #"{id: 36, priority: 1000, action: {type: 'redirect', redirect: {url: 'data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQ=='}}, condition: {urlFilter: '||ads.test/clip.mp4', resourceTypes: ['media']}}"#

    /// Runs `body` (JavaScript with `d`, `out`, `rule` and `tryIt` in scope)
    /// in a worker; `out` and what the shim reported.
    private func refusals(shim: Bool, _ body: String) async throws -> (out: [String: Any], errors: [String], folder: URL) {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rule-refusals-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Rule refusals","version":"1.0","permissions":["declarativeNetRequest","nativeMessaging"],
         "host_permissions":["<all_urls>"],"background":{"service_worker":"worker.js"}}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        const d = chrome.declarativeNetRequest, say = (t) => chrome.runtime.sendNativeMessage('test', 'rules ' + t);
        const rule = (id, path) => ({id, priority: 1, action: {type: 'block'}, condition: {urlFilter: path, resourceTypes: ['image']}});
        const tryIt = async (f) => { try { await f(); return 'ok'; } catch (e) { return String(e && e.message || e); } };
        const step = (t) => chrome.runtime.sendNativeMessage('test', 'step ' + t);
        const settle = () => new Promise((r) => setTimeout(r, 2500));
        (async () => {
          await new Promise((r) => setTimeout(r, 300));
          const out = {};
          step('start');
        \(body)
          say(JSON.stringify(out));
        })().catch((e) => say(JSON.stringify({threw: String(e)})));
        """.write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        if shim { try ExtensionShims.prepare(folder, fresh: true) }
        let controller = WKWebExtensionController(configuration: .init(identifier: UUID()))
        let answers = RefusalAnswers(folder: folder)
        controller.delegate = answers
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
        try controller.load(context)
        defer { try? controller.unload(context) }
        // WebKit answers reads only after the compiles queued before them, other
        // tests' big rule sets too.
        for _ in 0..<900 where answers.said.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let text = try #require(answers.said.first, "errors \(context.errors.map { ($0 as NSError).localizedDescription + " \(($0 as NSError).userInfo)" }); reported \(answers.errors); steps \(answers.steps)")
        let out = try #require(try JSONSerialization.jsonObject(with: Data(text.dropFirst("rules ".count).utf8)) as? [String: Any])
        return (out, answers.errors, folder)
    }

    /// WebKit alone: an unknown header or a data: redirect costs the whole
    /// change, the good rules in it too.
    @Test func webKitAloneRefusesTheWholeChange() async throws {
        let (out, _, folder) = try await refusals(shim: false, """
          out.header = await tryIt(() => d.updateDynamicRules({addRules: [rule(1, '/a.gif'), \(Self.acceptableAds), rule(3, '/b.gif')]}));
          out.redirect = await tryIt(() => d.updateDynamicRules({addRules: [rule(1, '/a.gif'), \(Self.blankMP4)]}));
          out.known = await tryIt(() => d.updateDynamicRules({addRules: [{id: 5, priority: 1, action: {type: 'modifyHeaders', requestHeaders: [{header: 'dnt', operation: 'set', value: '1'}]}, condition: {urlFilter: '||ads.test^'}}]}));
          out.ids = (await d.getDynamicRules()).map((r) => r.id);
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect((out["header"] as? String)?.contains("The header `x-acceptable-ads` is not recognized") == true, "\(out)")
        #expect((out["redirect"] as? String)?.contains("non-HTTP `url`") == true, "\(out)")
        #expect(out["known"] as? String == "ok", "\(out)")
        #expect(out["ids"] as? [Int] == [5], "\(out)")
    }

    /// With the shim, as the extension API specifies: no error, every rule read back as made,
    /// the good ones in WebKit, the redirect to a file of its bytes, the
    /// header rule standing in, and a header WebKit knows kept.
    @Test func chromesRulesAreTakenAsChromeTakesThem() async throws {
        let (out, errors, folder) = try await refusals(shim: true, """
          const made = [rule(1, '/a.gif'), \(Self.acceptableAds), rule(3, '/b.gif'), \(Self.blankMP4),
            {id: 40, priority: 1, action: {type: 'modifyHeaders', requestHeaders: [{header: 'x-acceptable-ads', operation: 'set', value: '1'}, {header: 'dnt', operation: 'set', value: '1'}]}, condition: {urlFilter: '||both.test^'}},
            {id: 41, priority: 1, action: {type: 'redirect', redirect: {url: 'about:blank'}}, condition: {urlFilter: '||blank.test^', resourceTypes: ['sub_frame']}}];
          out.add = await tryIt(() => d.updateDynamicRules({addRules: made}));
          step('added ' + out.add);
          await settle();
          step('settled');
          step('webkit holds ' + JSON.stringify((await globalThis.__yabRealRules('updateDynamicRules')).map((r) => r.id)));
          const read = await d.getDynamicRules();
          out.ids = read.map((r) => r.id).sort((a, b) => a - b);
          const canon = (v) => JSON.stringify(v, (k, x) => x && typeof x === 'object' && !Array.isArray(x) ? Object.keys(x).sort().reduce((o, k) => (o[k] = x[k], o), {}) : x);
          out.asMade = made.every((m) => read.some((r) => canon(r) === canon(m)));
          step('read');
          out.real = await globalThis.__yabRealRules('updateDynamicRules');
          step('real');
          // Taken out again, as the extension API specifies.
          out.remove = await tryIt(() => d.updateDynamicRules({removeRuleIds: [11, 36]}));
          await settle();
          out.idsAfter = (await d.getDynamicRules()).map((r) => r.id).sort((a, b) => a - b);
          out.realAfter = (await globalThis.__yabRealRules('updateDynamicRules')).map((r) => r.id).sort((a, b) => a - b);
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let split = 1_073_741_824, parts = 16
        #expect(out["add"] as? String == "ok", "\(out)")
        #expect(out["ids"] as? [Int] == [1, 3, 11, 36, 40, 41], "\(out)")
        #expect(out["asMade"] as? Bool == true, "\(out)")
        #expect(errors.isEmpty, "\(errors)")
        let real = try #require(out["real"] as? [[String: Any]], "\(out)")
        let byID = Dictionary(real.compactMap { r in (r["id"] as? Int).map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        #expect(byID[1] != nil && byID[3] != nil, "\(real)")
        // The redirect to a file of the same bytes, reachable from pages.
        let redirect = try #require(((byID[split + 36 * parts]?["action"] as? [String: Any])?["redirect"] as? [String: Any]), "\(real)")
        let path = try #require(redirect["extensionPath"] as? String, "\(redirect)")
        #expect(path.hasPrefix("/yab-redirects/") && path.hasSuffix(".mp4"))
        #expect(try Data(contentsOf: folder.appendingPathComponent(String(path.dropFirst()))).prefix(8) == Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]))
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect((manifest["web_accessible_resources"] as? [[String: Any]])?.contains { ($0["resources"] as? [String]) == ["yab-redirects/*"] } == true)
        // Nothing WebKit takes: standing in, matching nothing.
        for id in [11, 41] {
            let condition = try #require(byID[split + id * parts]?["condition"] as? [String: Any], "\(id): \(real)")
            #expect((condition["urlFilter"] as? String)?.contains("yab.invalid") == true)
        }
        // The header WebKit knows stays.
        let both = try #require((byID[split + 40 * parts]?["action"] as? [String: Any])?["requestHeaders"] as? [[String: Any]], "\(real)")
        #expect(both.map { $0["header"] as? String } == ["dnt"])
        #expect(out["remove"] as? String == "ok", "\(out)")
        #expect(out["idsAfter"] as? [Int] == [1, 3, 40, 41], "\(out)")
        #expect(out["realAfter"] as? [Int] == [1, 3, split + 40 * parts, split + 41 * parts], "\(out)")
    }
}
