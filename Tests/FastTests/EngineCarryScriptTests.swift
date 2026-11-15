import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Fast

/// engine-carry.js itself, in two WebKit stores that stand for the two engines.
@MainActor @Suite(.serialized)
struct EngineCarryScriptTests {
    private final class Side: NSObject, WKNavigationDelegate {
        let view: WKWebView
        private var loaded: CheckedContinuation<Void, Error>?

        override init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
            super.init()
            view.navigationDelegate = self
        }

        func open(_ origin: String) async throws {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                loaded = done
                view.loadSimulatedRequest(URLRequest(url: URL(string: origin + "/")!),
                                          responseHTML: "<!doctype html><meta charset=utf-8><title></title>")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loaded?.resume(throwing: error); loaded = nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loaded?.resume(throwing: error); loaded = nil
        }

        func run(_ body: String) async throws -> Any? {
            try await view.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        }

        func carry(_ fields: [String: Any]) async throws -> [String: Any] {
            let body = "return await (\(PageScript.load("engine-carry")))(fields)"
            return try await view.callAsyncJavaScript(body, arguments: ["fields": fields], in: nil, contentWorld: .defaultClient)
                as? [String: Any] ?? [:]
        }

        func close() { view.stopLoading(); view.navigationDelegate = nil }
    }

    /// Writes a base the way a site does, with one record JSON can't hold
    /// when `odd` (a cycle here, standing for MSAL's or Proton's CryptoKey).
    private static func seed(_ name: String, records: [String], odd: String?) -> String {
        let rows = records.map { "store.put({id: '\($0)', who: '\($0)'})" }.joined(separator: ";")
        let strange = odd.map { "const odd = {id: '\($0)', who: '\($0)'}; odd.self = odd; store.put(odd);" } ?? ""
        return """
        const base = await new Promise((done, failed) => {
          const opening = indexedDB.open('\(name)', 1);
          opening.onupgradeneeded = () => opening.result.createObjectStore('rows', {keyPath: 'id'});
          opening.onsuccess = () => done(opening.result); opening.onerror = () => failed(opening.error);
        });
        const writing = base.transaction(['rows'], 'readwrite'), store = writing.objectStore('rows');
        \(rows); \(strange)
        await new Promise((done, failed) => { writing.oncomplete = done; writing.onerror = () => failed(writing.error); });
        base.close();
        return true;
        """
    }

    private static func ids(_ name: String) -> String {
        """
        const names = (await indexedDB.databases()).map(row => row.name);
        if (!names.includes('\(name)')) return null;
        const base = await new Promise((done, failed) => {
          const opening = indexedDB.open('\(name)');
          opening.onsuccess = () => done(opening.result); opening.onerror = () => failed(opening.error);
        });
        if (!base.objectStoreNames.contains('rows')) { base.close(); return []; }
        const all = await new Promise((done, failed) => {
          const asking = base.transaction(['rows']).objectStore('rows').getAllKeys();
          asking.onsuccess = () => done(asking.result); asking.onerror = () => failed(asking.error);
        });
        base.close();
        return all.sort();
        """
    }

    /// The source's sign-in base has a record that can't cross: the
    /// destination's own copy of that base stays whole, while a base that
    /// crosses whole and localStorage still arrive.
    @Test func aBaseWithARecordThatCantCrossIsLeftAsTheDestinationHasIt() async throws {
        let origin = "https://carry.test"
        let source = Side(), destination = Side()
        defer { source.close(); destination.close() }
        try await source.open(origin)
        try await destination.open(origin)
        _ = try await source.run("localStorage.setItem('account', 'new'); return true")
        _ = try await source.run(Self.seed("signin", records: ["new-account"], odd: "new-key"))
        _ = try await source.run(Self.seed("plain", records: ["a", "b"], odd: nil))
        _ = try await destination.run("localStorage.setItem('account', 'old'); return true")
        _ = try await destination.run(Self.seed("signin", records: ["old-account"], odd: "old-key"))

        let head = try await source.carry(["op": "read", "limit": 24 * 1024 * 1024])
        #expect(head["skipped"] as? Int == 1)
        let length = head["length"] as? Int ?? 0
        var parts: [String] = [], at = 0
        while at < length {
            let got = try await source.carry(["op": "slice", "at": at, "size": 1024 * 1024])
            parts.append(got["part"] as? String ?? "")
            at = got["next"] as? Int ?? length
        }
        _ = try await destination.carry(["op": "begin"])
        for part in parts { _ = try await destination.carry(["op": "add", "part": part]) }
        _ = try await destination.carry(["op": "write"])

        #expect(try await destination.run("return localStorage.getItem('account')") as? String == "new")
        #expect(try await destination.run(Self.ids("plain")) as? [String] == ["a", "b"])
        // Before: deleted and written again without its key, ["new-account"].
        #expect(try await destination.run(Self.ids("signin")) as? [String] == ["old-account", "old-key"])
    }

    /// A part of a million UTF-16 units, in the worst letters JSON.stringify
    /// leaves in the carried text, crosses the helper's 4 MB wire both ways:
    /// as the reply YabCore writes (NSJSONSerialization) and as the request
    /// the client writes (JSONEncoder).
    @Test func aPartFitsTheHelpersWireWhateverItsLetters() throws {
        let limit = 4 * 1024 * 1024
        let context = JSContext()!
        // Every BMP unit outside the surrogates, inside a value that is
        // itself JSON text, as a site's localStorage often holds.
        context.evaluateScript("""
        let all = '';
        for (let unit = 0; unit < 0x10000; unit++) if (unit < 0xD800 || unit > 0xDFFF) all += String.fromCharCode(unit);
        var carried = JSON.stringify({local: [['key', JSON.stringify({value: all + '\\u{1F600}'})]], bases: [], whole: true, skipped: 0});
        """)
        let carried = context.objectForKeyedSubscript("carried").toString()!
        let replyFrame = try JSONSerialization.data(withJSONObject: ["part": ""]).count
        let requestFrame = try JSONEncoder().encode(["part": ""]).count
        var worst: (cost: Int, letter: Unicode.Scalar) = (0, " ")
        for letter in Set(carried.unicodeScalars) {
            let text = String(Character(letter))
            let reply = try JSONSerialization.data(withJSONObject: ["part": text]).count - replyFrame
            let request = try JSONEncoder().encode(["part": text]).count - requestFrame
            let units = text.utf16.count
            let cost = (max(reply, request) + units - 1) / units
            if cost > worst.cost { worst = (cost, letter) }
        }
        #expect(worst.cost <= 3, "U+\(String(worst.letter.value, radix: 16))")
        let letter = String(Character(worst.letter))
        let part = String(repeating: letter, count: 1024 * 1024 / letter.utf16.count)
        struct Wire: Encodable { let fields: [String: String]; let function: String }
        let reply = try JSONSerialization.data(withJSONObject: ["v": 1, "id": 1, "result": ["part": part, "next": 1 << 24]])
        let request = try JSONEncoder().encode(Wire(fields: ["op": "add", "part": part], function: PageScript.load("engine-carry")))
        #expect(reply.count < limit)
        #expect(request.count < limit)
    }
}
