import JavaScriptCore
import Testing
@testable import Fast

/// chrome.omnibox (ExtensionOmnibox.swift, extension-shims.js): the field's
/// events reach the extension's listeners over its port, `suggest` answers
/// by the request's number, and a description's markup becomes words.
@MainActor
@Suite(.serialized)
struct ExtensionOmniboxTests {
    private func shim(keyword: Bool = true) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var sent = [], port = null, background = true;
        var chrome = {};
        var runtime = { getManifest: () => (\(keyword) ? { omnibox: { keyword: "fx" } } : {}), connectNative: (name) => {
          const listeners = [];
          port = { name, posted: [], onMessage: { addListener: (f) => listeners.push(f) }, onDisconnect: { addListener: () => {} },
                   postMessage: (m) => port.posted.push(m), say: (m) => listeners.forEach((f) => f(m)) };
          return port;
        } };
        function native(api, args) { sent.push([api, args]); return Promise.resolve(null); }
        function event() { const listeners = new Set(); return { addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f), listeners }; }
        function put2(name, api) { if (!chrome[name]) chrome[name] = api; }
        function setTimeout(f) { f(); }
        var results = {};
        """)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // The extension's keyword in the field (ExtensionOmnibox.swift)."))
        let end = try #require(script.range(of: "  put2(\"tabCapture\"", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil)
        return context
    }

    @Test func aWorkerWithAKeywordOpensItsPortAndSaysItListens() throws {
        let c = try shim()
        #expect(c.evaluateScript("port && port.name")?.toString() == "yab.omnibox")
        #expect(c.evaluateScript("JSON.stringify(port.posted[0])")?.toString() == #"{"ready":true}"#)
    }

    @Test func noKeywordNoPort() throws {
        let c = try shim(keyword: false)
        #expect(c.evaluateScript("port === null")?.toBool() == true)
        #expect(c.evaluateScript("typeof chrome.omnibox.onInputEntered.addListener")?.toString() == "function")
    }

    @Test func eventsReachTheListenersAndSuggestCarriesTheRequest() throws {
        let c = try shim()
        c.evaluateScript("""
        chrome.omnibox.onInputChanged.addListener((text, suggest) => { results.changed = text; suggest([{ content: "a", description: "A" }]); });
        chrome.omnibox.onInputEntered.addListener((text, disposition) => { results.entered = [text, disposition]; });
        port.say({ e: "onInputChanged", a: ["hel"], r: 7 });
        port.say({ e: "onInputEntered", a: ["hello", "newBackgroundTab"] });
        port.say({ e: "notAnEvent", a: [] });
        chrome.omnibox.setDefaultSuggestion({ description: "Search %s" });
        """)
        #expect(c.evaluateScript("results.changed")?.toString() == "hel")
        #expect(c.evaluateScript("JSON.stringify(results.entered)")?.toString() == #"["hello","newBackgroundTab"]"#)
        #expect(c.evaluateScript("JSON.stringify(sent)")?.toString()
                == #"[["omnibox.suggest",[7,[{"content":"a","description":"A"}]]],["omnibox.setDefaultSuggestion",[{"description":"Search %s"}]]]"#)
    }

    @Test func aDescriptionsMarkupBecomesWords() {
        #expect(ExtensionOmnibox.plain("<match>One</match> tab <dim>&amp; more</dim> <url>a.com</url>") == "One tab & more a.com")
    }

    @Test func aRowsAddressCarriesItsContentBack() throws {
        let url = try #require(ExtensionOmnibox.address("abc", content: "one x&y"))
        let back = try #require(ExtensionOmnibox.content(of: url))
        #expect(back.id == "abc" && back.content == "one x&y")
        #expect(ExtensionOmnibox.content(of: URL(string: "https://a.com")!) == nil)
    }
}
