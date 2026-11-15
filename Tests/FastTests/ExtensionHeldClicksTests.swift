import JavaScriptCore
import Testing
@testable import Fast

/// The button pressed while an extension's worker sleeps or starts
/// (extension-shims.js, holdClicks): NordPass adds its click listener only
/// after its stored state is read, and the press that woke the worker was
/// lost (release QA 0.0.20, farm a272666189904a0d).
@MainActor
@Suite(.serialized)
struct ExtensionHeldClicksTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var now = 0, timers = [], pressedAgain = 0, heard = [];
        Date.now = () => now;
        function setTimeout(f, ms) { const timer = {f, at: now + (ms || 0)}; timers.push(timer); return timer; }
        function clearTimeout(timer) { timers = timers.filter(t => t !== timer); }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { clearTimeout(t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        // WebKit's onClicked: its listeners, and a press that fires them.
        var native = [], event = { addListener: f => native.push(f), removeListener: f => { native = native.filter(g => g !== f); } };
        function press(tab) { for (const f of native) f(tab); }
        // The worker importing a script (ExtensionImportHoldTests): what
        // arrives meanwhile is handed on once the import is over.
        var importing = false, afterwards = [];
        function afterImport(f) { if (!importing) return false; afterwards.push(f); return true; }
        function imported() { importing = false; for (const f of afterwards.splice(0)) f(); }
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  const holdClicks = (event, pressAgain) => {"))
        let end = try #require(script.range(of: "  // End of holdClicks.", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]) + "\nvar held = holdClicks(event, () => pressedAgain++);")
        try #require(context.exception == nil)
        return context
    }

    /// Promise jobs run once the evaluation that queued them returns.
    private func run(_ context: JSContext, _ js: String) {
        context.evaluateScript(js)
        context.evaluateScript("0")
    }

    @Test func aPressDuringAnImportGoesOnceItIsOver() throws {
        let c = try context()
        run(c, """
            event.addListener((tab) => heard.push(tab.id));
            importing = true;
            press({id: 7});
            var during = heard.length;
            imported();
            """)
        #expect(c.exception == nil)
        #expect(c.evaluateScript("during")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == "[7]")
    }

    @Test func theShimListensFromTheWorkersFirstLine() throws {
        let c = try context()
        #expect(c.evaluateScript("native.length")?.toInt32() == 1)
        #expect(c.evaluateScript("event.hasListeners()")?.toBool() == false)
    }

    @Test func aPressBeforeTheListenerGoesToItOnceItIsAdded() throws {
        let c = try context()
        run(c, #"""
        press({id: 7});
        advance(1500);
        event.addListener(tab => heard.push(['first', tab.id]));
        event.addListener(tab => heard.push(['second', tab.id]));
        """#)
        #expect(c.exception == nil)
        // Both listeners added in that turn hear it, once.
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["first",7],["second",7]]"#)
        run(c, "advance(20000); press({id: 8});")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["first",7],["second",7],["first",8],["second",8]]"#)
        #expect(c.evaluateScript("pressedAgain")?.toInt32() == 0)
        #expect(c.evaluateScript("native.length")?.toInt32() == 1)
    }

    @Test func aPressAfterStartupWithNoListenerIsDroppedAsInChrome() throws {
        let c = try context()
        run(c, "advance(16000); press({id: 1}); event.addListener(tab => heard.push(tab.id));")
        #expect(c.evaluateScript("heard.length")?.toInt32() == 0)
        #expect(c.evaluateScript("timers.length")?.toInt32() == 0)
    }

    @Test func aPressNoListenerTakesIsGivenBackWhenStartupEnds() throws {
        let c = try context()
        run(c, "press({id: 1}); advance(14999);")
        #expect(c.evaluateScript("pressedAgain")?.toInt32() == 0)
        run(c, "advance(1); event.addListener(tab => heard.push(tab.id));")
        #expect(c.evaluateScript("pressedAgain")?.toInt32() == 1)
        #expect(c.evaluateScript("heard.length")?.toInt32() == 0)
    }

    @Test func choosingAPopupTakesTheHeldPressOnce() throws {
        let c = try context()
        run(c, "press({id: 1}); var chosen = held.popupChosen(); var again = held.popupChosen(); advance(20000);")
        #expect(c.evaluateScript("chosen")?.toBool() == true)
        #expect(c.evaluateScript("again")?.toBool() == false)
        // Taken for the popup: not handed to a listener, nor given back.
        run(c, "event.addListener(tab => heard.push(tab.id));")
        #expect(c.evaluateScript("heard.length")?.toInt32() == 0)
        #expect(c.evaluateScript("pressedAgain")?.toInt32() == 0)
    }

    @Test func removedListenersHearNothingAndAThrowDoesNotStopTheOthers() throws {
        let c = try context()
        run(c, #"""
        const gone = () => heard.push('gone');
        event.addListener(gone);
        event.removeListener(gone);
        var hasGone = event.hasListener(gone);
        event.addListener(() => { throw Error('boom'); });
        event.addListener(tab => heard.push(tab.id));
        press({id: 3});
        """#)
        #expect(c.evaluateScript("hasGone")?.toBool() == false)
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == "[3]")
        // The throw is rethrown later, on its own, as an uncaught error.
        #expect(c.evaluateScript("timers.length")?.toInt32() == 1)
    }
}
