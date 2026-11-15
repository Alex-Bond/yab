import AppKit

// Arc's boosts, brought over as the person's own (register #447: a new Yab
// person from Arc asked how to get boosts to work).
//
// Arc keeps each boost as an MV3 folder of its own under
// ~/Library/Application Support/Arc/boosts/<uuid>/: manifest.json,
// styles.css, content.js and boost.config.json, which says the site
// ("scope"), whether the boost is on ("extensionEnabled") and whether each of
// its two parts is ("components"). Arc loads them itself; they are not in
// its profile's extension list, so bringing Arc's extensions leaves them.
//
// A boost comes as a Yab boost for its site and the site's www (and x.com
// for a twitter.com one, where that site lives now), its stylesheet as a
// Look and its script, if it has one, as a Page. A Look takes no URLs and
// no escapes (BoostPackage.read): Arc's editor writes `\[data-…]` for a
// bracket, which is unescaped; a line that still loads a URL is left out
// and counted. On or off as it was in Arc.
enum ArcBoosts {
    struct Found: Identifiable, Equatable {
        /// The Yab boost's id: "arc-", the site and the start of Arc's id.
        let id: String
        let name: String
        let sites: [String]
        let files: [String: String]
        let enabled: Bool
        let rung: BoostPackage.Rung
        /// Lines of its stylesheet left out: they load a URL.
        let dropped: Int
        /// Its script, left out: Yab runs only readable code.
        let scriptLeft: Bool
    }

    /// Arc's boosts folder. A test world reads only the one it is given.
    static var folder: URL? {
        if Store.testing {
            // Its own folder, or the one beside a stand-in Arc (Bench `standIn`).
            if let given = ProcessInfo.processInfo.environment["YAB_ARC_BOOSTS"] { return URL(fileURLWithPath: given, isDirectory: true) }
            return Chromium.installed().first { $0.bundle == TabImport.arc }.map(folder(of:))
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Arc/boosts", isDirectory: true)
    }

    /// Every boost Arc has that can come, read off the disk.
    static func all() -> [Found] { all(in: folder) }

    /// The boosts folder beside an Arc's data: `Arc/boosts` for
    /// `Arc/User Data` (a test world's stand-in Arc has its own).
    static func folder(of source: Chromium.Source) -> URL {
        source.root.deletingLastPathComponent().appendingPathComponent("boosts", isDirectory: true)
    }

    static func all(in folder: URL?) -> [Found] {
        guard let folder, let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(read)
    }

    /// The ones not here yet.
    @MainActor static func waiting() -> [Found] {
        let found = all()
        seen = found
        let here = Set(Boosts.shared.records.map(\.id))
        return found.filter { !here.contains($0.id) }
    }

    /// Counts from the last explicit import preview only. Opening the field
    /// must not read Arc's scripts, manifests or site list in the background.
    @MainActor private static var seen: [Found]?
    @MainActor static func waitingSoon() -> [Found] {
        let here = Set(Boosts.shared.records.map(\.id))
        return (seen ?? []).filter { !here.contains($0.id) }
    }

    /// Keep the action discoverable before its first preview, without
    /// inspecting Arc's data to decide whether the action may be offered.
    @MainActor static var available: Bool {
        if seen != nil { return !waitingSoon().isEmpty }
        if Store.testing { return Chromium.standIns.withLock { $0.contains { $0.bundle == TabImport.arc } } }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: TabImport.arc) != nil
    }

    /// One of Arc's folders as a Yab boost, nil when it has nothing that runs.
    static func read(_ folder: URL) -> Found? {
        func json(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func text(_ name: String) -> String {
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        guard let manifest = json("manifest.json") else { return nil }
        let config = json("boost.config.json") ?? [:]
        let components = config["components"] as? [String: Any] ?? [:]
        func part(_ key: String, _ fallback: String) -> String? {
            let entry = components[key] as? [String: Any]
            if entry?["enabled"] as? Bool == false { return nil }
            let path = entry?["path"] as? String ?? fallback
            guard BoostPackage.validPath(path) else { return nil }
            let body = text(path)
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
        }
        let scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        let cssFile = scripts.compactMap { ($0["css"] as? [String])?.first }.first ?? "styles.css"
        let jsFile = scripts.compactMap { ($0["js"] as? [String])?.first }.first ?? "content.js"
        let rawCSS = part("contentStylesheet", cssFile)
        let rawJS = part("contentScript", jsFile)
        guard rawCSS != nil || rawJS != nil else { return nil }

        let sites = sites(scope: config["scope"] as? String, matches: scripts.flatMap { $0["matches"] as? [String] ?? [] })
        guard !sites.isEmpty else { return nil }
        let arcID = (config["id"] as? String) ?? folder.lastPathComponent
        let short = String(BoostPackage.slug(arcID).replacingOccurrences(of: "-", with: "").prefix(8))
        let main = sites == ["<all_urls>"] ? "every-site" : sites[0]
        let id = String(BoostPackage.slug("arc-" + main + "-" + short).prefix(64))
        let given = (config["name"] as? String) ?? (manifest["name"] as? String) ?? ""
        let name = String((given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Arc boost for \(main)" : given).prefix(100))

        let (css, dropped) = rawCSS.map(clean) ?? ("", 0)
        var files: [String: String] = [:]
        var content: [String: Any] = ["matches": patterns(sites), "run_at": "document_end"]
        if !css.isEmpty { files["style.css"] = css; content["css"] = ["style.css"] }
        let withScript = rawJS.map { body in
            var trial = files
            trial["content.js"] = body
            return trial
        }
        let intent = name + ", brought from Arc."
        func make(_ files: [String: String], js: Bool) -> [String: String] {
            var files = files
            var content = content
            if js { content["js"] = ["content.js"] }
            files["manifest.json"] = BoostScript.json(["manifest_version": 3, "name": name, "version": "1.0.0", "content_scripts": [content]])
            files["BOOST.md"] = "---\nname: \(name)\nsites: \(sites.joined(separator: ", "))\nmade: Arc\n---\n\n\(intent)"
            return files
        }
        // Its script if Yab can run it as it is, else its look alone.
        if let withScript, let package = try? BoostPackage.read(id: id, files: make(withScript, js: true), sites: sites) {
            return Found(id: id, name: name, sites: sites, files: package.files, enabled: config["extensionEnabled"] as? Bool ?? true,
                         rung: package.rung, dropped: dropped, scriptLeft: false)
        }
        guard !css.isEmpty, let package = try? BoostPackage.read(id: id, files: make(files, js: false), sites: sites) else { return nil }
        return Found(id: id, name: name, sites: sites, files: package.files, enabled: config["extensionEnabled"] as? Bool ?? true,
                     rung: package.rung, dropped: dropped, scriptLeft: rawJS != nil)
    }

    /// Arc's scope ("twitter.com") or its manifest's matches
    /// ("*://*.twitter.com/*") as exact sites: the site, its www, and where
    /// a site that moved lives now. Every site when Arc's boost is for all.
    static func sites(scope: String?, matches: [String]) -> [String] {
        if matches.contains("<all_urls>") || ["*", "all", "<all_urls>"].contains(scope ?? "") { return ["<all_urls>"] }
        var hosts: [String] = []
        let named = [scope].compactMap { $0 } + matches.compactMap { pattern -> String? in
            guard let start = pattern.range(of: "://") else { return nil }
            let rest = pattern[start.upperBound...]
            return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
        }
        for raw in named {
            var host = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if host.hasPrefix("*.") { host.removeFirst(2) }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            guard BoostPackage.host(host) != nil else { continue }
            for site in [host, "www." + host] + (moved[host] ?? []) where !hosts.contains(site) { hosts.append(site) }
        }
        return Array(hosts.prefix(8))
    }

    /// Sites that live elsewhere now: an Arc boost for twitter.com would
    /// never meet a page.
    static let moved: [String: [String]] = ["twitter.com": ["x.com", "www.x.com"]]

    static func patterns(_ sites: [String]) -> [String] {
        sites == ["<all_urls>"] ? ["<all_urls>"] : sites.flatMap { ["https://\($0)/*", "http://\($0)/*"] }
    }

    /// A stylesheet a Look may carry: escaped punctuation unescaped
    /// (`\[` is `[`), and the lines that load a URL or still escape left out.
    static func clean(_ css: String) -> (String, Int) {
        let unescaped = css.replacingOccurrences(of: #"\\([^0-9a-fA-F\s])"#, with: "$1", options: .regularExpression)
        var dropped = 0
        let lines = unescaped.components(separatedBy: "\n").filter { line in
            let bad = line.contains("\\") || line.range(of: #"(?i)url\s*\(|@import|image-set\s*\("#, options: .regularExpression) != nil
            if bad { dropped += 1 }
            return !bad
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), dropped)
    }

    // MARK: bringing

    /// Kept as they are, as the person kept them in Arc: no trial, since
    /// they are theirs already. Said in a word after, since nothing on
    /// screen shows boosts for sites not open.
    @MainActor @discardableResult
    static func bring(_ found: [Found]) -> Int {
        var brought = 0
        for one in found {
            guard let package = try? BoostPackage.read(id: one.id, files: one.files, sites: one.sites) else { continue }
            if (try? Boosts.shared.keepSynced(package, author: "Arc", enabled: one.enabled)) != nil { brought += 1 }
        }
        return brought
    }

    /// An import from Arc (the welcome's Bring, Settings' Bring In): its
    /// boosts come with its spaces and tabs, the import itself the yes, and
    /// the count goes in what the import says came. Nothing from any other
    /// browser.
    @MainActor @discardableResult
    static func bringIn(from source: Chromium.Source) -> Int {
        guard source.bundle == TabImport.arc, source.credentialAccess else { return 0 }
        let found = all(in: folder(of: source))
        seen = found
        let here = Set(Boosts.shared.records.map(\.id))
        return bring(found.filter { !here.contains($0.id) })
    }

    /// "3 boosts", for an import's summary.
    static func words(_ count: Int) -> String { count == 1 ? "1 boost" : "\(count) boosts" }

    /// Asked first, with each boost and what it may do, then brought.
    @MainActor static func offer(in browser: Browser) {
        let found = waiting()
        guard !found.isEmpty else {
            browser.announce(all().isEmpty ? "Arc has no boosts on this Mac" : "Arc’s boosts are here already", mark: "info.circle")
            return
        }
        let code = found.filter { $0.rung != .look }
        let lines = found.map { one in
            one.name + " · " + (one.sites.first.map { $0 == "<all_urls>" ? "every site" : Browser.site($0) } ?? "") + (one.enabled ? "" : " · off in Arc")
        }
        let detail = code.isEmpty
            ? "Each changes how its site looks. No code runs."
            : (code.count == 1 ? "One runs code" : "\(code.count) run code") + " on its site, as it did in Arc. Turn any of them off in Site Controls (⌘E)."
        Task {
            guard await Questions.shared.ask(Question(title: found.count == 1 ? "Bring 1 boost from Arc?" : "Bring \(found.count) boosts from Arc?",
                                                     detail: detail, lines: lines, lineGlyph: "wand.and.stars", glyph: "wand.and.stars",
                                                     yes: "Bring", place: .plain)) else { return }
            let brought = bring(found)
            browser.announce(brought == 1 ? "1 boost from Arc, in Site Controls" : "\(brought) boosts from Arc, in Site Controls", mark: "wand.and.stars")
        }
    }
}
