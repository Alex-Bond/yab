import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// An extension's DOMContentLoaded listeners in its own world run after the
/// page's first frames (extension-shims.js, ExtensionShims.dclLate):
/// 1Password imported 449 KB of module there, before a new tab's first frame.
@Suite struct ExtensionContentLoadedTests {
    private func context() throws -> JSContext {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // What the extension does as the page's DOMContentLoaded fires"))
        let end = try #require(script.range(of: "  // Several onMessage listeners", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var frames = [], timers = [], ran = [];
        function EventTarget() {}
        EventTarget.prototype.addEventListener = function (type, f) { (this.l = this.l || []).push([type, f]); };
        EventTarget.prototype.removeEventListener = function (type, f) { this.l = (this.l || []).filter((p) => p[0] !== type || p[1] !== f); };
        EventTarget.prototype.fire = function (type) { for (const [t, f] of (this.l || []).slice()) if (t === type) f.call(this, { type }); };
        var document = Object.create(EventTarget.prototype); document.readyState = 'loading';
        var window = Object.create(EventTarget.prototype);
        var el = Object.create(EventTarget.prototype);
        function requestAnimationFrame(f) { frames.push(f); }
        function setTimeout(f, ms) { timers.push([f, ms || 0]); }
        function put(o, k, v) { o[k] = v; }
        var inContent = true;
        """)
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_DCL_LATE__", with: "true"))
        #expect(context.exception == nil)
        return context
    }

    @Test func listenersWaitForTheFirstFrames() throws {
        let c = try context()
        c.evaluateScript("""
        document.addEventListener('DOMContentLoaded', function () { ran.push('doc:' + (this === document)); });
        window.addEventListener('DOMContentLoaded', { handleEvent(e) { ran.push('win:' + e.type); } });
        el.addEventListener('DOMContentLoaded', () => ran.push('el'));
        document.addEventListener('click', () => ran.push('click'));
        const gone = () => ran.push('removed'); document.addEventListener('DOMContentLoaded', gone); document.removeEventListener('DOMContentLoaded', gone);
        document.fire('DOMContentLoaded'); window.fire('DOMContentLoaded'); el.fire('DOMContentLoaded'); document.fire('click');
        """)
        // Not the document's or the window's yet; another target and other events at once.
        #expect(c.evaluateScript("ran.join()")?.toString() == "el,click")
        c.evaluateScript("frames.shift()(); frames.shift()(); timers.filter((t) => t[1] === 0).forEach((t) => t[0]());")
        #expect(c.evaluateScript("ran.join()")?.toString() == "el,click,doc:true,win:DOMContentLoaded")
        // Once drawn, a late listener runs as it would have.
        #expect(c.evaluateScript("""
        (() => { const f = () => {}; document.addEventListener('DOMContentLoaded', f); return document.l.some((p) => p[1] === f); })()
        """)?.toBool() == true)
    }

    @Test func aHiddenPageGetsThemAfterHalfASecond() throws {
        let c = try context()
        c.evaluateScript("""
        document.addEventListener('DOMContentLoaded', () => ran.push('doc'));
        document.fire('DOMContentLoaded');
        timers.filter((t) => t[1] === 500).forEach((t) => t[0]());
        """)
        #expect(c.evaluateScript("ran.join()")?.toString() == "doc")
        // The frames coming later don't run it twice.
        c.evaluateScript("frames.shift()(); frames.shift()(); timers.filter((t) => t[1] === 0).forEach((t) => t[0]());")
        #expect(c.evaluateScript("ran.join()")?.toString() == "doc")
    }
}
