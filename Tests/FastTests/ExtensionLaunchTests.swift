import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// What a launch loads (ExtensionLaunch), and the shim's account of what a
/// worker listens for, with its stand-ins let go (docs/lazy-launch.md).
@MainActor
@Suite(.serialized)
struct ExtensionLaunchTests {
    private func facts(_ manifest: [String: Any]) -> ExtensionLaunch.Facts {
        ExtensionLaunch.facts(["version": "1.0"].merging(manifest) { _, new in new })
    }

    @Test func contentScriptsAndRulesLoadFirst() {
        let scripts = facts(["background": ["service_worker": "bg.js"], "content_scripts": [["matches": ["<all_urls>"], "js": ["c.js"]]]])
        #expect(ExtensionLaunch.need(scripts, heard: []).need == .first)
        let rules = facts(["background": ["service_worker": "bg.js"],
                           "declarative_net_request": ["rule_resources": [["id": "r", "enabled": true, "path": "r.json"]]]])
        #expect(ExtensionLaunch.need(rules, heard: []).need == .first)
        // Rules shipped off are no reason.
        let off = facts(["background": ["service_worker": "bg.js"],
                         "declarative_net_request": ["rule_resources": [["id": "r", "enabled": false, "path": "r.json"]]]])
        #expect(ExtensionLaunch.need(off, heard: []).need == .onUse)
    }

    @Test func onlyAnAdBlockersListsHoldTheFirstPages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blocks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func manifest(_ enabled: Bool) throws {
            let rules: [String: Any] = ["declarative_net_request": ["rule_resources": [["id": "r", "enabled": enabled, "path": "rules.json"]]]]
            try JSONSerialization.data(withJSONObject: rules).write(to: folder.appendingPathComponent("manifest.json"))
        }
        // A password manager's one header rule.
        try manifest(true)
        try Data(#"[{"id":1,"action":{"type":"modifyHeaders"}}]"#.utf8).write(to: folder.appendingPathComponent("rules.json"))
        #expect(!ExtensionLaunch.blocks(in: folder))
        // An ad blocker's list.
        try Data(repeating: 32, count: 200 * 1024).write(to: folder.appendingPathComponent("rules.json"))
        #expect(ExtensionLaunch.blocks(in: folder))
        // Shipped off.
        try manifest(false)
        #expect(!ExtensionLaunch.blocks(in: folder))
    }

    @Test func aWorkerThatMustRunEachLaunchLoads() {
        let worker = ["background": ["service_worker": "bg.js"]] as [String: Any]
        for permission in ["contextMenus", "alarms", "scripting", "webRequest", "declarativeNetRequest"] {
            let found = facts(worker.merging(["permissions": [permission]]) { _, new in new })
            #expect(ExtensionLaunch.need(found, heard: []).need == .launch, "\(permission)")
        }
        #expect(ExtensionLaunch.need(facts(worker.merging(["commands": ["toggle": [:]]]) { _, new in new }), heard: []).need == .launch)
        // The button's own key needs nothing more than the button.
        #expect(ExtensionLaunch.need(facts(worker.merging(["commands": ["_execute_action": [:]]]) { _, new in new }), heard: []).need == .onUse)
        #expect(ExtensionLaunch.need(facts(worker.merging(["externally_connectable": ["matches": ["https://a.com/*"]]]) { _, new in new }), heard: []).need == .launch)
    }

    @Test func whatTheWorkerHeardDecides() {
        let worker = facts(["background": ["service_worker": "bg.js"], "action": [:]])
        // Never heard from at this version: loaded, which hears it.
        #expect(ExtensionLaunch.need(worker, heard: nil).need == .launch)
        #expect(ExtensionLaunch.need(worker, heard: ["runtime.onStartup"]).need == .launch)
        #expect(ExtensionLaunch.need(worker, heard: ["tabs.onUpdated", "runtime.onMessage"]).need == .launch)
        #expect(ExtensionLaunch.need(worker, heard: ["runtime.onMessage", "runtime.onInstalled", "action.onClicked", "storage.onChanged"]).need == .onUse)
        #expect(ExtensionLaunch.need(worker, heard: [], openPage: true).need == .launch)
        // No worker at all: nothing to keep asleep.
        #expect(ExtensionLaunch.need(facts(["action": [:]]), heard: nil).need == .launch)
    }

    @Test func heardIsKeptByVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        ExtensionLaunch.write(["a": .init(version: "2", events: ["action.onClicked"], at: Date())], to: folder)
        let read = ExtensionLaunch.read(from: folder)
        #expect(ExtensionLaunch.events(read, id: "a", version: "2") == ["action.onClicked"])
        #expect(ExtensionLaunch.events(read, id: "a", version: "3") == nil)
        #expect(ExtensionLaunch.events(read, id: "b", version: "2") == nil)
    }

    /// The shim's block, run against a stand-in `chrome` whose events
    /// count their listeners as WebKit does.
    private func worker(mentioned: [String]) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(#"""
        var background = true, now = 0, timers = [], told = [], heldClicks = [], importing = false;
        function afterImport(f) { return false; }
        function setTimeout(f, ms) { const timer = {f, at: now + ms}; timers.push(timer); return timer; }
        function advance(ms) { now += ms; for (const t of [...timers]) if (t.at <= now) { timers = timers.filter(x => x !== t); t.f(); } }
        function put(o, k, v) { o[k] = v; }
        function native(api, args) { told.push([api, args]); return Promise.resolve(); }
        function event() {
          const listeners = [];
          return { addListener(f) { listeners.push(f); }, removeListener(f) { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
                   hasListeners() { return listeners.length > 0; }, fire(...a) { for (const f of [...listeners]) f(...a); }, count() { return listeners.length; } };
        }
        var chrome = { tabs: { onUpdated: event(), onCreated: event() }, windows: { onCreated: event() }, runtime: { onStartup: event(), onMessage: event(), onMessageExternal: event() },
                       webRequest: { onBeforeRequest: event() } };
        """#)
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  if (background) {\n    const mentioned"))
        let end = try #require(script.range(of: "  // What one of the extension's pages", range: start.upperBound..<script.endIndex))
        let list = String(data: try JSONSerialization.data(withJSONObject: mentioned), encoding: .utf8)!
        context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "__YAB_EVENTS__", with: list))
        try #require(context.exception == nil, "\(String(describing: context.exception))")
        return context
    }

    @Test func standInsForTabsNobodyHearsAreLetGo() throws {
        let js = try worker(mentioned: ["tabs.onUpdated", "tabs.onCreated", "windows.onCreated", "runtime.onStartup"])
        // The extension listens for tabs it creates and for the start.
        js.evaluateScript("chrome.tabs.onCreated.addListener(() => {}); chrome.runtime.onStartup.addListener(() => {});")
        #expect(js.evaluateScript("chrome.tabs.onUpdated.count()").toInt32() == 1)
        js.evaluateScript("chrome.tabs.onUpdated.fire(1, {}, {})")
        js.evaluateScript("advance(4000)")
        #expect(js.evaluateScript("told[0][0]").toString() == "background.listeners")
        #expect(js.evaluateScript("JSON.stringify(told[0][1][0])").toString() == #"["runtime.onStartup","tabs.onCreated"]"#)
        // Woken once for tabs.onUpdated with nobody listening.
        #expect(js.evaluateScript("JSON.stringify(told[0][1][1])").toString() == #"{"tabs.onUpdated":1}"#)
        js.evaluateScript("advance(16000)")
        // Gone from tabs.onUpdated, woken for nothing; windows.onCreated,
        // never woken, keeps its stand-in; tabs.onCreated keeps its
        // listener and stand-in; the start's stand-in is never let go.
        #expect(js.evaluateScript("chrome.tabs.onUpdated.count()").toInt32() == 0)
        #expect(js.evaluateScript("chrome.windows.onCreated.count()").toInt32() == 1)
        #expect(js.evaluateScript("chrome.tabs.onCreated.count()").toInt32() == 2)
        #expect(js.evaluateScript("chrome.runtime.onStartup.count()").toInt32() == 2)
        #expect(js.evaluateScript("told.length").toInt32() == 2)
        // Woken for nothing later, it goes at the next look.
        js.evaluateScript("chrome.windows.onCreated.fire({}); advance(20000)")
        #expect(js.evaluateScript("chrome.windows.onCreated.count()").toInt32() == 0)
        #expect(js.evaluateScript("told.length").toInt32() == 2)
    }

    @Test func messagesAndRequestsAreReadFromWebKit() throws {
        let js = try worker(mentioned: [])
        js.evaluateScript("chrome.runtime.onMessage.addListener(() => {}); chrome.webRequest.onBeforeRequest.addListener(() => {}); advance(4000)")
        let first = js.evaluateScript("JSON.stringify(told[0][1][0])").toString() ?? ""
        #expect(first == #"["runtime.onMessage","webRequest.onBeforeRequest"]"#)
    }
}
