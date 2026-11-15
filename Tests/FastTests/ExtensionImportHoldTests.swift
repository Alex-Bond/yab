import AppKit
import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

/// What reaches an extension's worker while it imports a script is heard
/// once the import is over, as extensions expect of a one-thread worker
/// (extension-shims.js, `afterImport`). WebKit hands the worker the events that
/// arrive while it fetches the script, and Rabby Wallet, which imports its
/// background at its first event and notes it has only once importScripts
/// returns, imported it again inside the first for each message its popup
/// sent meanwhile: eight welcome tabs from one press of its button.
///
/// And the popup's window.close(), made by the shim before the page's own
/// scripts, which survives a sandbox that takes globals away as MetaMask's
/// LavaMoat does; the bridge put in once the document is built only tells it
/// where to carry the call (ExtensionPopup.closeBridge).
@MainActor
@Suite(.serialized)
struct ExtensionImportHoldTests {
    private static func until(_ seconds: Double = 10, _ check: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await check()
    }

    /// The worker's native calls, answered with nothing.
    @MainActor
    final class Answers: NSObject, WKWebExtensionControllerDelegate {
        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
            NSNull()
        }
    }

    /// The real worker: messages blasted at it while it imports a big script
    /// on the first of them. Each is answered by the listener the script
    /// adds, the script runs once, and the import is never entered again
    /// from inside itself.
    @Test func messagesDuringAnImportWaitForIt() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-import-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Import hold test","description":"Test","version":"1.0","background":{"service_worker":"sw.js"}}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // Rabby's sw.js, in short: the background imported at the first
        // event, noted as imported only once importScripts returns.
        try """
            self.entries = 0; self.nested = 0; self.sources = []; let depth = 0, loaded = false;
            const importAll = (source) => {
              if (loaded) return;
              self.sources.push(source + '@' + depth);
              self.entries++; if (depth) self.nested++;
              depth++;
              try { importScripts('/big.js'); loaded = true; } catch (e) { self.failed = String(e); } finally { depth--; }
            };
            // Which questions the worker's own listener heard first, and
            // whether the script was in by then (for a failure's message).
            self.heard = [];
            chrome.runtime.onMessage.addListener((m, s, reply) => {
              if (m && m.big && self.heard.length < 12) self.heard.push(m.n + (loaded ? '' : '-') + (depth ? 'd' : ''));
              importAll('message');
              if (m && m.stats) { reply({entries: self.entries, nested: self.nested, evals: self.evals || 0, failed: self.failed || '', sources: self.sources, heard: self.heard,
                wrapped: !String(importScripts).includes('[native code]'), own: Object.prototype.hasOwnProperty.call(self, 'importScripts'), shim: !!self.__yabShim}); return true; }
              return false;
            });
            // WebKit imports only while the worker installs, which extensions expect
            // for a script it hasn't seen.
            self.addEventListener('install', () => importAll('install'));
            """.write(to: folder.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        // Big enough that fetching it takes a while, as Rabby's 21 MB do.
        var big = "self.evals = (self.evals || 0) + 1;\n"
        big += "chrome.runtime.onMessage.addListener((m, s, r) => { if (m && m.big) { r('big:' + self.evals); return true; } });\n"
        big += String(repeating: "// " + String(repeating: "x", count: 1000) + "\n", count: 40_000)
        try big.write(to: folder.appendingPathComponent("big.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Start</title>".write(to: folder.appendingPathComponent("start.html"), atomically: true, encoding: .utf8)
        // A page that asks from its first moment, so that its questions
        // arrive while the worker is still importing at its install.
        try "<!doctype html><title>Blast</title><script src=\"blast.js\"></script>".write(to: folder.appendingPathComponent("blast.html"), atomically: true, encoding: .utf8)
        try """
            globalThis.replies = []; globalThis.asked = 0; globalThis.none = [];
            // For 6 s, and at least 120 questions however slowly a busy
            // Mac runs the page's timers.
            const until = Date.now() + 6000;
            const ask = () => {
              if (Date.now() > until && asked >= 120) return;
              for (let i = 0; i < 4; i++) {
                asked++;
                const n = asked;
                chrome.runtime.sendMessage({big: true, n}).then((r) => { replies.push(r === undefined ? null : r); if (r === undefined) none.push(n); },
                  (e) => replies.push('error ' + e));
              }
              setTimeout(ask, 20);
            };
            ask();
            """.write(to: folder.appendingPathComponent("blast.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)

        // A controller of its own, as the other worker suites have: the
        // shared one is every test tab's, and in a full run, beside the
        // suites working it, this worker stopped answering halfway.
        func blastOnce() async throws -> (answered: Bool, tally: String?, result: String?, parsed: [String: Any]) {
            let controller = TestExtensions.controller()
            let answers = Answers()
            controller.delegate = answers
            WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
            context.baseURL = try #require(URL(string: "\(Extensions.scheme)://hold\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))/"))
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            try controller.load(context)
            defer { try? controller.unload(context) }
            let configuration = try #require(context.webViewConfiguration)
            // A page in no window keeps its timers running.
            configuration.preferences.inactiveSchedulingPolicy = .none
            let blast = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
            blast.load(URLRequest(url: context.baseURL.appendingPathComponent("blast.html")))
            // Every question asked has its answer. The worker's first start
            // and its import take seconds beside a build.
            let answered = try await Self.until(120) {
                (try? await blast.evaluateJavaScript("asked > 100 && replies.length === asked")) as? Bool == true
            }
            let tally = try? await blast.evaluateJavaScript("JSON.stringify({asked, replied: replies.length, kinds: [...new Set(replies)]})") as? String
            let result = try await blast.callAsyncJavaScript("""
                // A worker that never answers fails the test instead of holding the run.
                const stats = await Promise.race([chrome.runtime.sendMessage({stats: true}),
                    new Promise((resolve) => setTimeout(() => resolve({timedOut: true}), 60000))]);
                return JSON.stringify({asked, kinds: [...new Set(replies)], empty: replies.filter((r) => r === null).length, none, stats});
                """, contentWorld: .page) as? String
            let parsed = try #require(try JSONSerialization.jsonObject(with: Data((result ?? "{}").utf8)) as? [String: Any])
            withExtendedLifetime((blast, answers)) {}
            return (answered, tally, result, parsed)
        }
        let (answered, tally, result, parsed) = try await blastOnce()
        #expect(answered, "\(tally ?? "nil")")
        let stats = parsed["stats"] as? [String: Any] ?? [:]
        let kinds = parsed["kinds"] as? [Any] ?? []
        #expect(stats["evals"] as? Int == 1, "\(result ?? "nil")")
        #expect(stats["nested"] as? Int == 0, "\(result ?? "nil")")
        #expect(stats["failed"] as? String == "", "\(result ?? "nil")")
        // Every answer is the script's first run's. Of the questions the
        // worker heard, at most the one that started the import has none,
        // its listeners counted before the script added its own, as in
        // Chrome: none heard during the import is left unanswered.
        #expect(kinds.allSatisfy { $0 is NSNull || $0 as? String == "big:1" } && kinds.contains { $0 as? String == "big:1" }, "\(result ?? "nil")")
        let heard = (stats["heard"] as? [String] ?? []).compactMap { Int($0.prefix { $0.isNumber }) }
        let firstHeard = try #require(heard.min(), "\(result ?? "nil")")
        let starter = (stats["sources"] as? [String])?.first?.hasPrefix("message") == true ? firstHeard : nil
        let none = parsed["none"] as? [Int] ?? []
        // Questions asked before that never reached the worker: WebKit
        // (macOS 26.7 on m4, beside a build) answers the first few a page
        // sends while the worker first starts with nothing, where Chrome
        // waits for the worker. Those are not the import's to answer.
        #expect(none.allSatisfy { $0 < firstHeard || $0 == starter }, "\(result ?? "nil")")
    }

    // MARK: the mechanism, on its own

    /// The shim's holding and its message dispatcher, with a clock of its
    /// own, an import being "during" between `begin()` and `end()`.
    private func held() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var background = true, inContent = false, channel = null, now = 0, timers = [];
        Date.now = () => now;
        function setTimeout(f, ms) { const timer = {f, at: now + (ms || 0)}; timers.push(timer); return timer; }
        function clearTimeout(timer) { timers = timers.filter(t => t !== timer); }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { clearTimeout(t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        function tell() {} function join() {} function leave() {}
        var peers = new Set();
        var nativeListener, event = {addListener: f => nativeListener = f, removeListener: () => { nativeListener = null; }};
        """#)
        let script = ExtensionShims.script
        let holdStart = try #require(script.range(of: "  let importing = 0;"))
        let holdEnd = try #require(script.range(of: "  if (worker && typeof root.importScripts", range: holdStart.upperBound..<script.endIndex))
        let gatherStart = try #require(script.range(of: "const gather = (event, told) => {"))
        let gatherEnd = try #require(script.range(of: "// Chrome's runtime functions work", range: gatherStart.upperBound..<script.endIndex))
        context.evaluateScript(String(script[holdStart.lowerBound..<holdEnd.lowerBound])
            + "\nfunction begin() { importing++; } function end() { importing--; releaseHeld(); }\n"
            + String(script[gatherStart.lowerBound..<gatherEnd.lowerBound]) + "\ngather(event, true);")
        try #require(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return context
    }

    @Test func aMessageDuringAnImportIsHeardAfterItInOrder() throws {
        let c = try held()
        c.evaluateScript(#"""
        var heard = [], replies = [];
        event.addListener((m, s, reply) => { heard.push(m.n); if (m.n === 2) { reply('two'); } });
        begin();
        var kept1 = nativeListener({n: 1}, {}, v => replies.push(['1', v]));
        var kept2 = nativeListener({n: 2}, {}, v => replies.push(['2', v]));
        var duringImport = heard.length;
        // The script the import runs adds a listener of its own.
        event.addListener((m, s, reply) => { if (m.n === 1) { reply('one, from the import'); return true; } });
        end();
        var rightAfter = heard.length;
        advance(0);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.objectForKeyedSubscript("kept1")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("kept2")?.toBool() == true)
        #expect(c.objectForKeyedSubscript("duringImport")?.toInt32() == 0)
        // Not even as the import returns: the caller notes it has imported first.
        #expect(c.objectForKeyedSubscript("rightAfter")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == "[1,2]")
        #expect(c.evaluateScript("JSON.stringify(replies)")?.toString() == #"[["1","one, from the import"],["2","two"]]"#)
    }

    @Test func aHeldMessageNobodyTakesIsAnsweredWithNothing() throws {
        let c = try held()
        c.evaluateScript(#"""
        var replies = [];
        event.addListener(() => {});
        begin();
        nativeListener({n: 1}, {}, v => replies.push(v === undefined ? 'nothing' : v));
        end();
        advance(0); advance(0);
        var alone = JSON.stringify(replies);
        // A page of the extension that may answer it is given the time to.
        peers.add('page');
        begin();
        nativeListener({n: 2}, {}, v => replies.push(v === undefined ? 'nothing' : v));
        end();
        advance(0);
        var soon = replies.length;
        advance(10000);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.objectForKeyedSubscript("alone")?.toString() == #"["nothing"]"#)
        #expect(c.objectForKeyedSubscript("soon")?.toInt32() == 1)
        #expect(c.evaluateScript("replies.length")?.toInt32() == 2)
    }

    @Test func outsideAnImportAMessageIsHeardAtOnce() throws {
        let c = try held()
        c.evaluateScript(#"""
        var heard = 0;
        event.addListener(() => { heard++; });
        var kept = nativeListener({n: 1}, {}, () => {});
        """#)
        #expect(c.exception == nil)
        #expect(c.objectForKeyedSubscript("heard")?.toInt32() == 1)
        #expect(c.objectForKeyedSubscript("kept")?.isUndefined == true)
    }

    /// The shim's holding with its stand-ins for every other event of the
    /// worker, over a stand-in for WebKit's runtime.onInstalled.
    private func events() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var background = true, now = 0, timers = [];
        function setTimeout(f, ms) { const timer = {f, at: now + (ms || 0)}; timers.push(timer); return timer; }
        function clearTimeout(timer) { timers = timers.filter(t => t !== timer); }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { clearTimeout(t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        var native = [];
        var onInstalled = {
          addListener(f) { if (!native.includes(f)) native.push(f); },
          removeListener(f) { native = native.filter(g => g !== f); },
          hasListener(f) { return native.includes(f); },
        };
        function fire(details) { for (const f of [...native]) f(details); }
        var chrome = {runtime: {onInstalled}};
        var heldClicks = [];  // The button's click keeps its own (ExtensionHeldClicksTests).
        """#)
        let script = ExtensionShims.script
        let holdStart = try #require(script.range(of: "  let importing = 0;"))
        let holdEnd = try #require(script.range(of: "  if (worker && typeof root.importScripts", range: holdStart.upperBound..<script.endIndex))
        let start = try #require(script.range(of: "  if (background) {\n    const mentioned"))
        let end = try #require(script.range(of: "  // What one of the extension's pages or its worker posts to another", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[holdStart.lowerBound..<holdEnd.lowerBound])
            + "\nfunction begin() { importing++; } function end() { importing--; releaseHeld(); }\n"
            + String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_EVENTS__", with: #"["runtime.onInstalled"]"#))
        try #require(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return context
    }

    @Test func anEventDuringAnImportGoesToTheListenersThereAfterIt() throws {
        let c = try events()
        c.evaluateScript(#"""
        var buffered = [], heard = [];
        // MetaMask: a listener that buffers until its background loads.
        const buffer = (d) => buffered.push(d.reason);
        chrome.runtime.onInstalled.addListener(buffer);
        begin();
        fire({reason: 'install'});
        var duringImport = buffered.length;
        // Its background loads and takes over from the buffer.
        const real = (d) => heard.push(d.reason);
        chrome.runtime.onInstalled.addListener(real);
        chrome.runtime.onInstalled.removeListener(buffer);
        end();
        advance(0);
        // Outside an import, an event goes as WebKit sends it.
        fire({reason: 'update'});
        var listed = chrome.runtime.onInstalled.hasListener(real) && !chrome.runtime.onInstalled.hasListener(buffer);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.objectForKeyedSubscript("duringImport")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(buffered)")?.toString() == "[]")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"["install","update"]"#)
        #expect(c.objectForKeyedSubscript("listed")?.toBool() == true)
    }

    @Test func twoEventsDuringAnImportAreTwoAndInOrder() throws {
        let c = try events()
        c.evaluateScript(#"""
        var heard = [];
        chrome.runtime.onInstalled.addListener((d) => heard.push('a' + d.n));
        chrome.runtime.onInstalled.addListener((d) => heard.push('b' + d.n));
        begin();
        fire({n: 1}); fire({n: 2});
        end();
        advance(0);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"["a1","b1","a2","b2"]"#)
    }

    // MARK: Yab's own words in an extension's storage

    /// The worker's start, told to its content scripts through storage
    /// (`__yabWorkerLife`), is never seen by the extension: Rabby took it for
    /// a wallet already set up and opened no welcome page as it installed.
    @Test func yabsWordInStorageIsNotTheExtensions() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        function put(o, k, v) { o[k] = v; }
        function withLastError(e, cb) { cb(undefined); }
        function event() {
          const fs = [];
          return { fs, addListener(f) { fs.push(f); }, removeListener(f) { const i = fs.indexOf(f); if (i >= 0) fs.splice(i, 1); },
                   hasListener(f) { return fs.includes(f); }, fire(...a) { for (const f of [...fs]) f(...a); } };
        }
        var stored = {wallet: 1, __yabWorkerLife: 'abc'};
        var chrome = {storage: {onChanged: event(), local: {
          onChanged: event(),
          get: (keys) => Promise.resolve(Object.assign({}, stored)),
          getKeys: () => Promise.resolve(Object.keys(stored)),
        }}};
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  const ownWords = "))
        // Up to the copying shim after it, which needs the page's own context.
        let end = try #require(script.range(of: "  // Copying in a website's tab.", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil, "\(context.exception?.toString() ?? "")")
        context.evaluateScript(#"""
        var got = null, keys = null, viaCallback = null, heard = [], yabHeard = [];
        chrome.storage.local.get(null).then((v) => got = v);
        chrome.storage.local.get(null, (v) => viaCallback = v);
        chrome.storage.local.getKeys().then((v) => keys = v);
        const listener = (changes, area) => heard.push(Object.keys(changes).join(',') + '@' + area);
        chrome.storage.onChanged.addListener(listener);
        const yab = (changes) => yabHeard.push(Object.keys(changes).join(','));
        ownListeners.add(yab);
        chrome.storage.onChanged.addListener(yab);
        chrome.storage.onChanged.fire({__yabWorkerLife: {newValue: 'abc'}}, 'local');
        chrome.storage.onChanged.fire({wallet: {newValue: 2}, __yabWorkerLife: {newValue: 'def'}}, 'local');
        chrome.storage.onChanged.removeListener(listener);
        chrome.storage.onChanged.fire({wallet: {newValue: 3}}, 'local');
        """#)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        #expect(context.evaluateScript("JSON.stringify([got, viaCallback, keys])")?.toString() == #"[{"wallet":1},{"wallet":1},["wallet"]]"#)
        #expect(context.evaluateScript("JSON.stringify(heard)")?.toString() == #"["wallet@local"]"#)
        #expect(context.evaluateScript("JSON.stringify(yabHeard)")?.toString() == #"["__yabWorkerLife","wallet,__yabWorkerLife","wallet"]"#)
    }

    // MARK: window.close under a sandbox

    private final class Watcher: NSObject, WKScriptMessageHandler {
        var posted: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String { posted.append(body) }
        }
    }

    /// LavaMoat's scuttling, as MetaMask's popup runs it: every global it
    /// doesn't name that can be redefined becomes an accessor that throws.
    private static let scuttle = """
        (() => {
          const keep = new Set(['window', 'Object', 'Reflect', 'Array', 'String', 'self', 'top', 'frames']);
          const Failure = Error;
          for (const name of Object.getOwnPropertyNames(window)) {
            if (keep.has(name)) continue;
            const d = Object.getOwnPropertyDescriptor(window, name);
            if (!d || !d.configurable) continue;
            try { Object.defineProperty(window, name, { configurable: false, get() { throw new Failure('LavaMoat - property "' + name + '" of globalThis is inaccessible under scuttling mode.'); }, set() {} }); } catch (e) {}
          }
        })();
        """

    private static func page(shim: Bool) async throws -> (WKWebView, Watcher) {
        let watcher = Watcher(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(watcher, name: "yabPopupCloseTest")
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // The page's window.close(), which Yab carries"))
        let end = try #require(script.range(of: "  const runtime = chrome.runtime;", range: start.upperBound..<script.endIndex))
        if shim {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "(() => { const inContent = false;\n" + script[start.lowerBound..<end.lowerBound] + "\n})();",
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: scuttle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 240), configuration: configuration)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-scuttle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("popup.html")
        try "<p>popup</p><iframe srcdoc='<p>frame</p>'></iframe>".write(to: file, atomically: true, encoding: .utf8)
        web.loadFileURL(file, allowingReadAccessTo: folder)
        let ready = try await until(30) { (try? await web.evaluateJavaScript("document.readyState === 'complete' && document.querySelectorAll('iframe').length === 1")) as? Bool == true }
        let state = try? await web.evaluateJavaScript("(() => { try { return document.readyState + ' ' + location.href; } catch (e) { return 'threw ' + e.message; } })()") as? String
        #expect(ready, "\(state ?? "nil")")
        // Then the bridge, as the popup's document is built.
        let bridge = try #require(ExtensionPopup.closeBridge(scheme: "file", host: "", token: "document-token", handler: "yabPopupCloseTest"))
        // Without the shim's close it throws, close having been taken.
        _ = try? await web.evaluateJavaScript(bridge + "; true")
        return (web, watcher)
    }

    @Test func aSandboxedPopupStillCloses() async throws {
        // Without the shim's close, the sandbox took it: the error MetaMask's popup raised.
        let (bare, bareWatcher) = try await Self.page(shim: false)
        let thrown = try await bare.evaluateJavaScript("(() => { try { window.close(); return ''; } catch (e) { return String(e.message); } })()") as? String
        #expect(thrown?.contains("inaccessible under scuttling mode") == true, "\(thrown ?? "nil")")
        try await Task.sleep(for: .milliseconds(300))
        #expect(bareWatcher.posted.isEmpty)

        let (web, watcher) = try await Self.page(shim: true)
        let said = try await web.evaluateJavaScript("""
            (() => { try { window.close(); self.close(); (function () { 'use strict'; close(); })(); return 'ok'; } catch (e) { return String(e.message); } })()
            """) as? String
        #expect(said == "ok")
        // A frame's close stays WebKit's, and the page may still set its own.
        _ = try await web.evaluateJavaScript("const f = document.querySelector('iframe').contentWindow; f.close(); window.close.call(f); true")
        let own = try await web.evaluateJavaScript("window.close = () => 'mine'; window.close()") as? String
        #expect(own == "mine")
        _ = try await Self.until { watcher.posted.count >= 3 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(watcher.posted == Array(repeating: "document-token", count: 3))
    }
}
