import JavaScriptCore
import Testing
@testable import Fast

/// A command that reaches a starting worker during importScripts must
/// reach the listener the import adds. The real shim runs over a native
/// event stand-in; the form and vault contain only public synthetic data.
@MainActor
@Suite(.serialized)
struct ExtensionCommandImportTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var background = true, now = 0, timers = [], acceptsNativeListeners = true;
        function setTimeout(f, ms) { const timer = {f, at: now + (ms || 0)}; timers.push(timer); return timer; }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { timers = timers.filter(v => v !== t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        var nativeListeners = [];
        var onCommand = {
          addListener(f) {
            if (!acceptsNativeListeners) throw Error('Cannot add listener after startup');
            if (!nativeListeners.includes(f)) nativeListeners.push(f);
          },
          removeListener(f) { nativeListeners = nativeListeners.filter(g => g !== f); },
          hasListener(f) { return nativeListeners.includes(f); },
        };
        function fire(command, tab) { for (const f of [...nativeListeners]) f(command, tab); }
        var chrome = {runtime: {}, commands: {onCommand}}, heldClicks = [];
        var form = {username: {value: ''}, password: {value: ''}}, heard = [];
        var vault = [{username: 'fixture-user', password: 'fixture-password'}];
        function fill(command, tab) {
          heard.push([command, tab.id]);
          if (command !== 'autofill_login') return;
          form.username.value = vault[0].username;
          form.password.value = vault[0].password;
        }
        """#)
        let script = ExtensionShims.script
        let holdStart = try #require(script.range(of: "  let importing = 0;"))
        let holdEnd = try #require(script.range(of: "  if (worker && typeof root.importScripts", range: holdStart.upperBound..<script.endIndex))
        let start = try #require(script.range(of: "  if (background) {\n    const mentioned"))
        let end = try #require(script.range(of: "  // What one of the extension's pages or its worker posts to another", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[holdStart.lowerBound..<holdEnd.lowerBound])
            + "\nfunction begin() { importing++; } function end() { importing--; releaseHeld(); }\n"
            + String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_EVENTS__", with: #"["commands.onCommand"]"#))
        try #require(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return context
    }

    @Test func firstAutofillWaitsForItsImportedListener() throws {
        let c = try context()
        c.evaluateScript(#"""
        begin();
        fire('autofill_login', {id: 7});
        chrome.commands.onCommand.addListener(fill);
        var during = JSON.stringify(form);
        end();
        var returning = heard.length;
        advance(0);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.objectForKeyedSubscript("during")?.toString() == #"{"username":{"value":""},"password":{"value":""}}"#)
        #expect(c.objectForKeyedSubscript("returning")?.toInt32() == 0)
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["autofill_login",7]]"#)
        #expect(c.evaluateScript("JSON.stringify(form)")?.toString() == #"{"username":{"value":"fixture-user"},"password":{"value":"fixture-password"}}"#)
        #expect(c.evaluateScript("chrome.commands.onCommand.hasListener(fill)")?.toBool() == true)
    }

    @Test func queuedCommandsKeepTheirOrderAndRunOnce() throws {
        let c = try context()
        c.evaluateScript(#"""
        begin();
        fire('autofill_login', {id: 7});
        fire('generate_password', {id: 8});
        chrome.commands.onCommand.addListener(fill);
        end(); advance(0);
        fire('autofill_login', {id: 9});
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["autofill_login",7],["generate_password",8],["autofill_login",9]]"#)
    }

    @Test func aRemovedImportedListenerDoesNotFill() throws {
        let c = try context()
        c.evaluateScript(#"""
        begin(); fire('autofill_login', {id: 7});
        chrome.commands.onCommand.addListener(fill);
        chrome.commands.onCommand.removeListener(fill);
        end(); advance(0);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.evaluateScript("heard.length")?.toInt32() == 0)
        #expect(c.evaluateScript("form.username.value")?.toString() == "")
    }

    @Test func anExistingListenerDoesNotDuplicateTheImportedOne() throws {
        let c = try context()
        c.evaluateScript(#"""
        chrome.commands.onCommand.addListener((command, tab) => heard.push(['existing', tab.id]));
        begin(); fire('autofill_login', {id: 7});
        chrome.commands.onCommand.addListener(fill);
        end(); advance(0);
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["existing",7],["autofill_login",7]]"#)
    }

    @Test func webkitsLateListenerFallbackStillFillsOnce() throws {
        let c = try context()
        c.evaluateScript(#"""
        begin(); fire('autofill_login', {id: 7});
        acceptsNativeListeners = false;
        chrome.commands.onCommand.addListener(fill);
        end(); advance(0);
        fire('autofill_login', {id: 8});
        """#)
        #expect(c.exception == nil, "\(c.exception?.toString() ?? "")")
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"[["autofill_login",7],["autofill_login",8]]"#)
        #expect(c.evaluateScript("form.username.value")?.toString() == "fixture-user")
        #expect(c.evaluateScript("form.password.value")?.toString() == "fixture-password")
    }
}
