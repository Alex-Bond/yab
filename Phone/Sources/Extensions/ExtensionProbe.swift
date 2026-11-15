import UIKit
import WebKit

/// A test run's compatibility probe (YAB_EXTENSION_PROBE="id,id,…"): each
/// extension installed from the store with no question, its background
/// given time to start, its popup drawn out of sight and pictured, and what
/// it asked for and lacked written to <profile>/extension-probe.json, so a
/// UI test can say which work. Each one is removed before the next.
/// YAB_EXTENSION_PROBE_BLOCKING=1 also asks the page in front for addresses
/// ad blockers stop, before any is added and with each, so a blocker's
/// declarativeNetRequest rules are seen working (or not) in WebKit.
@MainActor
enum ExtensionProbe {
    static func runIfAsked(_ host: ExtensionHost) {
        guard let list = ProcessInfo.processInfo.environment["YAB_EXTENSION_PROBE"], !list.isEmpty,
              let profile = LaunchOptions.current.profileDirectory, !profile.isEmpty else { return }
        let ids = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let folder = URL(fileURLWithPath: profile, isDirectory: true)
        let blocking = ProcessInfo.processInfo.environment["YAB_EXTENSION_PROBE_BLOCKING"] == "1"
        Task { await run(ids, host: host, into: folder, blocking: blocking) }
    }

    private static func run(_ ids: [String], host: ExtensionHost, into folder: URL, blocking: Bool) async {
        var results: [[String: Any]] = []
        var before: [String: String] = [:]
        func write(done: Bool) {
            var body: [String: Any] = ["done": done, "results": results]
            if blocking { body["blockedWithout"] = before }
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("extension-probe.json"), options: .atomic)
            }
        }
        try? await Task.sleep(for: .seconds(3))
        // The simulator's network can come up after the first page: asked
        // until a plain address loads, so a block is never a dead network.
        if blocking {
            for _ in 0..<15 {
                before = await requests(host)
                if plain.allSatisfy({ before[$0] == "loaded" }) { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        for id in ids {
            var result: [String: Any] = ["id": id]
            let started = Date()
            do {
                let item = try await host.install(id)
                result["name"] = item.name
                result["version"] = item.version
                // Its background: started, failed, or never answered.
                for _ in 0..<40 {
                    if host.logs[id]?.contains(where: { $0.hasPrefix("background") }) == true { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .seconds(4))
                if blocking { result["blocking"] = await blocks(host) }
                result["popup"] = await popup(id, host: host, into: folder)
                try? await Task.sleep(for: .seconds(2))
                result["problems"] = host.problems(id)
                result["problemDetails"] = host.problemDetails(id)
                result["verdict"] = host.compatibility(id).map { ["kind": $0.kind.rawValue, "reason": $0.reason] } ?? [:]
            } catch {
                result["installError"] = error.localizedDescription
            }
            result["log"] = host.logs[id] ?? []
            result["seconds"] = Int(Date().timeIntervalSince(started))
            results.append(result)
            write(done: false)
            host.remove(id)
            try? await Task.sleep(for: .seconds(1))
        }
        write(done: true)
    }

    /// Ads and trackers in EasyList, EasyPrivacy and AdGuard Base, and two
    /// addresses no blocker stops, to tell a block from no network.
    static let ads = ["https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
                      "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
                      "https://www.google-analytics.com/analytics.js"]
    static let plain = ["https://example.com/", "https://www.wikipedia.org/"]

    /// Each address asked from the page in front: "loaded" or why not.
    private static func requests(_ host: ExtensionHost) async -> [String: String] {
        guard let web = host.frontPage() else { return ["page": "none"] }
        let script = """
        const out = {};
        for (const u of list) {
          try { await fetch(u, { mode: 'no-cors', cache: 'no-store', credentials: 'omit' }); out[u] = 'loaded'; }
          catch (e) { out[u] = 'failed: ' + e.message; }
        }
        return out;
        """
        let answer = try? await web.callAsyncJavaScript(script, arguments: ["list": ads + plain], contentWorld: .defaultClient)
        var out = (answer as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        out["page"] = web.url?.absoluteString ?? ""
        return out
    }

    /// With one added: its rules given time to compile, then the page
    /// reloaded once in case they only reach the next load.
    private static func blocks(_ host: ExtensionHost) async -> [String: Any] {
        let started = Date()
        func stopsAll(_ found: [String: String]) -> Bool {
            ads.allSatisfy { found[$0]?.hasPrefix("failed") == true } && plain.allSatisfy { found[$0] == "loaded" }
        }
        var found: [String: String] = [:]
        for _ in 0..<12 {
            found = await requests(host)
            if stopsAll(found) { return ["requests": found, "seconds": Int(Date().timeIntervalSince(started)), "reloaded": false] }
            try? await Task.sleep(for: .seconds(2))
        }
        if let web = host.frontPage() {
            _ = web.reload()
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if !web.isLoading { break }
            }
            try? await Task.sleep(for: .seconds(2))
            found = await requests(host)
        }
        return ["requests": found, "seconds": Int(Date().timeIntervalSince(started)), "reloaded": true]
    }

    /// Its popup drawn in a view out of sight: how much it drew, and a picture.
    private static func popup(_ id: String, host: ExtensionHost, into folder: URL) async -> [String: Any] {
        guard let web = host.popupView(id) else { return ["has": false] }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        web.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
        web.alpha = 0.01
        window?.insertSubview(web, at: 0)
        defer { web.removeFromSuperview(); host.closePopup(id) }
        for _ in 0..<60 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(3))
        let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.length : -1")) as? Int ?? -1
        let nodes = (try? await web.evaluateJavaScript("document.querySelectorAll('*').length")) as? Int ?? -1
        web.alpha = 1
        let shot = try? await web.takeSnapshot(configuration: nil)
        let file = "probe-\(id).png"
        if let data = shot?.pngData() { try? data.write(to: folder.appendingPathComponent(file)) }
        return ["has": true, "text": text, "nodes": nodes, "url": web.url?.absoluteString ?? "", "picture": shot == nil ? "" : file]
    }
}
