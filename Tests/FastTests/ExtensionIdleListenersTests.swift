import Foundation
import JavaScriptCore
import Testing
@testable import Fast

struct ExtensionIdleListenersTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var chrome = { idle: {} }, timers = new Map(), nextTimer = 0;
        var calls = [], pending = [], heard = [];
        function put(object, key, value) { object[key] = value; }
        function setInterval(callback, ms) { const id = ++nextTimer; timers.set(id, callback); return id; }
        function clearInterval(id) { timers.delete(id); }
        function native(name, args) {
          calls.push([name, args]);
          return { then(callback) { pending.push(callback); return { catch() {} }; } };
        }
        function tick() { for (const callback of [...timers.values()]) callback(); }
        function answer(state) { for (const callback of pending.splice(0)) callback(state); }
        function first(state) { heard.push('first:' + state); }
        function second(state) { heard.push('second:' + state); }
        """)
        let script = ExtensionShims.script
        let eventStart = try #require(script.range(of: "  const event = () => {"))
        let eventEnd = try #require(script.range(of: "\n\n  // Chrome's favicon permission", range: eventStart.upperBound..<script.endIndex))
        context.evaluateScript(String(script[eventStart.lowerBound..<eventEnd.lowerBound]))
        let start = try #require(script.range(of: "  if (chrome.idle && !chrome.idle.onStateChanged) {"))
        let end = try #require(script.range(of: "  define(\"power\"", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil)
        return context
    }

    @Test func removingTheLastListenerStopsNativePolling() throws {
        let c = try context()
        c.evaluateScript("""
        chrome.idle.onStateChanged.addListener(first);
        chrome.idle.onStateChanged.removeListener(first);
        tick();
        """)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 0)
        #expect(c.evaluateScript("chrome.idle.onStateChanged.hasListeners()")?.toBool() == false)
    }

    @Test func anotherListenerKeepsOneTimerAndStillHearsChanges() throws {
        let c = try context()
        c.evaluateScript("""
        chrome.idle.onStateChanged.addListener(first);
        chrome.idle.onStateChanged.addListener(first);
        chrome.idle.onStateChanged.addListener(second);
        chrome.idle.onStateChanged.removeListener(first);
        tick(); answer('idle');
        """)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 1)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 1)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:idle")
        c.evaluateScript("chrome.idle.onStateChanged.removeListener(second); tick()")
        #expect(c.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 1)
    }

    @Test func aLaterSubscriptionRestartsOneTimerWithTheChosenInterval() throws {
        let c = try context()
        c.evaluateScript("""
        chrome.idle.onStateChanged.addListener(first);
        chrome.idle.onStateChanged.removeListener(first);
        chrome.idle.setDetectionInterval(120);
        chrome.idle.onStateChanged.addListener(second);
        chrome.idle.onStateChanged.addListener(second);
        tick(); answer('locked');
        """)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 1)
        #expect(c.evaluateScript("calls[0][1][0]")?.toInt32() == 120)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:locked")
        c.evaluateScript("chrome.idle.onStateChanged.removeListener(second); tick(); answer('active')")
        #expect(c.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:locked")
    }

    @Test func aPreviousSubscriptionCannotAnswerTheNextOne() throws {
        let c = try context()
        c.evaluateScript("""
        chrome.idle.onStateChanged.addListener(first);
        tick();
        chrome.idle.onStateChanged.removeListener(first);
        chrome.idle.setDetectionInterval(120);
        chrome.idle.onStateChanged.addListener(second);
        answer('idle');
        """)
        try #require(c.exception == nil)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 1)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 1)
        #expect(c.evaluateScript("calls[0][1][0]")?.toInt32() == 60)
        #expect(c.evaluateScript("heard.join()")?.toString() == "",
                "idle reply from a finished subscription must be ignored")
        // Discard any stale delivery so it cannot satisfy the next check.
        // The same answer must still be new to the live subscription:
        // rejecting the old reply only after updating state would lose it.
        c.evaluateScript("heard.length = 0; tick(); answer('idle')")
        try #require(c.exception == nil)
        #expect(c.evaluateScript("calls[1][1][0]")?.toInt32() == 120)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:idle",
                "new idle subscription must receive its own same-state answer")
    }

    @Test func pendingRepliesStayValidWhileAnotherListenerRemains() throws {
        let c = try context()
        c.evaluateScript("""
        chrome.idle.onStateChanged.addListener(first);
        chrome.idle.onStateChanged.addListener(second);
        tick();
        chrome.idle.onStateChanged.removeListener(first);
        chrome.idle.onStateChanged.removeListener(first);
        chrome.idle.setDetectionInterval(120);
        answer('idle');
        """)
        try #require(c.exception == nil)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 1)
        #expect(c.evaluateScript("calls[0][1][0]")?.toInt32() == 60)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:idle")
        // More than one pending poll in this same subscription stays valid.
        c.evaluateScript("tick(); tick(); answer('locked')")
        try #require(c.exception == nil)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 3)
        #expect(c.evaluateScript("calls[1][1][0] === 120 && calls[2][1][0] === 120")?.toBool() == true)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:idle,second:locked")
        c.evaluateScript("tick(); chrome.idle.onStateChanged.removeListener(second); answer('active')")
        try #require(c.exception == nil)
        #expect(c.evaluateScript("timers.size")?.toInt32() == 0)
        #expect(c.evaluateScript("calls.length")?.toInt32() == 4)
        #expect(c.evaluateScript("heard.join()")?.toString() == "second:idle,second:locked")
    }
}
