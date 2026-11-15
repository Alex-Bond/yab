import Foundation
import JavaScriptCore
import Testing
@testable import Fast

struct ExtensionMenuStoreTests {
    private func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    @Test func nativeStoreCapsDefinitionsAndKeepsTemplates() throws {
        let rows: [[Any]] = (0..<90).map { ["item-\($0)", ["title": "Search %s", "onclick": "discard", "tabId": 42]] }
        let encoded = try #require(ExtensionMenuStore.encode(try json(rows), version: "1"))
        let decoded = try #require(ExtensionMenuStore.decode(encoded, version: "1"))
        let items = try #require(JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [[Any]])
        #expect(items.count == 64)
        let props = try #require(items.first?[1] as? [String: Any])
        #expect(props["title"] as? String == "Search %s")
        #expect(props["onclick"] == nil && props["tabId"] == nil)
        #expect(props["id"] as? String == "item-0")
    }

    @Test func oldVersionsLegacyAndMalformedStoresAreDiscarded() throws {
        let legacy = #"[["item",{"title":"Selected private words"}]]"#
        #expect(ExtensionMenuStore.decode(legacy, version: "1") == nil)
        let encoded = try #require(ExtensionMenuStore.encode(legacy, version: "1"))
        #expect(ExtensionMenuStore.decode(encoded, version: "2") == nil)
        for bad in ["null", "{}", "[[]]", "[[true,{}]]", "[[{},{}]]", "[[1,null]]"] {
            #expect(ExtensionMenuStore.encode(bad, version: "1") == nil)
        }
        #expect(ExtensionMenuStore.encode(String(repeating: " ", count: ExtensionMenuStore.byteLimit + 1), version: "1") == nil)
    }

    @Test func numericAndStringIDsStayDistinctAndDuplicatesDoNotGrowTheStore() throws {
        let text = #"[[1,{"title":"Numeric"}],["1",{"title":"String"}],[1,{"title":"Duplicate"}]]"#
        let saved = try #require(ExtensionMenuStore.encode(text, version: "1"))
        let loaded = try #require(ExtensionMenuStore.decode(saved, version: "1"))
        let items = try #require(JSONSerialization.jsonObject(with: Data(loaded.utf8)) as? [[Any]])
        #expect(items.count == 2)
    }

    private func shim(separate: Bool = false) throws -> JSContext {
        let c = try #require(JSContext())
        c.evaluateScript(#"""
        var timers = [], saved = [], created = [], requests = [], failed = false;
        var background = true, held = [], importing = false, loadStore;
        function put(o, k, v) { o[k] = v; }
        function setTimeout(f, ms) { const t = { f, ms }; timers.push(t); return t; }
        function flush(ms) {
          for (const t of [...timers]) if (t.ms <= ms) {
            timers = timers.filter(x => x !== t); t.f();
          }
        }
        function afterImport(f) { if (!importing) return false; held.push(f); return true; }
        function Event() { this.listeners = []; }
        Event.prototype.addListener = function (f) { if (!this.listeners.includes(f)) this.listeners.push(f); };
        Event.prototype.removeListener = function (f) { this.listeners = this.listeners.filter(x => x !== f); };
        Event.prototype.hasListener = function (f) { return this.listeners.includes(f); };
        Event.prototype.fire = function (...a) { for (const f of [...this.listeners]) f(...a); };
        var workerEvents = {};
        var root = {
          addEventListener(type, listener) { (workerEvents[type] ||= new Event()).addListener(listener); },
          removeEventListener(type, listener) { if (workerEvents[type]) workerEvents[type].removeListener(listener); }
        };
        var runtime = { onInstalled: new Event(), onMessage: new Event(), lastError: null,
          getManifest: () => ({ version: '2' }), reload() { requests.push('reload'); } };
        var menus = {
          create(props, callback) {
            created.push(props);
            runtime.lastError = failed ? { message: 'refused' } : null;
            if (callback) callback();
            runtime.lastError = null;
            return props.id;
          },
          update(id, props, callback) { if (callback) callback(); },
          remove(id, callback) { if (callback) callback(); },
          removeAll(callback) { if (callback) callback(); }
        };
        var chrome = { runtime, contextMenus: menus, menus, tabs: { onUpdated: new Event() },
          webRequest: { onBeforeRequest: new Event() } };
        function native(api, args) {
          requests.push(api);
          if (api === 'menus.load') return new Promise(resolve => { loadStore = resolve; });
          if (api === 'menus.save') saved.push(JSON.parse(args[0]));
          return Promise.resolve(api === 'runtime.mayReload' ? true : false);
        }
        function load(items) { loadStore({ items: JSON.stringify(items), generation: 'current' }); }
        function stored() { return JSON.stringify(saved[saved.length - 1] || []); }
        """#)
        if separate { c.evaluateScript("chrome.menus = { ...menus };") }
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // Only definitions from startup or an install listener survive a worker."))
        let end = try #require(script.range(of: "  // webRequest listeners", range: start.upperBound..<script.endIndex))
        c.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
        let install = try #require(script.range(of: "  // WebKit says \"install\" again whenever an extension is taken up afresh:"))
        let worker = try #require(script.range(of: "  // A worker may add listeners only while it starts", range: install.upperBound..<script.endIndex))
        c.evaluateScript(String(script[install.lowerBound..<worker.lowerBound]))
        try #require(c.exception == nil, "\(String(describing: c.exception))")
        return c
    }

    private func run(_ c: JSContext, _ script: String) throws {
        c.evaluateScript(script)
        try #require(c.exception == nil, "\(String(describing: c.exception))")
    }

    @Test func laterTitlesAndPageIDsNeverReachSettings() throws {
        let c = try shim()
        try run(c, """
        menus.create({ id: 'search', title: 'Search %s', contexts: ['selection'] });
        load([]);
        """)
        try run(c, """
        flush(0);
        chrome.tabs.onUpdated.addListener(() => {
          menus.update('search', { title: 'Search private selected words' });
          for (let i = 0; i < 100; i++) menus.create({ id: 'page-' + i, title: 'Private page title' });
        });
        chrome.tabs.onUpdated.fire(); flush(300);
        """)
        #expect(c.evaluateScript("stored()")?.toString() == #"[["search",{"id":"search","title":"Search %s","contexts":["selection"]}]]"#)
    }

    @Test func installDefinitionsAreKeptAfterTheFirstEventAndTitlesStayAtCreation() throws {
        let c = try shim()
        try run(c, """
        runtime.onMessage.addListener(() => {}); runtime.onMessage.fire();
        runtime.onInstalled.addListener(() => {
          menus.create({ id: 'installed', title: 'Original %s' });
          menus.update('installed', { title: 'Expanded private words', enabled: false });
        });
        runtime.onInstalled.fire({ reason: 'update' }); load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("stored().includes('Original %s') && !stored().includes('private')")?.toBool() == true)
        #expect(c.evaluateScript("saved[0][0][1].enabled")?.toBool() == false)
    }

    @Test func deferredInstallTranslationStillCountsAsInstallation() throws {
        let c = try shim()
        try run(c, """
        runtime.onInstalled.addListener(() => menus.create({ id: 'installed', title: 'Static' }));
        runtime.onInstalled.fire({ reason: 'install' }); load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("saved[0][0][0]")?.toString() == "installed")
    }

    @Test func replaySkipsStartupIDsAndRemembersTheirNewDefinition() throws {
        let c = try shim()
        try run(c, """
        menus.create({ id: 'same', title: 'New definition' });
        load([['same', { title: 'Old definition' }], ['other', { title: 'Other' }]]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("created.filter(p => p.id === 'same').length")?.toInt32() == 1)
        #expect(c.evaluateScript("created.length")?.toInt32() == 2)
        #expect(c.evaluateScript("stored().includes('New definition') && !stored().includes('Old definition')")?.toBool() == true)
        #expect(c.evaluateScript("requests.filter(x => x === 'menus.load').length")?.toInt32() == 1)
    }

    @Test func dynamicIDsAlsoSuppressReplayWithoutBeingSaved() throws {
        let c = try shim()
        try run(c, """
        chrome.webRequest.onBeforeRequest.addListener(() => menus.create({ id: 'same', title: 'Private' }));
        chrome.webRequest.onBeforeRequest.fire();
        load([['same', { title: 'Static' }]]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("created.length")?.toInt32() == 1)
        #expect(c.evaluateScript("stored()")?.toString() == "[]")
    }

    @Test func rawWorkerEventsAlsoEndTheStartupWindow() throws {
        let c = try shim()
        try run(c, """
        menus.create({ id: 'static', title: 'Static' });
        var listener = () => menus.create({ id: 'request', title: 'Private URL' });
        root.addEventListener('fetch', listener);
        workerEvents.fetch.fire();
        root.removeEventListener('fetch', listener);
        load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("saved[0].length")?.toInt32() == 1)
        #expect(c.evaluateScript("stored().includes('Private')")?.toBool() == false)
        #expect(c.evaluateScript("workerEvents.fetch.listeners.length")?.toInt32() == 0)
    }

    @Test func replayWaitsForImportsAndHonorsRemovalOfParentsAndAllItems() throws {
        let c = try shim()
        try run(c, """
        importing = true;
        menus.remove('parent'); menus.create({ id: 'parent', title: 'New parent' });
        load([['parent', { title: 'Parent' }], ['child', { title: 'Child', parentId: 'parent' }], ['kept', { title: 'Keep' }]]);
        """)
        try run(c, "flush(0);")
        #expect(c.evaluateScript("created.length")?.toInt32() == 1)
        try run(c, "importing = false; held.shift()(); flush(300);")
        #expect(c.evaluateScript("created.length")?.toInt32() == 2)
        #expect(c.evaluateScript("created[1].id")?.toString() == "kept")
        let all = try shim()
        try run(all, "menus.removeAll(); menus.create({ id: 'new', title: 'New' }); load([['old', { title: 'Old' }]]);")
        try run(all, "flush(0); flush(300);")
        #expect(all.evaluateScript("created.length")?.toInt32() == 1)
        #expect(all.evaluateScript("saved[0][0][0]")?.toString() == "new")
    }

    @Test func shimCapsSavedItemsAndRejectsFailedCreates() throws {
        let c = try shim()
        try run(c, """
        failed = true; menus.create({ id: 'bad', title: 'Refused' }); failed = false;
        for (let i = 0; i < 90; i++) menus.create({ id: i, title: 'Static' });
        load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("saved[0].length")?.toInt32() == 64)
        #expect(c.evaluateScript("stored().includes('Refused')")?.toBool() == false)
    }

    @Test func separateMenuNamespacesShareOneStoreAndOneLimit() throws {
        let c = try shim(separate: true)
        try run(c, """
        for (let i = 0; i < 40; i++) menus.create({ id: 'first-' + i, title: 'First' });
        for (let i = 0; i < 40; i++) chrome.menus.create({ id: 'second-' + i, title: 'Second' });
        load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("saved[0].length")?.toInt32() == 64)
        #expect(c.evaluateScript("requests.filter(x => x === 'menus.load').length")?.toInt32() == 1)
        #expect(c.evaluateScript("stored().includes('First') && stored().includes('Second')")?.toBool() == true)
    }

    @Test func definitionArraysAreCopiedAndAnInstallScopeDoesNotLeakAfterAwait() throws {
        let c = try shim()
        try run(c, """
        var contexts = ['selection'];
        menus.create({ id: 'template', title: 'Search %s', contexts });
        contexts.push('Private page title');
        runtime.onInstalled.addListener(async () => {
          menus.create({ id: 'sync', title: 'Static' });
          await Promise.resolve();
          menus.create({ id: 'late', title: 'Private words' });
        });
        runtime.onInstalled.fire({ reason: 'update' }); load([]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("saved[0].length")?.toInt32() == 2)
        #expect(c.evaluateScript("stored().includes('Private')")?.toBool() == false)
    }

    @Test func reloadStopsPendingSavesAndReplayAndListenerIdentityIsPreserved() throws {
        let c = try shim()
        try run(c, """
        var listener = () => {};
        chrome.tabs.onUpdated.addListener(listener);
        var hadListener = chrome.tabs.onUpdated.hasListener(listener);
        chrome.tabs.onUpdated.removeListener(listener);
        var removedListener = !chrome.tabs.onUpdated.hasListener(listener);
        menus.create({ id: 'old', title: 'Old' }); runtime.reload();
        load([['replay', { title: 'Replay' }]]);
        """)
        try run(c, "flush(0); flush(300);")
        #expect(c.evaluateScript("hadListener && removedListener")?.toBool() == true)
        #expect(c.evaluateScript("saved.length")?.toInt32() == 0)
        #expect(c.evaluateScript("created.length")?.toInt32() == 1)
    }
}
