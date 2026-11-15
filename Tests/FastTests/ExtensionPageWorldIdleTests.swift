import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// requestIdleCallback for an extension's script in a page's own world:
/// WebKit has none (bug 287681), and Proton Pass's elements.js, put there by
/// scripting.executeScript, threw "Can't find variable" as its element left
/// the page. yab-idle.js goes first, and only before a file that calls it.
@MainActor
@Suite(.serialized)
struct ExtensionPageWorldIdleTests {
    private func shimContext(idle: [String], audio: [String] = []) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var executed = [], registered = [];
        var background = false;
        var runtime = { getURL: (path) => 'chrome-extension://test/' + path };
        var chrome = { runtime, scripting: {
          executeScript: (injection) => { executed.push(injection); return Promise.resolve([{ result: 1 }]); },
          registerContentScripts: (list) => { registered.push(list); return Promise.resolve(); },
          updateContentScripts: (list) => { registered.push(list); return Promise.resolve(); },
          unregisterContentScripts: () => Promise.resolve(), getRegisteredContentScripts: () => Promise.resolve([]) } };
        function put(o, k, v) { o[k] = v; }
        function withLastError(e, callback) { callback(); }
        function yabStorageGuard() {}
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  const scripting = chrome.scripting;"))
        let end = try #require(script.range(of: "  const wantsUserScripts", range: start.upperBound..<script.endIndex))
        let list = String(data: try JSONSerialization.data(withJSONObject: idle), encoding: .utf8)!
        let players = String(data: try JSONSerialization.data(withJSONObject: audio), encoding: .utf8)!
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_IDLE__", with: list)
            .replacingOccurrences(of: "__YAB_AUDIO__", with: players)
            .replacingOccurrences(of: "__YAB_WARM__", with: "true")
            .replacingOccurrences(of: "__YAB_PORT_TRACE__", with: "false"))
        try #require(context.exception == nil)
        return context
    }

    /// What each executeScript call put in, in order: its files, null for a
    /// function, "guard" for the storage guard the shim runs first.
    private static let injected = #"JSON.stringify(executed.map(i => i.func === yabStorageGuard ? "guard" : i.files || null))"#

    @Test func executeScriptPutsItBeforeAPageWorldFileThatCallsIt() throws {
        let c = try shimContext(idle: ["elements.js"])
        // One after another, as the wrapper is async: an injection into the
        // extension's own world has the storage guard (yabStorageGuard) put
        // there first, and the page's own world gets none.
        c.evaluateScript(#"""
        (async () => {
          await chrome.scripting.executeScript({ target: { tabId: 1 }, world: "MAIN", files: ["elements.js"] });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, world: "MAIN", files: ["/other.js"] });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["elements.js"] });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, world: "MAIN", func: () => 1 });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["chrome-extension://test/elements.js"] });
        })().catch((e) => { failed = String(e); });
        """#)
        #expect(c.exception == nil)
        #expect(c.evaluateScript("typeof failed")?.toString() == "undefined")
        let files = c.evaluateScript(Self.injected)?.toString()
        #expect(files == #"[["yab-idle.js","elements.js"],["/other.js"],"guard",["elements.js"],null,"guard",["elements.js"]]"#)
    }

    @Test func aRegisteredPageWorldScriptThatCallsItGetsItFirst() throws {
        let c = try shimContext(idle: ["js/passkeys.js"])
        c.evaluateScript(#"""
        chrome.scripting.registerContentScripts([
          { id: "a", matches: ["https://*/*"], js: ["/js/passkeys.js"], world: "MAIN" },
          { id: "b", matches: ["https://*/*"], js: ["js/other.js"], world: "MAIN" },
          { id: "c", matches: ["https://*/*"], js: ["js/passkeys.js"] }]);
        """#)
        #expect(c.exception == nil)
        let js = c.evaluateScript("JSON.stringify(registered[0].map(s => s.js))")?.toString()
        #expect(js == #"[["yab-idle.js","yab-passkeys.js","/js/passkeys.js"],["yab-passkeys.js","js/other.js"],["js/passkeys.js"]]"#)
    }

    /// Transpose's player-main.js makes an AudioContext in the page's own
    /// world (feedback #271): yab-audio.js goes first, before yab-idle.js
    /// for a file that needs both, and only before such a file.
    @Test func aPageWorldFileThatMakesAnAudioContextGetsTheAudioHelperFirst() throws {
        let c = try shimContext(idle: ["both.js"], audio: ["player-main.js", "both.js"])
        c.evaluateScript(#"""
        (async () => {
          await chrome.scripting.executeScript({ target: { tabId: 1 }, world: "MAIN", files: ["player-main.js"] });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, files: ["player-main.js"] });
          await chrome.scripting.executeScript({ target: { tabId: 1 }, world: "MAIN", files: ["both.js"] });
        })().catch((e) => { failed = String(e); });
        chrome.scripting.registerContentScripts([{ id: "a", matches: ["https://*/*"], js: ["player-main.js"], world: "MAIN" }]);
        """#)
        #expect(c.exception == nil)
        #expect(c.evaluateScript("typeof failed")?.toString() == "undefined")
        let files = c.evaluateScript(Self.injected)?.toString()
        #expect(files == #"[["yab-audio.js","player-main.js"],"guard",["player-main.js"],["yab-audio.js","yab-idle.js","both.js"]]"#)
        let js = c.evaluateScript("JSON.stringify(registered[0].map(s => s.js))")?.toString()
        #expect(js == #"[["yab-audio.js","yab-passkeys.js","player-main.js"]]"#)
    }

    /// The helper: a context suspended though its own code never suspended
    /// it starts with the page's next trusted click or key, inside it; one
    /// its code suspended stays so; subclasses and instanceof still work.
    @Test func theAudioHelperStartsAWaitingContextWithTheNextClick() throws {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var gesture = false, listeners = {};
        class AudioContext {
          constructor() { this.state = "suspended"; this.heard = []; }
          addEventListener(k, f) { this.heard.push(f); }
          resume() { if (gesture) { this.state = "running"; this.heard.forEach(f => f()); } return Promise.resolve(); }
          suspend() { this.state = "suspended"; return Promise.resolve(); }
        }
        var window = { AudioContext, webkitAudioContext: AudioContext,
          addEventListener(k, f) { (listeners[k] = listeners[k] || new Set()).add(f); },
          removeEventListener(k, f) { listeners[k] && listeners[k].delete(f); } };
        function fire(kind, trusted) { gesture = true; for (const f of [...(listeners[kind] || [])]) f({ isTrusted: trusted }); gesture = false; }
        """#)
        context.evaluateScript("(function (window) {\n" + ExtensionShims.audioPage + "\n})(window);")
        context.evaluateScript(#"""
        var a = new window.AudioContext(); a.resume();
        var held = new window.AudioContext(); held.suspend();
        class Sub extends window.AudioContext {}
        var sub = new Sub();
        var shape = [a instanceof AudioContext, sub instanceof Sub, sub instanceof AudioContext, window.webkitAudioContext === window.AudioContext];
        fire("pointerdown", false);
        var untrusted = [a.state, sub.state];
        fire("pointerdown", true);
        var after = [a.state, held.state, sub.state, (listeners.pointerdown || new Set()).size];
        """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(shape)")?.toString() == "[true,true,true,true]")
        #expect(context.evaluateScript("JSON.stringify(untrusted)")?.toString() == #"["suspended","suspended"]"#)
        #expect(context.evaluateScript("JSON.stringify(after)")?.toString() == #"["running","suspended","running",0]"#)
    }

    @Test func thePolyfillRunsCallbacksLaterAndKeepsAPagesOwn() throws {
        let page = ExtensionShims.idlePage
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var queue = [], ran = [];
        var window = globalThis;
        window.setTimeout = (f) => { queue.push(f); return queue.length; };
        window.clearTimeout = (id) => { queue[id - 1] = null; };
        function tick() { const q = queue; queue = []; q.forEach(f => f && f()); }
        """#)
        context.evaluateScript(page)
        context.evaluateScript(#"""
        var a = requestIdleCallback(d => ran.push(['a', d.didTimeout, d.timeRemaining() > 0]));
        var b = requestIdleCallback(() => ran.push(['b']));
        cancelIdleCallback(b);
        var sync = ran.length;
        tick();
        var threw; try { requestIdleCallback(5); } catch (e) { threw = e instanceof TypeError; }
        """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("sync")?.toInt32() == 0)
        #expect(context.evaluateScript("JSON.stringify(ran)")?.toString() == #"[["a",false,true]]"#)
        #expect(context.evaluateScript("threw")?.toBool() == true)
        // A page that has its own keeps it.
        let own = try #require(JSContext())
        own.evaluateScript("var window = globalThis; window.setTimeout = () => 0; window.clearTimeout = () => {}; var mine = () => 'mine'; window.requestIdleCallback = mine; window.cancelIdleCallback = () => {};")
        own.evaluateScript(page)
        #expect(own.evaluateScript("requestIdleCallback === mine")?.toBool() == true)
    }

    @Test func prepareListsItOnlyForAPageWorldEntryThatCallsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-idle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"""
        {"manifest_version":3,"name":"Idle test","version":"1.0","background":{"service_worker":"worker.js"},
         "content_scripts":[
          {"matches":["https://*/*"],"js":["js/passkeys.js"],"world":"MAIN"},
          {"matches":["https://*/*"],"js":["js/plain.js"],"world":"MAIN"},
          {"matches":["https://*/*"],"js":["js/content.js"]}]}
        """#.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "requestIdleCallback(() => {});".write(to: folder.appendingPathComponent("js/passkeys.js"), atomically: true, encoding: .utf8)
        try "1;".write(to: folder.appendingPathComponent("js/plain.js"), atomically: true, encoding: .utf8)
        try "requestIdleCallback(() => {});".write(to: folder.appendingPathComponent("js/content.js"), atomically: true, encoding: .utf8)
        try "self.x = 1;".write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let js = (manifest["content_scripts"] as? [[String: Any]] ?? []).map { $0["js"] as? [String] ?? [] }
        let shim = ExtensionShims.shimOnce ? [["yab-content.js"]] : []
        #expect(js == shim + [["yab-idle.js", "yab-passkeys.js", "js/passkeys.js"],
                              ["yab-passkeys.js", "js/plain.js"],
                              (ExtensionShims.shimOnce ? [] : ["yab-content.js"]) + ["js/content.js"]])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("yab-idle.js").path))
        // The worker's shim knows both callers, for what it registers and executes later;
        // its own words about requestIdleCallback don't make the worker one.
        #expect(ExtensionShims.idleCallers(in: folder) == ["js/passkeys.js", "js/content.js"])
        let worker = try String(contentsOf: folder.appendingPathComponent("worker.js"), encoding: .utf8)
        #expect(worker.contains(#"new Set(["js/content.js","js/passkeys.js"])"#))
    }
}
