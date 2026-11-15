import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// The extension's own navigator.locks on macOS 26.4 and 26.5, where
/// WebKit ends the process of an extension that asks for a Web Lock
/// (extension-shims.js, ExtensionShims.ownLocks; feedback #140).
@Suite struct ExtensionLocksTests {
    private func context() throws -> JSContext {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  if (__YAB_LOCKS__ && root.navigator && root.navigator.locks) {"))
        let end = try #require(script.range(of: "  // WebKit serves extension .wasm files", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var root = globalThis, log = [];
        function LockManager() {}
        LockManager.prototype.request = function () { log.push('webkit'); return Promise.resolve(); };
        var navigator = { locks: new LockManager() };
        class DOMException extends Error { constructor(message, name) { super(message); this.name = name; } }
        """)
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_LOCKS__", with: "true"))
        #expect(context.exception == nil)
        return context
    }

    @Test func exclusiveOnesTakeTurnsAndNeverReachWebKit() throws {
        let c = try context()
        c.evaluateScript("""
        let open;
        navigator.locks.request('fill', async (lock) => { log.push('a ' + lock.name + ' ' + lock.mode); await new Promise((r) => open = r); log.push('a done'); });
        navigator.locks.request('fill', (lock) => { log.push('b'); return 7; }).then((v) => log.push('b gave ' + v));
        """)
        #expect(c.evaluateScript("log.join()")?.toString() == "a fill exclusive")
        c.evaluateScript("open()")
        #expect(c.evaluateScript("log.join()")?.toString() == "a fill exclusive,a done,b,b gave 7")
        #expect(c.evaluateScript("navigator.locks instanceof LockManager")?.toBool() == true)
    }

    @Test func sharedOnesTogetherAndIfAvailable() throws {
        let c = try context()
        c.evaluateScript("""
        let open;
        navigator.locks.request('s', { mode: 'shared' }, () => new Promise((r) => { log.push('1'); open = r; }));
        navigator.locks.request('s', { mode: 'shared' }, () => { log.push('2'); });
        navigator.locks.request('s', { ifAvailable: true }, (lock) => { log.push('free ' + lock); });
        """)
        #expect(c.evaluateScript("log.join()")?.toString() == "1,2,free null")
        c.evaluateScript("""
        navigator.locks.query().then((q) => log.push('held ' + q.held.length));
        open();
        """)
        #expect(c.evaluateScript("log.join()")?.toString() == "1,2,free null,held 1")
    }

    @Test func stealTakesItAndSignalLetsGo() throws {
        let c = try context()
        c.evaluateScript("""
        navigator.locks.request('x', () => new Promise(() => {})).catch((e) => log.push('first ' + e.name));
        navigator.locks.request('x', { steal: true }, () => { log.push('stole'); });
        """)
        #expect(c.evaluateScript("log.join()")?.toString() == "first AbortError,stole")
        c.evaluateScript("""
        log = [];
        let open; const stop = { aborted: false, l: [], addEventListener(t, f) { this.l.push(f); } };
        navigator.locks.request('y', () => new Promise((r) => open = r));
        navigator.locks.request('y', { signal: stop }, () => log.push('never')).catch((e) => log.push('gave up ' + e.name));
        stop.aborted = true; stop.l.forEach((f) => f());
        open();
        """)
        #expect(c.evaluateScript("log.join()")?.toString() == "gave up AbortError")
    }
}
