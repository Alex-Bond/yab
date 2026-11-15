import JavaScriptCore
import Testing
@testable import Fast

/// Runs the production storage facade and worker startup block against inert
/// storage. It never opens an extension, profile, native database or window.
@MainActor
struct ExtensionWorkerBeaconTests {
    private func part(_ start: String, _ end: String) throws -> String {
        let script = ExtensionShims.script
        let first = try #require(script.range(of: start))
        let last = try #require(script.range(of: end, range: first.upperBound..<script.endIndex))
        return String(script[first.lowerBound..<last.lowerBound])
    }

    private func startup(_ c: JSContext) throws {
        c.evaluateScript(try part("  if (worker && chrome.storage && chrome.storage.local && typeof chrome.storage.local.set", "  // A worker at work stays"))
        try #require(c.exception == nil, "\(c.exception?.toString() ?? "")")
    }

    private func fixture(keys: Bool = true) throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript(#"""
        var worker = true, workerLife = 'life-a', inContent = true;
        var now = 0, timers = [], calls = [], stored = {}, lastKeyDeletes = 0, failBytes = false;
        function setTimeout(f, ms) { const t = {f, at: now + ms}; timers.push(t); return t; }
        function clearTimeout(t) { timers = timers.filter(x => x !== t); }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { clearTimeout(t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        var runtime = {id: 'fixture'};
        function withLastError(error, callback) { runtime.lastError = {message: String(error)}; try { callback(); } finally { delete runtime.lastError; } }
        function event() { const fs = new Set(); return {addListener: f => fs.add(f), removeListener: f => fs.delete(f), hasListener: f => fs.has(f), fire: (...a) => { for (const f of [...fs]) f(...a); }}; }
        var changed = event(), localChanged = event();
        function emit(changes) { changed.fire(changes, 'local'); localChanged.fire(changes); }
        function selected(keys) { return keys == null ? Object.keys(stored) : Array.isArray(keys) ? keys : [keys]; }
        var local = {
          onChanged: localChanged,
          get: keys => Promise.resolve(Object.fromEntries(selected(keys).filter(k => k in stored).map(k => [k, stored[k]]))),
          getKeys: () => Promise.resolve(Object.keys(stored)),
          set: values => { calls.push('set'); const changes = {}; for (const [k, v] of Object.entries(values)) { changes[k] = {oldValue: stored[k], newValue: v}; stored[k] = v; } emit(changes); return Promise.resolve(); },
          remove: keys => { calls.push('remove'); const changes = {}; for (const k of selected(keys)) if (k in stored) { changes[k] = {oldValue: stored[k]}; delete stored[k]; } if (Object.keys(changes).length && !Object.keys(stored).length) lastKeyDeletes++; emit(changes); return Promise.resolve(); },
          clear: () => { calls.push('clear'); const changes = Object.fromEntries(Object.entries(stored).map(([k, v]) => [k, {oldValue: v}])); if (Object.keys(stored).length) lastKeyDeletes++; stored = {}; emit(changes); return Promise.resolve(); },
          // An opaque native byte oracle, not a claim about WebKit's formula.
          getBytesInUse: keys => failBytes ? Promise.reject(new Error('fixture bytes')) : Promise.resolve(selected(keys).filter(k => k in stored).reduce((n, k) => n + k.length + JSON.stringify(stored[k]).length, 0))
        };
        var nativeBytes = local.getBytesInUse;
        var chrome = {runtime, storage: {local, onChanged: changed}, scripting: {executeScript: () => { calls.push('script@' + now); return Promise.resolve('ok'); }}, tabs: {}};
        runtime.connect = () => ({onMessage: event(), onDisconnect: event(), postMessage() {}, disconnect() { this.nativeDisconnects = (this.nativeDisconnects || 0) + 1; }});
        """#)
        if !keys { c.evaluateScript("delete local.getKeys;") }
        c.evaluateScript(try part("  const ownWords = ", "  if (inContent) return;"))
        try #require(c.exception == nil, "\(c.exception?.toString() ?? "")")
        return c
    }

    @Test func startupOverwritesWithoutDeletingItsLastKeyAndKeepsTheBarrier() throws {
        let c = try fixture()
        try startup(c)
        c.evaluateScript("var injected = false; chrome.scripting.executeScript({}).then(() => injected = true);")
        #expect(c.evaluateScript("stored.__yabWorkerLife")?.toString() == "life-a")
        c.evaluateScript("advance(299);")
        #expect(c.evaluateScript("injected")?.toBool() == false)
        c.evaluateScript("advance(1);")
        #expect(c.evaluateScript("injected && calls.includes('script@300')")?.toBool() == true)
        #expect(c.evaluateScript("calls.filter(x => x === 'remove').length")?.toInt32() == 0)
        #expect(c.evaluateScript("lastKeyDeletes")?.toInt32() == 0)
        c.evaluateScript("workerLife = 'life-b';")
        try startup(c)
        c.evaluateScript("advance(300);")
        #expect(c.evaluateScript("Object.keys(stored).length === 1 && stored.__yabWorkerLife === 'life-b'")?.toBool() == true)
        #expect(c.evaluateScript("lastKeyDeletes")?.toInt32() == 0)
    }

    @Test(arguments: [true, false])
    func facadeHidesTheRetainedRecordButKeepsNativeUserOperations(keys: Bool) throws {
        let c = try fixture(keys: keys)
        c.evaluateScript(#"""
        stored = {wallet: 'visible', __yabWorkerLife: 'life-a'};
        var got, total, explicit, mixed, hidden, callback, actual, publicEvents = 0;
        chrome.storage.onChanged.addListener(() => publicEvents++);
        local.get(null).then(v => got = JSON.stringify(v));
        local.getBytesInUse().then(v => total = v);
        local.getBytesInUse('wallet').then(v => explicit = v);
        local.getBytesInUse(['wallet', '__yabWorkerLife']).then(v => mixed = v);
        local.getBytesInUse('__yabWorkerLife').then(v => hidden = v);
        local.getBytesInUse(null, v => callback = v);
        nativeBytes(null).then(v => actual = v);
        """#)
        #expect(c.evaluateScript("got")?.toString() == #"{"wallet":"visible"}"#)
        #expect(c.evaluateScript("total === explicit && total === mixed && total === callback && hidden === 0 && actual > total")?.toBool() == true)
        if keys {
            c.evaluateScript("var visibleKeys; local.getKeys().then(v => visibleKeys = JSON.stringify(v));")
            #expect(c.evaluateScript("visibleKeys")?.toString() == #"["wallet"]"#)
        }
        c.evaluateScript("local.set({__yabWorkerLife:'life-b'});")
        #expect(c.evaluateScript("publicEvents")?.toInt32() == 0)
        c.evaluateScript("var rejected, callbackError; failBytes = true; local.getBytesInUse().catch(e => rejected = String(e)); local.getBytesInUse(null, () => callbackError = runtime.lastError.message);")
        #expect(c.evaluateScript("rejected.includes('fixture bytes') && callbackError.includes('fixture bytes') && !runtime.lastError")?.toBool() == true)
        c.evaluateScript("local.remove('wallet');")
        #expect(c.evaluateScript("!('wallet' in stored) && stored.__yabWorkerLife === 'life-b' && calls.includes('remove') && publicEvents === 1")?.toBool() == true)
        c.evaluateScript("local.clear();")
        #expect(c.evaluateScript("Object.keys(stored).length === 0 && calls.includes('clear') && lastKeyDeletes === 1")?.toBool() == true)
    }

    @Test func retainedGenerationStillDisconnectsOnlyPortsFromThePreviousWorker() throws {
        let c = try fixture()
        c.evaluateScript(try part("  if (inContent && runtime && typeof runtime.connect === \"function\")", "  // YAB_PORT_TRACE=1 (a diagnosis): every runtime.connect"))
        try #require(c.exception == nil, "\(c.exception?.toString() ?? "")")
        c.evaluateScript(#"""
        var old = runtime.connect(), current = runtime.connect(), oldGone = 0, currentGone = 0;
        old.onDisconnect.addListener(() => oldGone++); current.onDisconnect.addListener(() => currentGone++);
        old.onMessage.fire({__yabPortLife:'old'}); current.onMessage.fire({__yabPortLife:'life-a'});
        """#)
        try startup(c)
        #expect(c.evaluateScript("oldGone === 1 && old.nativeDisconnects === 1 && currentGone === 0")?.toBool() == true)
        c.evaluateScript("changed.fire({__yabWorkerLife:{newValue:'other'}}, 'session'); advance(300);")
        #expect(c.evaluateScript("currentGone")?.toInt32() == 0)
        c.evaluateScript("workerLife = 'life-b';")
        try startup(c)
        #expect(c.evaluateScript("oldGone === 1 && currentGone === 1 && current.nativeDisconnects === 1")?.toBool() == true)
        c.evaluateScript("var fresh = runtime.connect(), freshGone = 0; fresh.onDisconnect.addListener(() => freshGone++); fresh.onMessage.fire({__yabPortLife:'life-b'}); changed.fire({__yabWorkerLife:{newValue:'life-b'}}, 'local'); advance(300);")
        #expect(c.evaluateScript("freshGone === 0 && !calls.includes('remove')")?.toBool() == true)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
    }
}
