import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// A content script's port that WebKit ends at once ("Tab not found", a page
/// open before its extension loaded) is said to have ended a little later
/// each time (extension-shims.js, ExtensionShims.portSlow): NordPass's store
/// connected again 5,000 times a second in every such tab.
@Suite struct ExtensionPortSlowTests {
    private func context() throws -> JSContext {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // A content script WebKit put into a page that was already open when"))
        let end = try #require(script.range(of: "  // Yab's own words in an extension's storage", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        context.evaluateScript("""
        var timers = [], heard = [], made = [];
        function setTimeout(f, ms) { timers.push([f, ms || 0]); }
        function put(o, k, v) { o[k] = v; }
        function Event() { this.l = []; }
        Event.prototype.addListener = function (f) { this.l.push(f); };
        Event.prototype.removeListener = function (f) { this.l = this.l.filter((g) => g !== f); };
        Event.prototype.hasListener = function (f) { return this.l.includes(f); };
        Event.prototype.fire = function (...a) { for (const f of this.l.slice()) f(...a); };
        // `fails`: the next port WebKit makes ends at once, as in a page it
        // doesn't find the tab of.
        var fails = true;
        function Runtime(tag) { this.tag = tag; }
        Runtime.prototype.connect = function (options) {
          const port = { name: options && options.name, onDisconnect: new Event(), onMessage: new Event(), via: this.tag };
          if (fails) port.error = { message: 'Invalid call to runtime.connect(). Tab not found.' };
          made.push(port);
          return port;
        };
        var chrome = { runtime: new Runtime('chrome') };
        var root = { browser: { runtime: new Runtime('browser') } };
        var runtime = chrome.runtime, inContent = true;
        """)
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_PORT_SLOW__", with: "true"))
        #expect(context.exception == nil)
        return context
    }

    @Test func aPortWebKitEndsAtOnceIsToldLaterEachTime() throws {
        let c = try context()
        c.evaluateScript("""
        const f = (p) => heard.push(p.name);
        for (let i = 0; i < 4; i++) {
          const port = root.browser.runtime.connect({ name: 'synco-redux' });
          port.onDisconnect.addListener(f);
          port.onDisconnect.fire(port);
        }
        """)
        // Nobody told yet; each one later than the last.
        #expect(c.evaluateScript("heard.length")?.toInt32() == 0)
        #expect(c.evaluateScript("timers.map((t) => t[1]).join()")?.toString() == "50,100,200,400")
        c.evaluateScript("timers.forEach((t) => t[0]())")
        #expect(c.evaluateScript("heard.join()")?.toString() == "synco-redux,synco-redux,synco-redux,synco-redux")
        // Never more than a minute.
        c.evaluateScript("""
        timers = [];
        for (let i = 0; i < 12; i++) { const port = chrome.runtime.connect({ name: 'x' }); port.onDisconnect.addListener(f); port.onDisconnect.fire(port); }
        """)
        #expect(c.evaluateScript("Math.max(...timers.map((t) => t[1]))")?.toInt32() == 60000)
    }

    @Test func anOrdinaryDisconnectIsToldAtOnceAndAnOpenPortResetsTheWait() throws {
        let c = try context()
        c.evaluateScript("""
        const f = (p) => heard.push('gone');
        const bad = chrome.runtime.connect({ name: 'a' }); bad.onDisconnect.addListener(f); bad.onDisconnect.fire(bad);
        fails = false;
        const good = chrome.runtime.connect({ name: 'b' }); good.onDisconnect.addListener(f);
        good.onMessage.fire({ hello: true });
        good.onDisconnect.fire(good);
        """)
        // The ordinary one at once, the failed one waits.
        #expect(c.evaluateScript("heard.join()")?.toString() == "gone")
        #expect(c.evaluateScript("timers.map((t) => t[1]).join()")?.toString() == "50")
        // A port that opened: the next failure waits the shortest again.
        c.evaluateScript("""
        fails = true; timers = [];
        const again = chrome.runtime.connect({ name: 'c' }); again.onDisconnect.addListener(f); again.onDisconnect.fire(again);
        """)
        #expect(c.evaluateScript("timers.map((t) => t[1]).join()")?.toString() == "50")
    }

    @Test func itsListenersAreStillTheExtensionsOwn() throws {
        let c = try context()
        // NordPass asks hasListener before adding its own, on every port.
        #expect(c.evaluateScript("""
        (() => {
          const f = () => {};
          const port = root.browser.runtime.connect({ name: 'synco-redux' });
          const before = port.onDisconnect.hasListener(f);
          port.onDisconnect.addListener(f);
          const after = port.onDisconnect.hasListener(f);
          port.onDisconnect.removeListener(f);
          return [before, after, port.onDisconnect.hasListener(f), port.onDisconnect.l.length].join();
        })()
        """)?.toString() == "false,true,false,0")
    }
}
