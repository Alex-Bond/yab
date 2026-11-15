import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// A heavy content script run after the page's first frames
/// (ExtensionShims.late): NordPass's 7.4 MB in every frame held a new
/// tab's first frame by 400 ms. And the shim once per extension.
@Suite(.serialized)
struct ExtensionLateContentTests {
    private func package(_ files: [String: String], entries: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"Late test","version":"1.0","background":{"service_worker":"worker.js"},
         "web_accessible_resources":[{"resources":["img/*.png"],"matches":["https://*/*"]}],
         "content_scripts":[\(entries)]}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "self.x = 1;".write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        for (name, source) in files {
            try source.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    private func manifest(_ folder: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    private func entries(_ folder: URL) throws -> [[String]] {
        (try manifest(folder)["content_scripts"] as? [[String: Any]] ?? []).map { $0["js"] as? [String] ?? [] }
    }

    @Test func originPatterns() {
        #expect(ExtensionShims.originPattern("https://www.director.ai/?*") == "https://www.director.ai/*")
        #expect(ExtensionShims.originPattern("*://*/*") == "*://*/*")
        #expect(ExtensionShims.originPattern("file:///*") == "file:///*")
        #expect(ExtensionShims.originPattern("<all_urls>") == "<all_urls>")
    }

    /// MetaMask's shape: a provider in the page's world and a heavy relay in
    /// its own, both at document_start over the same sites. The relay waits
    /// (`lateRelay`); a heavy document_start script with no such partner
    /// (an ad blocker's cosmetic filters) does not.
    @Test func aWalletsRelayWaitsAndABlockersStartDoesNot() throws {
        guard ExtensionShims.lateKB > 0, ExtensionShims.lateRelay else { return }
        let heavy = "(function(){/*" + String(repeating: "x", count: ExtensionShims.lateKB * 1024) + "*/})();"
        let sites = #"["file://*/*","http://*/*","https://*/*"]"#
        let folder = try package(["js/relay.js": heavy, "js/inpage.js": "(()=>{})()", "js/cosmetic.js": heavy],
                                 entries: """
                                 {"matches":\(sites),"js":["js/relay.js"],"run_at":"document_start","all_frames":true},
                                 {"matches":\(sites),"js":["js/inpage.js"],"run_at":"document_start","all_frames":true,"world":"MAIN"},
                                 {"matches":["https://*/*"],"js":["js/cosmetic.js"],"run_at":"document_start"}
                                 """)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ExtensionShims.prepare(folder, fresh: true)
        let shim = ExtensionShims.shimOnce ? [] : ["yab-content.js"]
        let expected = [shim + ["yab-late-0.js"], ["yab-passkeys.js", "js/inpage.js"], shim + ["js/cosmetic.js"], shim + ["js/relay.js"]]
        #expect(try entries(folder).filter { $0 != ["yab-content.js"] } == expected)
        // The late file for web sites; on files the relay runs as before.
        let all = try #require(try manifest(folder)["content_scripts"] as? [[String: Any]]).filter { ($0["js"] as? [String]) != ["yab-content.js"] }
        #expect(all[0]["matches"] as? [String] == ["http://*/*", "https://*/*"])
        #expect(all[3]["matches"] as? [String] == ["file:///*"])
        #expect(all[3]["run_at"] as? String == "document_start")
        // Reachable from where the relay runs, in patterns any WebKit takes.
        let accessible = try manifest(folder)["web_accessible_resources"] as? [[String: Any]] ?? []
        let late = try #require(accessible.first { ($0["resources"] as? [String]) == ["js/relay.js"] })
        #expect(late["matches"] as? [String] == ["http://*/*", "https://*/*"])
        // Prepared again (a newer Yab), the same: no second twin.
        try "stale".write(to: folder.appendingPathComponent(ExtensionShims.stamp), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder)
        #expect(try entries(folder).filter { $0 != ["yab-content.js"] } == expected)
    }

    @Test func aHeavyEntryWaitsAndALightOneDoesNot() throws {
        guard ExtensionShims.lateKB > 0 else { return }
        let heavy = "(function(){globalThis.order.push('a');/*" + String(repeating: "x", count: ExtensionShims.lateKB * 1024) + "*/})();"
        let folder = try package(["js/a.js": heavy, "js/b.js": "(()=>{globalThis.order.push('b')})()", "js/c.js": "(()=>{})()",
                                  "js/open.js": "var shared = 1;" + heavy],
                                 entries: """
                                 {"matches":["https://*/*"],"js":["js/a.js","js/b.js"],"run_at":"document_end","all_frames":true},
                                 {"matches":["https://*/*"],"js":["js/c.js"]},
                                 {"matches":["http://a.test/x*"],"js":["js/a.js"],"run_at":"document_start"},
                                 {"matches":["https://*/*"],"js":["js/open.js"]},
                                 {"matches":["https://*/*"],"js":["js/a.js"],"world":"MAIN"}
                                 """)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ExtensionShims.prepare(folder, fresh: true)
        let once = ExtensionShims.shimOnce
        let shim = once ? [] : ["yab-content.js"]
        let expected = (once ? Array(repeating: ["yab-content.js"], count: ExtensionShims.shimScope ? 2 : 1) : []) + [shim + ["yab-late-0.js"], shim + ["js/c.js"], shim + ["js/a.js"],
                                                             shim + ["yab-late-3.js"], ["yab-passkeys.js", "js/a.js"]]
        #expect(try entries(folder) == expected)
        if once, ExtensionShims.shimScope {
            // The shim by reach (shimScope): all frames where the all-frames
            // entry goes, the top frame alone for the rest it doesn't cover.
            let shims = try #require(try manifest(folder)["content_scripts"] as? [[String: Any]]).prefix(2)
            #expect(shims.first?["matches"] as? [String] == ["https://*/*"])
            #expect(shims.first?["all_frames"] as? Bool == true)
            #expect(shims.last?["matches"] as? [String] == ["http://a.test/x*"])
            #expect(shims.last?["all_frames"] == nil)
            #expect(shims.allSatisfy { $0["run_at"] as? String == "document_start" })
        }
        let accessible = try manifest(folder)["web_accessible_resources"] as? [[String: Any]] ?? []
        #expect(accessible.count == 3)

        // Prepared again (a newer Yab), it starts from the package's files.
        try "stale".write(to: folder.appendingPathComponent(ExtensionShims.stamp), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder)
        #expect(try entries(folder) == expected)
        #expect((try manifest(folder)["web_accessible_resources"] as? [[String: Any]] ?? []).count == accessible.count)

        // Run: nothing before the frames, then each file in order.
        let context = try #require(JSContext())
        context.evaluateScript("""
        var order = [], frames = [], timers = [];
        var window = this; window.top = window;
        var document = { visibilityState: 'visible', addEventListener() {}, removeEventListener() {}, documentElement: {} };
        function requestAnimationFrame(f) { frames.push(f); }
        function setTimeout(f) { timers.push(f); }
        var sources = { 'js/a.js': \(String(data: try JSONSerialization.data(withJSONObject: [heavy]), encoding: .utf8)!)[0],
                        'js/b.js': "(()=>{globalThis.order.push('b')})()" };
        var chrome = { runtime: { getURL: (p) => p } };
        function fetch(url) { return Promise.resolve({ text: () => Promise.resolve(sources[url]) }); }
        """)
        context.evaluateScript(try String(contentsOf: folder.appendingPathComponent("yab-late-0.js"), encoding: .utf8))
        #expect(context.exception == nil)
        #expect(context.evaluateScript("order.length")?.toInt32() == 0)
        context.evaluateScript("frames.shift()(); frames.shift()(); while (timers.length) timers.shift()();")
        // A stub's fetches settle in microtasks, after the evaluateScript.
        context.evaluateScript("0")
        // The first file, then a frame for the page before the next (`lateYield`).
        #expect(context.evaluateScript("order.join()")?.toString() == (ExtensionShims.lateYield ? "a" : "a,b"))
        for _ in 0..<3 { context.evaluateScript("while (frames.length) frames.shift()(); while (timers.length) timers.shift()();") }
        #expect(context.evaluateScript("order.join()")?.toString() == "a,b")
    }

    @Test func aRestartDoesNotRunAManifestEntryAgainInTheSameDocument() throws {
        guard ExtensionShims.lateIdleKB > 0 else { return }
        let source = "globalThis.runs++;/*" + String(repeating: "x", count: (ExtensionShims.lateIdleKB + 1) * 1024) + "*/"
        let folder = try package(["js/a.js": source], entries: """
        {"matches":["https://*/*"],"js":["js/a.js"]},
        {"matches":["https://*/*"],"js":["js/a.js"]}
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        try ExtensionShims.prepare(folder, fresh: true)
        let first = try String(contentsOf: folder.appendingPathComponent("yab-late-0.js"), encoding: .utf8)
        let second = try String(contentsOf: folder.appendingPathComponent("yab-late-1.js"), encoding: .utf8)
        func document() throws -> JSContext {
            let context = try #require(JSContext())
            context.evaluateScript("""
            var runs = 0, fetches = 0, frames = [], timers = [], extensionID = 'one';
            var window = this; window.top = window;
            var document = { visibilityState: 'visible', addEventListener() {}, removeEventListener() {}, documentElement: {} };
            function requestAnimationFrame(f) { frames.push(f); }
            function setTimeout(f) { timers.push(f); }
            var chrome = { runtime: { getURL: (p) => 'chrome-extension://' + extensionID + '/' + p } };
            function fetch(url) { fetches++; return Promise.resolve({ text: () => Promise.resolve('globalThis.runs++') }); }
            """)
            return context
        }
        func flush(_ context: JSContext) {
            for _ in 0..<3 {
                context.evaluateScript("while (frames.length) frames.shift()(); while (timers.length) timers.shift()();")
                context.evaluateScript("0")
            }
        }
        let context = try document()
        // A context reload can inject another stub before the first one's
        // frames or fetch settle. These must share the pending run too.
        for _ in 0..<6 { context.evaluateScript(first) }
        flush(context)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("runs")?.toInt32() == 1)
        #expect(context.evaluateScript("fetches")?.toInt32() == 1)
        context.evaluateScript(first)
        flush(context)
        #expect(context.evaluateScript("runs")?.toInt32() == 1)
        // Separate manifest entries and extensions keep their own runs.
        context.evaluateScript(second)
        flush(context)
        #expect(context.evaluateScript("runs")?.toInt32() == 2)
        context.evaluateScript("extensionID = 'two'")
        context.evaluateScript(first)
        flush(context)
        #expect(context.evaluateScript("runs")?.toInt32() == 3)
        // A navigation has a fresh global even at the very same address.
        let next = try document()
        next.evaluateScript(first)
        flush(next)
        #expect(next.evaluateScript("runs")?.toInt32() == 1)
    }
}
