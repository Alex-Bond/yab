import JavaScriptCore
import Testing
@testable import Fast

/// chrome.permissions with a site that has a port (extension-shims.js):
/// Chrome takes "http://127.0.0.1:8080/*", WebKit throws that it is no
/// pattern. 1Password asks contains() for the page in front and threw on
/// every page with a port (release QA, 0.0.20).
@MainActor
@Suite(.serialized)
struct ExtensionPermissionPortsTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        // WebKit's chrome.permissions, as strict as it is about patterns.
        context.evaluateScript(#"""
        var asked = [], unheld = [];
        const strict = (name) => (arg) => {
          // A port, or a scheme WebKit has no patterns for (ftp, ws, wss).
          for (const o of (arg && arg.origins) || []) if (/:\/\/[^/]*:(\d+|\*)\//.test(o) || /^(ftp|wss?|urn):/i.test(o)) {
            return Promise.reject(new Error("Invalid call to permissions." + name + "(). The 'origins' value is invalid, because '" + o + "' is not a valid pattern."));
          }
          asked.push([name, (arg && arg.origins) || []]);
          return Promise.resolve(!(name === "contains" && ((arg && arg.origins) || []).some((o) => unheld.includes(o))));
        };
        var chrome = { permissions: { contains: strict("contains"), request: strict("request"), remove: strict("remove"),
                                      getAll: () => Promise.resolve({ permissions: [], origins: [] }) } };
        var runtime = { getManifest: () => ({ permissions: ["tabs", "proxy"] }) };
        function native(name) { return Promise.resolve(name === "permissions.ask" ? true : []); }
        function withLastError(e, callback) { callback(undefined); }
        function put(o, k, v) { o[k] = v; }
        var results = {};
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  if (chrome.permissions) {"))
        let end = try #require(script.range(of: "// chrome.userScripts", range: start.upperBound..<script.endIndex))
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(context.exception == nil)
        return context
    }

    private func settle(_ context: JSContext, _ js: String) async throws {
        context.evaluateScript(js)
        try #require(context.exception == nil)
        // Promise jobs run as JavaScriptCore drains its queue between calls.
        for _ in 0..<10 { context.evaluateScript("0"); try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSiteWithAPortIsAskedWithoutIt() async throws {
        let c = try context()
        try await settle(c, #"""
        chrome.permissions.contains({ origins: ["http://127.0.0.1:63871/*"] })
          .then(v => results.contains = v, e => results.contains = "threw " + e.message);
        chrome.permissions.request({ origins: ["https://localhost:8443/*"] })
          .then(v => results.request = v, e => results.request = "threw " + e.message);
        chrome.permissions.remove({ origins: ["http://*.example.com:*/*"] })
          .then(v => results.remove = v, e => results.remove = "threw " + e.message);
        """#)
        #expect(c.evaluateScript("results.contains")?.toBool() == true)
        #expect(c.evaluateScript("results.request")?.toBool() == true)
        #expect(c.evaluateScript("results.remove")?.toBool() == true)
        let asked = c.evaluateScript("JSON.stringify(asked)")?.toString() ?? ""
        #expect(asked.contains(#""http://127.0.0.1/*""#))
        #expect(asked.contains(#""https://localhost/*""#))
        #expect(asked.contains(#""http://*.example.com/*""#))
        #expect(!asked.contains(":63871") && !asked.contains(":8443"))
    }

    @Test func otherPatternsPassAsTheyAre() async throws {
        let c = try context()
        try await settle(c, #"""
        chrome.permissions.contains({ origins: ["https://github.com/*", "<all_urls>", "*://*/*"] })
          .then(v => results.contains = v, e => results.contains = "threw " + e.message);
        """#)
        #expect(c.evaluateScript("results.contains")?.toBool() == true)
        #expect(c.evaluateScript("JSON.stringify(asked)")?.toString() == #"[["contains",["https://github.com/*","<all_urls>","*://*/*"]]]"#)
    }

    /// Proton VPN's popup asks for the proxy with every site over http,
    /// https, ftp, ws and wss in one list, and stayed on "Allow VPN
    /// permissions" when WebKit refused the list over ftp (feedback #161,
    /// #166). ftp is left out, ws and wss are asked as http and https.
    @Test func protonVPNsQuestionIsAskedInWebKitsSchemes() async throws {
        let c = try context()
        try await settle(c, #"""
        var proton = { permissions: ["proxy"], origins: ["http://*/*", "https://*/*", "ftp://*/*", "ws://*/*", "wss://*/*",
          "https://account.protonvpn.com/*", "https://account.proton.me/*"] };
        chrome.permissions.contains(proton).then(v => results.contains = v, e => results.contains = "threw " + e.message);
        chrome.permissions.request(proton).then(v => results.request = v, e => results.request = "threw " + e.message);
        chrome.permissions.remove({ origins: ["ftp://*/*", "wss://example.com/*"] })
          .then(v => results.remove = v, e => results.remove = "threw " + e.message);
        """#)
        #expect(c.evaluateScript("results.contains")?.toBool() == true)
        #expect(c.evaluateScript("results.request")?.toBool() == true)
        #expect(c.evaluateScript("results.remove")?.toBool() == true)
        let asked = c.evaluateScript("JSON.stringify(asked)")?.toString() ?? ""
        #expect(asked.contains(#"["contains",["http://*/*","https://*/*","https://account.protonvpn.com/*","https://account.proton.me/*"]]"#))
        #expect(asked.contains(#"["remove",["https://example.com/*"]]"#))
        #expect(!asked.contains("ftp:") && !asked.contains("ws:") && !asked.contains("wss:"))
    }

    /// Left out, ftp makes nothing true by itself: with a site not held,
    /// the same question is still no.
    @Test func protonVPNsQuestionStaysNoWithoutTheSites() async throws {
        let c = try context()
        try await settle(c, #"""
        unheld = ["https://account.proton.me/*"];
        chrome.permissions.contains({ permissions: ["proxy"], origins: ["ftp://*/*", "wss://*/*", "https://account.proton.me/*"] })
          .then(v => results.contains = v, e => results.contains = "threw " + e.message);
        chrome.permissions.contains({ permissions: ["proxy", "bookmarks"], origins: ["ftp://*/*"] })
          .then(v => results.lacking = v, e => results.lacking = "threw " + e.message);
        """#)
        #expect(c.evaluateScript("results.contains")?.toBool() == false)
        #expect(c.evaluateScript("results.contains")?.isBoolean == true)
        #expect(c.evaluateScript("results.lacking")?.isBoolean == true)
        #expect(c.evaluateScript("results.lacking")?.toBool() == false)
    }

    /// WebKit tells onAdded of the site a press of the button lends
    /// (activeTab) and onRemoved as it goes back; Chrome tells neither.
    /// Transpose reloads the tab in front on any onAdded with sites, so
    /// each press started the video over (feedback #271). What a listener
    /// hears is only what getAll holds now and didn't before (onRemoved:
    /// held before, not now).
    @Test func aLentSiteIsNotToldAsAddedOrRemoved() async throws {
        let c = try #require(JSContext())
        c.evaluateScript(#"""
        var held = ["https://transpose.video/*"], heard = [];
        var setTimeout = () => 0;
        const event = () => { const l = new Set(); return { addListener: f => l.add(f), removeListener: f => l.delete(f),
          hasListener: f => l.has(f), fire: (d) => [...l].forEach(f => f(JSON.parse(JSON.stringify(d)))) }; };
        var chrome = { permissions: { contains: () => Promise.resolve(true), request: () => Promise.resolve(true),
          remove: () => Promise.resolve(true), getAll: () => Promise.resolve({ permissions: ["storage"], origins: held.slice() }),
          onAdded: event(), onRemoved: event() } };
        var runtime = { getManifest: () => ({ permissions: ["storage"] }) };
        function native() { return Promise.resolve([]); }
        function withLastError(e, callback) { callback(undefined); }
        function put(o, k, v) { o[k] = v; }
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  if (chrome.permissions) {"))
        let end = try #require(script.range(of: "// chrome.userScripts", range: start.upperBound..<script.endIndex))
        c.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        try #require(c.exception == nil)
        try await settle(c, #"""
        const p = chrome.permissions;
        const added = (d) => heard.push("added " + d.origins.join(" ")), removed = (d) => heard.push("removed " + d.origins.join(" "));
        p.onAdded.addListener(added); p.onRemoved.addListener(removed);
        var has = p.onAdded.hasListener(added);
        """#)
        // A press lends YouTube: nothing told, either way.
        try await settle(c, #"p.onAdded.fire({ origins: ["*://*.www.youtube.com/*"], permissions: [] });"#)
        try await settle(c, #"p.onRemoved.fire({ origins: ["*://*.www.youtube.com/*"], permissions: [] });"#)
        // Every site given through request: told.
        try await settle(c, #"held.push("*://*/*"); p.onAdded.fire({ origins: ["*://*/*"], permissions: [] });"#)
        // A press lends a site it holds already: not new, nothing told.
        try await settle(c, #"p.onAdded.fire({ origins: ["*://*.example.com/*"], permissions: [] });"#)
        // Every site taken back: told.
        try await settle(c, #"held = ["https://transpose.video/*"]; p.onRemoved.fire({ origins: ["*://*/*"], permissions: [] });"#)
        // A listener taken off hears nothing more.
        try await settle(c, #"p.onAdded.removeListener(added); held.push("https://a.test/*"); p.onAdded.fire({ origins: ["https://a.test/*"], permissions: [] });"#)
        #expect(c.evaluateScript("has")?.toBool() == true)
        #expect(c.evaluateScript("p.onAdded.hasListener(added)")?.toBool() == false)
        #expect(c.evaluateScript("JSON.stringify(heard)")?.toString() == #"["added *://*/*","removed *://*/*"]"#)
    }
}
