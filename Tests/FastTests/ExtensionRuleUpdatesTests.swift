import AppKit
import Testing
import WebKit
@testable import Fast

/// A change to an extension's declarativeNetRequest rules is answered at once
/// and gathered with the next ones into one change for WebKit
/// (extension-shims.js, the declarativeNetRequest queue), not answered once
/// WebKit has compiled all of the extension's rules again: 15 to 34 s a
/// change for AdBlock, whose popup waited behind its queued changes and came
/// up blank over a site it had just paused, and whose changes one by one kept
/// a core compiling for minutes after it was added. A bad change is still
/// refused at once.
@MainActor
@Suite(.serialized)
struct ExtensionRuleUpdatesTests {
    @MainActor
    final class Answers: NSObject, WKWebExtensionControllerDelegate {
        var said: [String] = []
        /// Every word from the worker, its shim's included, with the
        /// seconds since the extension was loaded: where a run stopped.
        var heard: [String] = []
        var start = Date()
        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
            let at = String(format: "%.1f", Date().timeIntervalSince(start))
            if let text = message as? String {
                if text.hasPrefix("rules ") { said.append(text) }
                heard.append("\(at) \(text.prefix(60))")
            } else if let body = message as? [String: Any] {
                let api = body["api"] as? String ?? "?"
                let said = api == "debug.error" ? " \(String(describing: body["args"] ?? "").prefix(160))" : ""
                heard.append("\(at) \(applicationIdentifier ?? "?") \(api)\(said)")
            }
            return NSNull()
        }
    }

    /// A blocker with two big rule sets, the second off, whose worker turns
    /// it on (a compile of seconds), adds a dynamic rule, and tries two bad
    /// changes, saying when each was answered and what it read meanwhile;
    /// with the shim, a burst of changes too (WebKit alone would take
    /// minutes over it).
    private func run(shim: Bool, last: Bool = true) async throws -> [String: Any]? {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rule-updates-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        {"manifest_version":3,"name":"Rule updates","version":"1.0","permissions":["declarativeNetRequest","nativeMessaging"],
         "host_permissions":["<all_urls>"],"background":{"service_worker":"worker.js"},
         "declarative_net_request":{"rule_resources":[{"id":"ads","enabled":true,"path":"ads.json"},{"id":"more","enabled":false,"path":"more.json"}]}}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let ads = (0..<30000).map { #"{"id":\#($0 + 1),"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/static-ad-\#($0).gif","resourceTypes":["image"]}}"# }
        try ("[" + ads.joined(separator: ",") + "]").write(to: folder.appendingPathComponent("ads.json"), atomically: true, encoding: .utf8)
        let more = (0..<30000).map { #"{"id":\#($0 + 1),"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/more-ad-\#($0)-banner.js","resourceTypes":["image","script","sub_frame"]}}"# }
        try ("[" + more.joined(separator: ",") + "]").write(to: folder.appendingPathComponent("more.json"), atomically: true, encoding: .utf8)
        try """
        const d = chrome.declarativeNetRequest, say = (t) => chrome.runtime.sendNativeMessage('test', 'rules ' + t);
        const step = (t) => chrome.runtime.sendNativeMessage('test', 'step ' + t).catch(() => {});
        say('start');
        const rule = (id, path) => ({id, priority: 1, action: {type: 'block'}, condition: {urlFilter: path, resourceTypes: ['image']}});
        const timed = async (f) => { const t = Date.now(); try { await f(); return {ms: Date.now() - t}; } catch (e) { return {ms: Date.now() - t, error: String(e && e.message || e)}; } };
        (async () => {
          await new Promise((r) => setTimeout(r, 300));
          const out = {};
          step('enable');
          out.enable = await timed(() => d.updateEnabledRulesets({enableRulesetIds: ['more']}));
          out.enabled = (await d.getEnabledRulesets()).sort().join(',');
          step('add');
          out.add = await timed(() => d.updateDynamicRules({addRules: [rule(500001, '/one.gif')]}));
          out.dynamic = (await d.getDynamicRules()).map((r) => r.id);
          out.duplicate = await timed(() => d.updateDynamicRules({addRules: [rule(500001, '/again.gif')]}));
          out.invalid = await timed(() => d.updateDynamicRules({addRules: [{id: 500002, priority: 1, action: {type: 'nope'}, condition: {}}]}));
          out.dynamicAfter = (await d.getDynamicRules()).map((r) => r.id);
          step('checked');
          // A burst, as AdBlock updates its lists: twenty changes, one after
          // another, then what WebKit has once they have gone to it.
          if (\(shim)) {
          const burst = Date.now();
          for (let i = 0; i < 20; i++) await d.updateDynamicRules({removeRuleIds: [600000 + i - 1], addRules: [rule(600000 + i, '/burst-' + i + '.gif')]});
          out.burstMs = Date.now() - burst;
          step('burst');
          await new Promise((r) => setTimeout(r, 12000));
          step('waited');
          out.burstAfter = (await d.getDynamicRules()).map((r) => r.id).sort((a, b) => a - b);
          }
          say(JSON.stringify(out));
        })().catch((e) => say(JSON.stringify({threw: String(e)})));
        """.write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        if shim { try ExtensionShims.prepare(folder, fresh: true) }
        let controller = TestExtensions.controller()
        let answers = Answers()
        controller.delegate = answers
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
        answers.start = Date()
        try controller.load(context)
        defer { try? controller.unload(context) }
        // WebKit alone compiles 60,000 rules before it answers: 12 s on an
        // idle Mac with macOS 27, past a minute beside a build.
        let came = try await Loaded.until(300, every: .milliseconds(100)) { answers.said.contains(where: { $0 != "rules start" }) }
        if !came, !last { return nil }
        let text = try #require(answers.said.first(where: { $0 != "rules start" }),
                                "shim \(shim): said \(answers.said); heard \(answers.heard); errors \(context.errors.map { ($0 as NSError).localizedDescription + " \(($0 as NSError).userInfo)" })")
        return try #require(try JSONSerialization.jsonObject(with: Data(text.dropFirst("rules ".count).utf8)) as? [String: Any])
    }

    private func ms(_ step: Any?) -> Int { (step as? [String: Any])?["ms"] as? Int ?? -1 }
    private func error(_ step: Any?) -> String? { (step as? [String: Any])?["error"] as? String }

    @Test func aChangeIsAnsweredOnceTakenNotOnceCompiled() async throws {
        let alone = try #require(try await run(shim: false))
        let punctual = Punctuality()
        let shimmed = try #require(try await run(shim: true))
        punctual.stop()
        print("WebKit alone:", alone, "with the shim:", shimmed)
        // WebKit alone answers turning a big set on once it has compiled
        // (12 s on macOS 27, 1.2 s on macOS 26 with these rules); with the
        // shim, a quarter of a second after it took the change.
        #expect(ms(shimmed["enable"]) >= 0 && ms(shimmed["enable"]) < max(1000, ms(alone["enable"]) / 4), "\(shimmed)")
        #expect(error(shimmed["enable"]) == nil, "\(shimmed)")
        // What is read meanwhile has the change, as the extension API specifies.
        #expect(shimmed["enabled"] as? String == "ads,more", "\(shimmed)")
        #expect(error(shimmed["add"]) == nil && (shimmed["dynamic"] as? [Int]) == [500001], "\(shimmed)")
        // A change WebKit refuses is still refused.
        #expect(error(shimmed["duplicate"])?.contains("unique") == true, "\(shimmed)")
        // A rule WebKit can't take is left out, as the shim did before.
        #expect((shimmed["dynamicAfter"] as? [Int]) == [500001], "\(shimmed)")
        // A burst of changes is answered at once and lands whole: sooner
        // than WebKit compiles one change, and within 2 s where the Mac
        // kept time.
        let burst = shimmed["burstMs"] as? Int ?? .max
        #expect(burst < max(2000, ms(alone["enable"])), "\(shimmed)")
        if punctual.held(0.5) { #expect(burst < 2000, "\(shimmed); main actor up to \(punctual.worst) s late") }
        #expect((shimmed["burstAfter"] as? [Int]) == [500001, 600019], "\(shimmed)")
    }
}
