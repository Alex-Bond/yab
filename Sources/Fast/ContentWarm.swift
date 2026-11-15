import Foundation
import WebKit

/// Extensions' content scripts compiled in a spare tab's process before the
/// page it will show, so the page's first frame doesn't wait for them.
///
/// An ad blocker runs over a megabyte of script in every frame as the
/// document starts (uBlock Origin Lite's scriptlets: 657 KB in the page's
/// world and 456 KB in its own for its default lists), and a new tab's
/// process compiled all of it before the page's own first script: the
/// whole of the adblock profile's extra time on "open tab" (+25-30 ms over
/// clean, docs/evidence/adblock-vs-chrome-2026-10-13.md). JavaScriptCore
/// keeps what it compiled in its process, keyed by the script's text and
/// its address's host, and a user script with both the same is not
/// compiled again: one evaluated in the spare's empty page, in a world of
/// its own, makes the page's copy cost 3 ms instead of 14 (measured with a
/// spare left 12 and 75 s, past the cache's working-set time).
///
/// The warm world is made inert first (no network, no timers, no
/// listeners), and its page is replaced by the real one, so what the
/// scripts do when run there is gone with it. YAB_CONTENT_WARM=0 turns it
/// off for an A/B.
@available(macOS 15.4, *)
@MainActor
enum ContentWarm {
    static let on = ProcessInfo.processInfo.environment["YAB_CONTENT_WARM"] != "0"
    /// What is compiled ahead at most, in characters: document_start first.
    static let cap = 3_000_000
    private static let world = WKContentWorld.world(name: "yab-warm")
    private static let evaluate = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")
    private typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, @escaping @convention(block) (Any?, Error?) -> Void) -> Void

    /// Each extension's registered content scripts (scripting.registerContentScripts),
    /// as its worker last told them: WebKit keeps them across launches and
    /// has no way to list them from here.
    private static var registered: [String: [[String: Any]]] = [:]
    /// Held as NSString, what WebKit is handed, but only for scripts that
    /// fit the warm-up budget. Reading every candidate first kept 17.9 MiB
    /// of strings even though only the first 3 million characters were used.
    private static var texts = TextCache()
    /// Views warmed already, with the scripts compiled in each: a spare
    /// kept is not warmed twice, and one warmed while the extensions were
    /// still loading at launch gets the rest once they are (`warm` again).
    private static let warmed = NSMapTable<WKWebView, NSMutableSet>.weakToStrongObjects()
    /// Spares warmed and not taken yet: nothing their scripts do may
    /// navigate them or open a window (Browser's decidePolicyFor and
    /// createWebViewWith refuse it). NordPass's redirectContent.js, meant
    /// for nordpass.com alone, sent a warmed spare there.
    private static let held = NSHashTable<WKWebView>.weakObjects()
    static func holds(_ web: WKWebView) -> Bool { held.contains(web) }
    /// Taken for a page: its own navigations from now on.
    static func release(_ web: WKWebView?) { if let web { held.remove(web) } }

    private static func file(_ id: String) -> URL {
        Extensions.folder(for: id).appendingPathComponent("_yab/registered.json")
    }

    static func registered(_ list: [[String: Any]], for id: String) {
        registered[id] = list
        let url = file(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: url, options: .atomic) }
    }

    private static func registered(_ id: String) -> [[String: Any]] {
        if let known = registered[id] { return known }
        let list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file(id)))) as? [[String: Any]] ?? []
        registered[id] = list
        return list
    }

    struct ScriptFile {
        let file: URL
        let url: URL
    }

    /// The selected prefix, in UTF-16 code units as NSString.length and the
    /// original warm-up cap count them. A rejected script keeps its length
    /// and timestamp only, so subsequent spares do not reread a large file.
    struct TextCache {
        private var texts: [String: (stamp: Date, text: NSString)] = [:]
        private var lengths: [String: (stamp: Date, count: Int)] = [:]

        mutating func scripts(_ files: [ScriptFile], cap: Int) -> [(source: NSString, url: URL)] {
            var kept: [String: (stamp: Date, text: NSString)] = [:]
            var inspected: [String: (stamp: Date, count: Int)] = [:]
            var out: [(source: NSString, url: URL)] = []
            var size = 0
            for candidate in files {
                // nil skips an unreadable file; false stops at the first
                // script that cannot fit, without retaining its text.
                let admitted: Bool? = autoreleasepool {
                    let path = candidate.file.path
                    // URL resource values may cache a previous timestamp across calls.
                    let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    if let known = lengths[path], known.stamp == stamp, known.count > cap - size {
                        inspected[path] = known
                        return false
                    }
                    let text: NSString
                    if let hit = kept[path] ?? texts[path], hit.stamp == stamp {
                        text = hit.text
                    } else if let read = try? NSString(contentsOf: candidate.file, encoding: String.Encoding.utf8.rawValue) {
                        text = read
                    } else {
                        return nil
                    }
                    inspected[path] = (stamp, text.length)
                    guard text.length <= cap - size else { return false }
                    size += text.length
                    kept[path] = (stamp, text)
                    out.append((text, candidate.url))
                    return true
                }
                if admitted == false { break }
            }
            texts = kept
            lengths = inspected
            return out
        }
    }

    /// Every loaded extension's content scripts, as WebKit will inject them
    /// into a page: their text, and the address WebKit gives them (its
    /// host is part of JavaScriptCore's key). Those run as the document
    /// starts first, then the rest, up to `cap`.
    static func scripts() -> [(source: NSString, url: URL)] {
        var early: [ScriptFile] = [], later: [ScriptFile] = []
        var seen = Set<String>()
        for (id, context) in Extensions.shared.contexts.sorted(by: { $0.key < $1.key }) {
            let folder = Extensions.folder(for: id)
            // Only scripts made for every site: one for a few sites only
            // could do there what it does on them.
            var entries: [(js: [String], runAt: String)] = []
            for entry in context.webExtension.manifest["content_scripts"] as? [[String: Any]] ?? []
            where everywhere(entry["matches"]) {
                entries.append((entry["js"] as? [String] ?? [], (entry["run_at"] as? String) ?? "document_idle"))
            }
            for entry in registered(id) where everywhere(entry["matches"]) {
                entries.append((entry["js"] as? [String] ?? [], (entry["runAt"] as? String) ?? "document_idle"))
            }
            for entry in entries {
                for name in entry.js {
                    let path = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !path.isEmpty, !path.hasPrefix("yab-late-"), seen.insert(id + "/" + path).inserted,
                          let local = ExtensionShims.inside(path, of: folder),
                          let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL else { continue }
                    let script = ScriptFile(file: local, url: url)
                    if entry.runAt == "document_start" { early.append(script) } else { later.append(script) }
                }
            }
        }
        return texts.scripts(early + later, cap: cap)
    }

    /// Whether match patterns take in every site, as an ad blocker's do.
    static func everywhere(_ matches: Any?) -> Bool {
        let list = matches as? [String] ?? []
        if list.contains("<all_urls>") || list.contains("*://*/*") { return true }
        return list.contains("http://*/*") && list.contains("https://*/*")
    }

    /// The scripts compiled in a spare's process: its view built from a
    /// configuration that carries the extensions, its process started.
    static func warm(_ web: WKWebView) {
        guard on, web.configuration.webExtensionController != nil, web.responds(to: evaluate) else { return }
        let done = warmed.object(forKey: web)
        let scripts = scripts().filter { !(done?.contains($0.url.absoluteString) ?? false) }
        guard !scripts.isEmpty else { return }
        if done == nil { warmed.setObject(NSMutableSet(), forKey: web) }
        warmed.object(forKey: web)?.addObjects(from: scripts.map(\.url.absoluteString))
        held.add(web)
        let call = unsafeBitCast(web.method(for: evaluate), to: Evaluate.self)
        let started = CFAbsoluteTimeGetCurrent()
        if done == nil { call(web, evaluate, inert as NSString, false, nil, nil, false, nil, world) { _, _ in } }
        for (index, script) in scripts.enumerated() {
            let last = index == scripts.count - 1
            call(web, evaluate, script.source, false, script.url as NSURL, nil, false, nil, world) { _, _ in
                guard last else { return }
                OpenTrace.mark(String(format: "warm.scripts %d %d", scripts.count, scripts.reduce(0) { $0 + $1.source.length }),
                               took: (CFAbsoluteTimeGetCurrent() - started) * 1000)
            }
        }
    }

    /// The warm world with nothing to reach outside itself or run later:
    /// the scripts' own top level runs, and that is all.
    private static let inert = """
    (() => {
      const g = globalThis, none = () => {}, gone = (o, k, v) => { try { Object.defineProperty(o, k, { value: v, configurable: true, writable: true }); } catch (e) {} };
      for (const k of ["fetch", "XMLHttpRequest", "WebSocket", "EventSource", "Worker", "SharedWorker", "BroadcastChannel",
                       "MutationObserver", "IntersectionObserver", "ResizeObserver", "PerformanceObserver", "Image", "Audio", "RTCPeerConnection"]) gone(g, k, undefined);
      for (const k of ["setTimeout", "setInterval", "requestAnimationFrame", "requestIdleCallback", "queueMicrotask",
                       "postMessage", "open", "alert", "confirm", "prompt", "print"]) gone(g, k, none);
      if (typeof EventTarget === "function") gone(EventTarget.prototype, "addEventListener", none);
      if (typeof Navigator === "function") gone(Navigator.prototype, "sendBeacon", none);
      if (typeof HTMLElement === "function") { gone(HTMLElement.prototype, "click", none); }
      if (typeof Document === "function") { gone(Document.prototype, "write", none); gone(Document.prototype, "writeln", none); }
    })();
    """
}
