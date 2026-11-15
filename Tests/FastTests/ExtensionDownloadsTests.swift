import Foundation
import JavaScriptCore
import Testing
@testable import Fast

@MainActor
struct ExtensionDownloadsTests {
    /// The shim's downloads events, run against a browser that answers
    /// from `replies` in turn and then never again.
    private func run(_ body: String, replies: [[String: Any]], worker: Bool = false, naming: Bool = false) throws -> [String: Any] {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "  // Downloads' events come from the browser"))
        let end = try #require(script.range(of: "  define(\"sidePanel\"", range: start.upperBound..<script.endIndex))
        let context = try #require(JSContext())
        let answers = String(data: try JSONSerialization.data(withJSONObject: replies), encoding: .utf8)!
        let source = """
        (() => {
          const asked = [], heard = [];
          const replies = \(answers);
          const event = () => { const listeners = new Set(); return { addListener: (f) => listeners.add(f),
            removeListener: (f) => listeners.delete(f), listeners }; };
          const chrome = { downloads: { onCreated: event(), onChanged: event(), onErased: event(), onDeterminingFilename: event() } };
          let nameReply;
          chrome.downloads.download = () => \(naming ? "new Promise(resolve => { nameReply = resolve; })" : "Promise.resolve(7)");
          const put = (target, key, value) => { target[key] = value; };
          const background = \(worker);
          const withLastError = () => {};
          const setTimeout = () => {};
          const queueMicrotask = (fn) => Promise.resolve().then(fn);
          const native = (api, args) => { asked.push([api, args[0]]);
            if (api === 'downloads.filenameListening') return Promise.resolve();
            if (api === 'downloads.filenameSuggestion') {
              heard.push(['suggest', args[0].filename]); nameReply?.(7); return Promise.resolve();
            }
            if (args[0] && args[0].now) return Promise.resolve({ seq: 3, events: [] });
            return replies.length ? Promise.resolve(replies.shift()) : new Promise(() => {}); };
        \(script[start.lowerBound..<end.lowerBound])
          globalThis.__result = { asked, heard };
          \(body)
        })()
        """
        context.evaluateScript(source)
        try #require(context.exception == nil, "\(context.exception!)")
        let value = try #require(context.evaluateScript("JSON.stringify(__result)")?.toString())
        return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    @Test func listenersHearWhatTheBrowserSaysInOrder() throws {
        let result = try run("""
          chrome.downloads.onChanged.addListener((delta) => heard.push(['changed', delta.id, delta.paused?.current]));
          chrome.downloads.onCreated.addListener((item) => heard.push(['created', item.id]));
        """, replies: [
            ["seq": 2, "events": [["name": "onCreated", "value": ["id": 1]],
                                   ["name": "onChanged", "value": ["id": 1, "paused": ["previous": false, "current": true]]]]],
        ])
        let heard = result["heard"] as? [[Any]] ?? []
        #expect(heard.count == 2)
        #expect(heard.first?.first as? String == "created")
        #expect(heard.last?[2] as? Bool == true)
        let asked = result["asked"] as? [[Any]] ?? []
        // A page's first question learns where things stand; the next goes on from there.
        #expect((asked.first?[1] as? [String: Any])?["worker"] as? Bool == false)
        #expect((asked.last?[1] as? [String: Any])?["after"] as? Int == 2)
    }

    @Test func aDownloadStartedHereTakesAMarkFirst() throws {
        let result = try run("""
          chrome.downloads.onChanged.addListener(() => {});
          chrome.downloads.download({ url: 'https://example.com/a.bin' });
        """, replies: [])
        let asked = (result["asked"] as? [[Any]] ?? []).map { $0[1] as? [String: Any] ?? [:] }
        #expect(asked.contains { $0["now"] as? Bool == true })
    }

    @Test func nobodyListeningAsksNothing() throws {
        let result = try run("", replies: [])
        #expect((result["asked"] as? [Any])?.isEmpty == true)
    }

    @Test func asynchronousFilenameReplyDoesNotWaitForTheDownloadIDItResolves() throws {
        let result = try run("""
          chrome.downloads.onCreated.addListener(item => heard.push(['created', item.id]));
          chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
            Promise.resolve().then(() => { suggest({filename:'Pictures/original.png'}); suggest({filename:'duplicate.png'}); });
            return true;
          });
          chrome.downloads.download({url:'https://fixture.invalid/image.png'}).then(id => heard.push(['id',id]));
        """, replies: [
            ["seq": 1, "events": [["name": "onCreated", "value": ["id": 7]]]],
            ["seq": 2, "events": [["name": "onDeterminingFilename", "value": ["request": "native-name", "item": ["id": 7]]]]],
        ], worker: true, naming: true)
        let heard = result["heard"] as? [[Any]] ?? []
        #expect(heard.count == 3)
        #expect(heard.first?[0] as? String == "suggest")
        #expect(heard.first?[1] as? String == "Pictures/original.png")
        #expect(heard.dropFirst().first?[0] as? String == "id")
        #expect(heard.last?[0] as? String == "created")
    }

    @Test func anItemSaysWhatChromeSays() {
        var item = ExtensionDownloads.Item(id: 4, url: "https://a.test/f.zip", finalUrl: "https://a.test/f.zip", startTime: Date(timeIntervalSince1970: 0))
        item.paused = true
        item.canResume = true
        let json = item.json
        #expect(json["state"] as? String == "in_progress")
        #expect(json["paused"] as? Bool == true)
        #expect(json["canResume"] as? Bool == true)
        #expect(json["startTime"] as? String == "1970-01-01T00:00:00.000Z")
        #expect(json["danger"] as? String == "safe")
    }
}
