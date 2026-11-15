import AppKit
import CryptoKit
import Testing
import WebKit
@testable import Fast

/// Replacing a blocker's filters is one change. Rejecting an oversized
/// replacement must preserve both the enabled sets and earlier queued work.
@MainActor
@Suite(.serialized)
struct ExtensionRuleAtomicTests {
    /// PageScript removes one final newline before substituting shim vars.
    /// Bind to the raw resource the running test actually selected, before
    /// making a fixture. A stale/missing A/B resource is a setup failure.
    private func sourceBinding() throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedArm = environment["YAB_RULE_ATOMIC_ARM"]
        let expected = environment["YAB_RULE_ATOMIC_EXPECTED_SCRIPT_SHA"]
        let arm: String
        if requestedArm == nil && expected == nil {
            arm = "standalone"
        } else {
            arm = try #require(requestedArm)
            try #require(["baseline", "candidate"].contains(arm))
            _ = try #require(expected)
        }
        let url = try #require(PageScript.url("extension-shims"))
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expected {
            try #require(hash == expected, "wrong extension-shims resource: \(url.path), \(hash), expected \(expected)")
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        // The production script also expands the bundled file-system shim.
        text = text.replacingOccurrences(of: "__YAB_FILE_SYSTEM__", with: PageScript.load("legacy-file-system"))
        try #require(ExtensionShims.script == text)
        emit("RULE_ATOMIC_SOURCE", ["arm": arm, "script_sha256": hash])
    }

    private func emit(_ marker: String, _ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(marker + " " + String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private final class Answers: NSObject, WKWebExtensionControllerDelegate {
        let owner: Extensions
        var budgetCalls = 0
        var errors: [String] = []

        init(owner: Extensions) { self.owner = owner }

        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                    toApplicationWithIdentifier applicationIdentifier: String?,
                                    for extensionContext: WKWebExtensionContext) async throws -> Any? {
            // Use the production bridge, including its on-disk ruleset
            // counts. No substitute budget or rules implementation here.
            guard applicationIdentifier == ExtensionShims.application else { return NSNull() }
            if let body = message as? [String: Any] {
                if body["api"] as? String == "dnr.budget" { budgetCalls += 1 }
                if body["api"] as? String == "debug.error" {
                    errors.append((body["args"] as? [Any])?.first as? String ?? "?")
                }
            }
            return try await ExtensionShims.answer(message, from: extensionContext, owner: owner)
        }
    }

    @MainActor
    private final class Fixture {
        let owner: Extensions
        let browser: Browser
        let controller: WKWebExtensionController
        let context: WKWebExtensionContext
        let answers: Answers
        let folder: URL
        let storage: URL
        let driver: WKWebView
        let reader: WKWebView
        let page: WKWebView
        let server: LocalNetworkFixture

        init(owner: Extensions, browser: Browser, controller: WKWebExtensionController, context: WKWebExtensionContext,
             answers: Answers, folder: URL, storage: URL, driver: WKWebView, reader: WKWebView,
             page: WKWebView, server: LocalNetworkFixture) {
            self.owner = owner
            self.browser = browser
            self.controller = controller
            self.context = context
            self.answers = answers
            self.folder = folder
            self.storage = storage
            self.driver = driver
            self.reader = reader
            self.page = page
            self.server = server
        }

        func close() {
            driver.stopLoading()
            reader.stopLoading()
            page.stopLoading()
            server.stop()
            try? controller.unload(context)
            ExtensionRules.forget(context.uniqueIdentifier)
            owner.shutDown()
            Self.closeBrowser(browser)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: storage)
        }

        static func closeBrowser(_ browser: Browser) {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.tabs.forEach { $0.close() }
            if let windowID = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
            }
        }

        func run(_ body: String) async throws -> [String: Any] {
            let value = try await driver.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            return try #require(value as? [String: Any])
        }

        /// This page was added after preparation and has no injected shim.
        /// It can only read native state, so pending overlays cannot pass
        /// the post-flush assertions and the huge set is never raw-enabled.
        func nativeSets() async throws -> [String] {
            let value = try await reader.callAsyncJavaScript(
                "return (await chrome.declarativeNetRequest.getEnabledRulesets()).sort();",
                arguments: [:], in: nil, contentWorld: .page)
            return try #require(value as? [String])
        }

        func waitForNative(_ expected: [String]) async throws {
            let arrived = try await Loaded.until(10, every: .milliseconds(50)) {
                try await self.nativeSets() == expected
            }
            let actual = try await nativeSets()
            #expect(arrived, "native sets \(actual); expected \(expected); errors \(answers.errors)")
        }

        /// Both images are valid and served by the same loopback endpoint.
        /// The server records requests independently of page error events.
        func images() async throws -> [String: Any] {
            let tag = UUID().uuidString
            let result = try await page.callAsyncJavaScript("""
            const load = (path) => new Promise((resolve) => {
              const image = new Image();
              image.onload = () => resolve('loaded');
              image.onerror = () => resolve('error');
              image.src = path + '?tag=' + tag;
              document.body.append(image);
            });
            const result = await Promise.race([
              Promise.all([load('/atomic-blocked.gif'), load('/atomic-control.gif')]),
              new Promise((resolve) => setTimeout(() => resolve(['timeout', 'timeout']), 5000))
            ]);
            return {blocked: result[0], control: result[1]};
            """, arguments: ["tag": tag], in: nil, contentWorld: .page)
            var out = try #require(result as? [String: Any])
            out["blocked_requests"] = server.requests.filter { $0.path == "/atomic-blocked.gif?tag=" + tag }.count
            out["control_requests"] = server.requests.filter { $0.path == "/atomic-control.gif?tag=" + tag }.count
            return out
        }

        static func blocks(_ observed: [String: Any]) -> Bool {
            observed["blocked"] as? String == "error" && observed["control"] as? String == "loaded"
                && observed["blocked_requests"] as? Int == 0 && observed["control_requests"] as? Int == 1
        }

        func reset() async throws {
            let out = try await run("""
            await window.atomic.checked();
            await chrome.declarativeNetRequest.updateEnabledRulesets({enableRulesetIds: ['base'], disableRulesetIds: ['small']});
            return {ok: true};
            """)
            try #require(out["ok"] as? Bool == true)
            try await waitForNative(["base"])
        }
    }

    private func installed() async throws -> Fixture {
        try sourceBinding()
        try #require(Store.testing)
        _ = NSApplication.shared
        let owner = Extensions(signIn: UUID())
        let browser = Browser(windowID: UUID())
        owner.browser = browser
        let controller = TestExtensions.controller()
        let answers = Answers(owner: owner)
        controller.delegate = answers
        let id = "atomic" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let folder = Extensions.folder(for: id)
        var loaded: WKWebExtensionContext?
        var storage: URL?
        var endpoint: LocalNetworkFixture?
        var complete = false
        defer {
            if !complete {
                endpoint?.stop()
                if let loaded { try? controller.unload(loaded) }
                ExtensionRules.forget(id)
                owner.shutDown()
                Fixture.closeBrowser(browser)
                try? FileManager.default.removeItem(at: folder)
                if let storage { try? FileManager.default.removeItem(at: storage) }
            }
        }
        let server = try LocalNetworkFixture()
        endpoint = server
        server.route("/atomic-page", .init("<!doctype html><body>Rule atomicity</body>"))
        var image = LocalNetworkFixture.Reply("")
        image.type = "image/gif"
        image.body = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        server.route("/atomic-blocked.gif", image)
        server.route("/atomic-control.gif", image)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Atomic filter replacement","version":"1.0","permissions":["declarativeNetRequest","nativeMessaging"],"host_permissions":["<all_urls>"],"declarative_net_request":{"rule_resources":[{"id":"base","enabled":true,"path":"base.json"},{"id":"small","enabled":false,"path":"small.json"},{"id":"huge","enabled":false,"path":"huge.json"}]}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let tiny = #"{"id":1,"action":{"type":"block"},"condition":{"initiatorDomains":["atomic.invalid"]}}"#
        let blocking = #"{"id":2,"action":{"type":"block"},"condition":{"urlFilter":"/atomic-blocked.gif","resourceTypes":["image"]}}"#
        try ("[" + tiny + "," + blocking + "]").write(to: folder.appendingPathComponent("base.json"), atomically: true, encoding: .utf8)
        try ("[" + tiny + "]").write(to: folder.appendingPathComponent("small.json"), atomically: true, encoding: .utf8)
        // Disabled in the manifest. Only the protected production shim may
        // be asked to enable this; WebKit must never compile it directly.
        let huge = (0...ExtensionRuleBudget.limit).map {
            #"{"id":\#($0 + 1),"action":{"type":"block"},"condition":{"initiatorDomains":["d\#($0).invalid"]}}"#
        }
        try ("[" + huge.joined(separator: ",") + "]")
            .write(to: folder.appendingPathComponent("huge.json"), atomically: true, encoding: .utf8)
        try "<html><body><script src=driver.js></script></body></html>"
            .write(to: folder.appendingPathComponent("driver.html"), atomically: true, encoding: .utf8)
        try """
        window.atomic = {
          checked: async () => {
            if (typeof globalThis.__yabRealRules !== 'function') throw new Error('production DNR shim is missing');
            const reply = await chrome.runtime.sendNativeMessage('yab', {api: 'dnr.budget', args: []});
            const b = reply && !reply.error && reply.value;
            if (!b || b.limit !== 65534 || !b.sets || b.sets.base !== 1 || b.sets.small !== 1 || b.sets.huge !== 65535)
              throw new Error('real rule budget is missing or invalid: ' + JSON.stringify(reply));
            return b;
          },
          attempt: async (options) => {
            try { await chrome.declarativeNetRequest.updateEnabledRulesets(options); return {ok: true}; }
            catch (e) { return {ok: false, error: String(e && e.message || e)}; }
          }
        };
        """.write(to: folder.appendingPathComponent("driver.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        let counts = ExtensionRuleBudget.counts(in: folder)
        try #require(ExtensionRuleBudget.limit == 65_534 && counts == ["base": 1, "small": 1, "huge": 65_535])
        // A read-only observation page, deliberately outside prepare's HTML
        // injection. No test path obtains an unwrapped update method.
        try "<html><body>Native rule state</body></html>"
            .write(to: folder.appendingPathComponent("reader.html"), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
        let root = try #require(controller.configuration.value(forKey: "_storageDirectoryPath") as? String)
        let ownStorage = URL(fileURLWithPath: root).appendingPathComponent(id, isDirectory: true)
        storage = ownStorage
        ExtensionRules.prepare(context, storage: ownStorage, owner: controller)
        try controller.load(context)
        loaded = context
        try #require(context.isLoaded)
        let configuration = try #require(context.webViewConfiguration)
        configuration.preferences.inactiveSchedulingPolicy = .none
        let driver = WKWebView(frame: .zero, configuration: configuration)
        let reader = WKWebView(frame: .zero, configuration: configuration)
        let ordinary = WKWebViewConfiguration()
        ordinary.websiteDataStore = try #require(controller.configuration.defaultWebsiteDataStore)
        ordinary.webExtensionController = controller
        ordinary.preferences.inactiveSchedulingPolicy = .none
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: ordinary)
        driver.load(URLRequest(url: context.baseURL.appendingPathComponent("driver.html")))
        reader.load(URLRequest(url: context.baseURL.appendingPathComponent("reader.html")))
        page.load(URLRequest(url: try #require(URL(string: server.root + "/atomic-page"))))
        let ready = try await Loaded.until(30) {
            guard !driver.isLoading, !reader.isLoading, !page.isLoading, page.url != nil else { return false }
            let driverReady = try await driver.evaluateJavaScript("typeof window.atomic === 'object'") as? Bool == true
            let readerReady = try await reader.evaluateJavaScript("document.readyState === 'complete' && typeof globalThis.__yabRealRules === 'undefined'") as? Bool == true
            return driverReady && readerReady
        }
        try #require(ready)
        let fixture = Fixture(owner: owner, browser: browser, controller: controller, context: context, answers: answers,
                              folder: folder, storage: ownStorage, driver: driver, reader: reader, page: page, server: server)
        // Both Swift and the extension validate the actual native bridge
        // metadata before any potentially oversized request.
        let reply = try #require(try await ExtensionShims.answer(["api": "dnr.budget", "args": []], from: context, owner: owner) as? [String: Any])
        try #require(reply["error"] == nil, "dnr.budget bridge reply: \(reply)")
        let budget = try #require(reply["value"] as? [String: Any], "dnr.budget bridge reply: \(reply)")
        try #require(budget["limit"] as? Int == 65_534 && budget["sets"] as? [String: Int] == counts)
        _ = try await fixture.run("return {budget: await window.atomic.checked()};")
        try #require(answers.budgetCalls > 0)
        try await fixture.waitForNative(["base"])
        // The controller applies its own compiled DNR list to this ordinary
        // HTTP page. No cached bridge list is manually added to the page.
        let blockingReady = try await Loaded.until(10, every: .milliseconds(100)) {
            Fixture.blocks(try await fixture.images())
        }
        try #require(blockingReady, "base never blocked its actual image with control allowed")
        complete = true
        return fixture
    }

    private func phase(_ name: String, update: [String: Any], fixture: Fixture,
                       valid: [String: Any]? = nil) async throws {
        // The queue waits one second of quiet. Reads below go directly to
        // WebKit and actual image requests after that timer can run.
        try await Task.sleep(for: .milliseconds(1500))
        let native = try await fixture.nativeSets()
        let api = try await fixture.run("return {sets: (await chrome.declarativeNetRequest.getEnabledRulesets()).sort()};")
        let traffic = try await fixture.images()
        let expected = name == "priorPending" ? ["base", "small"] : ["base"]
        let semanticPass = update["ok"] as? Bool == false && native == expected
            && api["sets"] as? [String] == expected && Fixture.blocks(traffic)
            && (valid == nil || valid?["ok"] as? Bool == true)
        var out: [String: Any] = ["arm": ProcessInfo.processInfo.environment["YAB_RULE_ATOMIC_ARM"] ?? "standalone",
                                  "phase": name, "ready": true, "update": update, "native": native,
                                  "api": api, "traffic": traffic, "semantic_pass": semanticPass]
        if let valid { out["valid"] = valid }
        emit("RULE_ATOMIC_PHASE", out)
        #expect(semanticPass, "RULE_ATOMIC_SEMANTIC_\(name): \(out)")
    }

    @Test func oversizedReplacementIsAtomicAndPreservesEarlierPendingWork() async throws {
        let fixture = try await installed()
        defer { fixture.close() }

        let replacement = try await fixture.run("""
        await window.atomic.checked();
        return await window.atomic.attempt({disableRulesetIds: ['base'], enableRulesetIds: ['huge']});
        """)
        try await phase("replacement", update: replacement, fixture: fixture)
        try await fixture.reset()

        let mixed = try await fixture.run("""
        await window.atomic.checked();
        return await window.atomic.attempt({enableRulesetIds: ['small', 'huge']});
        """)
        try await phase("mixed", update: mixed, fixture: fixture)
        try await fixture.reset()

        let pending = try await fixture.run("""
        await window.atomic.checked();
        const valid = await window.atomic.attempt({enableRulesetIds: ['small']});
        const rejected = await window.atomic.attempt({disableRulesetIds: ['base', 'small'], enableRulesetIds: ['huge']});
        return {valid, rejected, visible: (await chrome.declarativeNetRequest.getEnabledRulesets()).sort()};
        """)
        let valid = try #require(pending["valid"] as? [String: Any])
        let rejected = try #require(pending["rejected"] as? [String: Any])
        try await phase("priorPending", update: rejected, fixture: fixture, valid: valid)
        let oldWarning = "console.warn: yab: rule sets huge kept off: with them WebKit would get more than 65534 rules that match every address"
        let expectedWarnings = ProcessInfo.processInfo.environment["YAB_RULE_ATOMIC_ARM"] == "baseline"
            ? Array(repeating: oldWarning, count: 3) : []
        #expect(fixture.answers.errors == expectedWarnings, "\(fixture.answers.errors)")
    }
}
