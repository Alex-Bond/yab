import JavaScriptCore
import Testing
@testable import Fast

/// chrome.debugger (ExtensionDebugger.swift, extension-shims.js): the shim
/// names a tab by its place and address and carries events from its port;
/// the page's side answers Runtime.evaluate in Chrome's shapes, the ones
/// recorded from Chrome in evals/extensions/debugger_chrome.json.
@MainActor
@Suite(.serialized)
struct ExtensionDebuggerTests {
    // MARK: the shim

    private func shim() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var sent = [], port = null;
        var chrome = { tabs: {
          get: (id) => id === 7 ? Promise.resolve({ id: 7, index: 2, url: "https://example.com/" }) : Promise.reject(new Error("no tab")),
          query: () => Promise.resolve([{ id: 7, index: 2, url: "https://example.com/", title: "Example" }, { id: 8, index: 3, url: "https://b.example/", title: "B" }]),
        } };
        var runtime = { connectNative: (name) => {
          const listeners = [], gone = [];
          port = { name, onMessage: { addListener: (f) => listeners.push(f) }, onDisconnect: { addListener: (f) => gone.push(f) },
                   say: (m) => listeners.forEach((f) => f(m)) };
          return port;
        } };
        var lastError = null;
        function native(api, args) {
          sent.push([api, args]);
          if (api === "debugger.send" && args[0].method === "Foo.bar") return Promise.reject(new Error('{"code":-32601,"message":"\'Foo.bar\' wasn\'t found"}'));
          if (api === "debugger.send") return Promise.resolve({ result: { type: "number", value: 2, description: "2" } });
          if (api === "debugger.attached") return Promise.resolve([{ tabId: 7, targetId: "T7" }]);
          return Promise.resolve(null);
        }
        function withLastError(e, callback) { lastError = e.message; callback(); lastError = null; }
        function event() { const listeners = new Set(); return { addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f), listeners }; }
        function put2(name, api) { if (!chrome[name]) chrome[name] = api; }
        var results = {};
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // The Chrome DevTools Protocol for a tab"))
        let end = try #require(script.range(of: "  put2(\"gcm\"", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil)
        return context
    }

    private func settle(_ context: JSContext, _ js: String) async throws {
        context.evaluateScript(js)
        try #require(context.exception == nil)
        for _ in 0..<10 { context.evaluateScript("0"); try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func attachNamesTheTabByPlaceAndAddressAndOpensThePort() async throws {
        let c = try shim()
        try await settle(c, #"chrome.debugger.attach({ tabId: 7 }, "1.3").then(() => results.attached = true)"#)
        #expect(c.evaluateScript("results.attached")?.toBool() == true)
        #expect(c.evaluateScript("JSON.stringify(sent[0])")?.toString()
                == #"["debugger.attach",[{"tabId":7,"index":2,"url":"https://example.com/","version":"1.3"}]]"#)
        #expect(c.evaluateScript("port && port.name")?.toString() == "yab.debugger")
    }

    @Test func aMissingTabOrATargetIdIsRefusedAsChromeSays() async throws {
        let c = try shim()
        try await settle(c, #"""
        chrome.debugger.attach({ tabId: 99 }, "1.3").catch((e) => results.missing = e.message);
        chrome.debugger.attach({ targetId: "abc" }, "1.3").catch((e) => results.target = e.message);
        """#)
        #expect(c.evaluateScript("results.missing")?.toString() == "No tab with given id 99.")
        #expect(c.evaluateScript("results.target")?.toString() == "Only tabs can be debugged in Yab.")
    }

    @Test func sendCommandAnswersByPromiseAndByCallback() async throws {
        let c = try shim()
        try await settle(c, #"""
        chrome.debugger.sendCommand({ tabId: 7 }, "Runtime.evaluate", { expression: "1+1" }).then((v) => results.value = v.result.value);
        chrome.debugger.sendCommand({ tabId: 7 }, "Foo.bar", {}, (v) => { results.cb = v === undefined; results.error = lastError; });
        """#)
        #expect(c.evaluateScript("results.value")?.toInt32() == 2)
        #expect(c.evaluateScript("results.cb")?.toBool() == true)
        #expect(c.evaluateScript("results.error")?.toString() == #"{"code":-32601,"message":"'Foo.bar' wasn't found"}"#)
        #expect(c.evaluateScript("JSON.stringify(sent[0][1][0])")?.toString() == #"{"tabId":7,"method":"Runtime.evaluate","params":{"expression":"1+1"}}"#)
    }

    @Test func eventsAndDetachesComeFromThePort() async throws {
        let c = try shim()
        try await settle(c, #"""
        chrome.debugger.onEvent.addListener((source, method, params) => results.event = [source.tabId, method, params.x]);
        chrome.debugger.onDetach.addListener((source, reason) => results.detach = [source.tabId, reason]);
        chrome.debugger.attach({ tabId: 7 }, "1.3").then(() => {
          port.say({ e: [{ tabId: 7 }, "Page.loadEventFired", { x: 1 }] });
          port.say({ d: [{ tabId: 7 }, "canceled_by_user"] });
        });
        """#)
        #expect(c.evaluateScript("JSON.stringify(results.event)")?.toString() == #"[7,"Page.loadEventFired",1]"#)
        #expect(c.evaluateScript("JSON.stringify(results.detach)")?.toString() == #"[7,"canceled_by_user"]"#)
    }

    @Test func getTargetsListsEveryTabAndWhichAreHeld() async throws {
        let c = try shim()
        try await settle(c, "chrome.debugger.getTargets().then((t) => results.targets = t.map((x) => [x.tabId, x.attached, x.id, x.type]))")
        #expect(c.evaluateScript("JSON.stringify(results.targets)")?.toString() == #"[[7,true,"T7","page"],[8,false,"YAB8","page"]]"#)
    }

    // MARK: Runtime.evaluate's answers

    private func evaluate(_ expression: String, byValue: Bool = true, wait: Bool = true) async throws -> [String: Any] {
        let context = try #require(JSContext())
        context.evaluateScript("var window = globalThis; var out = null;")
        let call = "(async function (expression, byValue, wait, context) {\n\(ExtensionDebugger.evaluation)\n})"
        let function = try #require(context.evaluateScript(call))
        try #require(context.exception == nil)
        let promise = function.call(withArguments: [expression, byValue, wait, 1])
        context.setObject(promise, forKeyedSubscript: "pending" as NSString)
        context.evaluateScript("pending.then((v) => out = v, (e) => out = JSON.stringify({ threw: String(e) }))")
        for _ in 0..<20 where context.evaluateScript("out")?.isNull != false {
            context.evaluateScript("0")
            try await Task.sleep(for: .milliseconds(5))
        }
        let text = try #require(context.evaluateScript("out")?.toString())
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func result(_ answer: [String: Any]) -> [String: Any] { answer["result"] as? [String: Any] ?? [:] }

    @Test func valuesComeInChromesShapes() async throws {
        let number = result(try await evaluate("21 * 2"))
        #expect(number["type"] as? String == "number" && number["value"] as? Int == 42 && number["description"] as? String == "42")
        let string = result(try await evaluate("'hi'"))
        #expect(string["type"] as? String == "string" && string["value"] as? String == "hi" && string["description"] == nil)
        #expect(result(try await evaluate("undefined")).keys.sorted() == ["type"])
        let null = result(try await evaluate("null"))
        #expect(null["subtype"] as? String == "null" && null["value"] is NSNull)
        let negative = result(try await evaluate("-0"))
        #expect(negative["unserializableValue"] as? String == "-0" && negative["value"] == nil)
        let object = result(try await evaluate("({ a: 1, b: [1, 'x'] })"))
        #expect(object["type"] as? String == "object" && (object["value"] as? [String: Any])?["a"] as? Int == 1)
        #expect(result(try await evaluate("(() => 1)"))["type"] as? String == "function")
    }

    @Test func byReferenceAnObjectIsKeptWithItsClassAndDescription() async throws {
        let array = result(try await evaluate("[1, 2, 3]", byValue: false))
        #expect(array["subtype"] as? String == "array" && array["className"] as? String == "Array"
                && array["description"] as? String == "Array(3)" && (array["objectId"] as? String)?.hasPrefix("yab.1.") == true)
    }

    @Test func whatCantComeByValueIsCDPsError() async throws {
        #expect(try await evaluate("Symbol('s')")["cdp"] as? String == "Object couldn't be returned by value")
        #expect(try await evaluate("(() => { const o = {}; o.o = o; return o })()")["cdp"] as? String == "Object reference chain is too long")
    }

    @Test func errorsComeAsExceptionDetails() async throws {
        let thrown = try await evaluate("throw new TypeError('bad')")
        let details = try #require(thrown["exceptionDetails"] as? [String: Any])
        let exception = try #require(details["exception"] as? [String: Any])
        #expect(details["text"] as? String == "Uncaught")
        #expect(exception["className"] as? String == "TypeError" && exception["subtype"] as? String == "error")
        #expect((exception["description"] as? String)?.hasPrefix("TypeError: bad") == true)
    }

    /// Claude retries its javascript tool as an async function when Chrome
    /// says exactly this, with a scriptId and no stack.
    @Test func aTopLevelReturnIsChromesIllegalReturnStatement() async throws {
        let answer = try await evaluate("{return 7\n}")
        let details = try #require(answer["exceptionDetails"] as? [String: Any])
        let exception = try #require(details["exception"] as? [String: Any])
        #expect(exception["className"] as? String == "SyntaxError")
        #expect(exception["description"] as? String == "SyntaxError: Illegal return statement")
        #expect(details["scriptId"] != nil && details["stackTrace"] == nil)
    }

    @Test func promisesAreAwaitedAndATopLevelAwaitWorks() async throws {
        #expect(result(try await evaluate("Promise.resolve(5)"))["value"] as? Int == 5)
        #expect(result(try await evaluate("{ await Promise.resolve('later') }"))["value"] as? String == "later")
        let rejected = try await evaluate("Promise.reject(new Error('no'))")
        let details = try #require(rejected["exceptionDetails"] as? [String: Any])
        #expect((details["text"] as? String)?.hasPrefix("Uncaught (in promise) Error: no") == true)
    }

    @Test func aCDPErrorIsChromesJSON() {
        #expect(ExtensionDebugger.Failure(code: -32601, "'Foo.bar' wasn't found").text == #"{"code":-32601,"message":"'Foo.bar' wasn't found"}"#)
    }
}
