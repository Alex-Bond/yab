import Foundation
import JavaScriptCore

/// A portable MV3 package. Parsing does not load code or grant permissions.
struct BoostPackage: Equatable {
    enum Rung: String, Codable { case look = "Look", page = "Page", tool = "Tool", app = "App" }
    struct Content: Equatable {
        let matches: [String]
        let css: [String]
        let js: [String]
    }
    let id: String
    let name: String
    let sites: [String]
    let intent: String
    let checks: [BoostCheck]
    let files: [String: String]
    let content: [Content]
    let rung: Rung
    let plugin: BoostPlugin

    var examples: [BoostExample] { (try? BoostExample.read(files["evals.yaml"], tools: plugin.tools)) ?? [] }

    var allSites: Bool { sites == ["<all_urls>"] }
    var canApplyEverywhere: Bool { !content.isEmpty && plugin == .empty && files["commands.json"] == nil && !files.keys.contains(where: { $0.hasPrefix("skills/") }) }

    var previewURL: URL? {
        if let line = files["BOOST.md"]?.components(separatedBy: .newlines).first(where: { $0.hasPrefix("preview: ") }),
           let url = URL(string: String(line.dropFirst(9))), ["http", "https"].contains(url.scheme ?? ""), sites.contains(url.host ?? ""), matches(url) { return url }
        return sites.first.flatMap { URL(string: "https://" + $0 + "/") }
    }

    var css: String { content.flatMap(\.css).compactMap { files[$0] }.joined(separator: "\n") }
    var js: String { content.flatMap(\.js).compactMap { files[$0] }.joined(separator: "\n;\n") }
    var permission: String {
        if allSites { return "Read and change every site you visit. Skipped on detected sign-in and payment pages, private tabs and Developer Mode." }
        let sites = sites.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }.joined(separator: ", ")
        guard rung != .look else { return "Change how \(sites) looks. No code runs." }
        let can = plugin.permissions.compactMap { Self.rights[$0] }
        let ai = plugin.permissions.contains("yab:task") || plugin.permissions.contains("yab:ask") || files["commands.json"] != nil
        // Tools, services and app pages alone never run inside the site's pages.
        return (content.isEmpty ? "Run code for \(sites), outside its pages." : "Run code on \(sites). It can read and change these pages.")
            + (plugin.tools.isEmpty ? "" : " Adds \(plugin.tools.count) agent tools.")
            + (can.isEmpty ? "" : " Can " + Self.list(can) + ".")
            + (plugin.every.map { " Checks public data every \(Int($0 / 60)) minutes." } ?? "")
            + (files["commands.json"] == nil ? "" : " Adds commands, quick actions or routines to Settings.")
            + (ai ? " Up to \(plugin.dailyLimit) AI calls a day." : "")
            + (plugin.siteActions.isEmpty ? "" : " Presses buttons on " + sites + ".")
            + (plugin.hosts.isEmpty ? "" : " Talks to " + plugin.hosts.joined(separator: ", ") + ".")
    }
    /// What each `yab:` permission lets a plugin do, in the card's words
    /// (BoostPlugin.permissions, chrome.yab in Skills/boosts).
    static let rights: [String: String] = [
        "yab:task": "start agent tasks", "yab:ask": "use your AI plan", "yab:memory": "use details you share",
        "yab:calendar": "read your next meeting", "yab:live": "add live folders", "yab:rows": "suggest links on New Tab",
        "yab:notify": "show notifications", "yab:route": "plan routes", "yab:summarize": "summarize pages of its site",
        "yab:translate": "translate text on this Mac",
    ]
    /// "a", "a and b", "a, b and c".
    static func list(_ words: [String]) -> String {
        words.count < 2 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + words.last!
    }
    /// True when this version may do something the kept one may not: a
    /// higher rung, another site, host, permission, tool or tool action, an
    /// app page, a service or commands, a shorter interval or a larger AI
    /// limit. Such an update waits for the person's Keep; anything else
    /// applies quietly.
    func widens(_ kept: BoostPackage) -> Bool {
        let order: [Rung] = [.look, .page, .tool, .app]
        let tools = Set(kept.plugin.tools.map(\.name))
        return order.firstIndex(of: rung)! > order.firstIndex(of: kept.rung)!
            || !Set(sites).isSubset(of: kept.sites) || (allSites && !kept.allSites)
            || !Set(plugin.siteActions).isSubset(of: kept.plugin.siteActions)
            || !Set(plugin.hosts).isSubset(of: kept.plugin.hosts)
            || !Set(plugin.permissions).isSubset(of: kept.plugin.permissions)
            || plugin.tools.contains { tool in !tools.contains(tool.name) || (tool.acts != nil && tool.acts != kept.plugin.tools.first { $0.name == tool.name }?.acts) }
            || (plugin.app != nil && kept.plugin.app == nil) || (plugin.service != nil && kept.plugin.service == nil)
            || (files["commands.json"] != nil && kept.files["commands.json"] == nil)
            || (plugin.every ?? .infinity) < (kept.plugin.every ?? .infinity)
            || plugin.dailyLimit > kept.plugin.dailyLimit
    }
    func matches(_ url: URL) -> Bool { allSites ? ["http", "https"].contains(url.scheme ?? "") : content.isEmpty ? sites.contains(url.host ?? "") : content.contains { $0.matches.contains { Self.matches($0, url) } } }

    struct Invalid: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func slug(_ name: String) -> String {
        name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? String($0) : "-" }
            .joined().split(separator: "-").joined(separator: "-")
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 180 && !path.hasPrefix("/") && !path.contains("\\")
            && !path.contains(":") && !path.contains("\0") && path.split(separator: "/").count <= 9
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    static func host(_ site: String) -> String? {
        let value = site.lowercased()
        guard value == site, value.count <= 253,
              value.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
              !value.contains("..") else { return nil }
        return value
    }

    /// Wildcards are allowed only in the path, never in the host or scheme.
    static func patternHost(_ pattern: String) -> String? {
        guard let url = URL(string: pattern), ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host, Self.host(host) != nil,
              pattern.hasPrefix("\(url.scheme!)://\(host)/") else { return nil }
        return host
    }

    static func matches(_ pattern: String, _ url: URL) -> Bool {
        if pattern == "<all_urls>" { return ["http", "https"].contains(url.scheme ?? "") }
        guard let source = URL(string: pattern), let host = patternHost(pattern),
              url.host?.lowercased() == host, source.scheme == url.scheme else { return false }
        let regex = "^" + NSRegularExpression.escapedPattern(for: source.path).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return (url.path.isEmpty ? "/" : url.path).range(of: regex, options: .regularExpression) != nil
    }

    static func merge(_ changes: [String: Any], into previous: [String: String]) throws -> [String: String] {
        var files = previous
        for (path, value) in changes {
            guard validPath(path) else { throw Invalid("Invalid file path: \(path)") }
            if value is NSNull { files.removeValue(forKey: path) }
            else if let text = value as? String { files[path] = text }
            else { throw Invalid("Files must contain text, or null to remove a file.") }
        }
        guard files.count <= 32, files.values.reduce(0, { $0 + $1.utf8.count }) <= 512_000 else {
            throw Invalid("A boost may contain at most 32 files and 512 KB.")
        }
        return files
    }

    static func read(id: String, files: [String: String], sites: [String]) throws -> BoostPackage {
        guard !id.isEmpty, id == slug(id), id.count <= 64 else { throw Invalid("Use a short lowercase name with letters, numbers and hyphens.") }
        guard !sites.isEmpty, sites.count <= 8, Set(sites).count == sites.count, sites == ["<all_urls>"] || sites.allSatisfy({ host($0) != nil }) else {
            throw Invalid("Name up to eight exact sites, such as youtube.com. Wildcard sites are not allowed.")
        }
        _ = try merge(files.mapValues { $0 as Any }, into: [:])
        for (path, text) in files where path.hasSuffix(".js") || path.hasSuffix(".html") {
            guard !text.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || [0x200B, 0x200C, 0x200D, 0xFEFF].contains($0.value) }),
                  !text.components(separatedBy: .newlines).contains(where: { $0.utf8.count > 2000 }),
                  text.range(of: #"(?i)\beval\s*\(|\bnew\s+Function\s*\(|\bimport\s*\("#, options: .regularExpression) == nil else {
                throw Invalid("Code must be readable: no minified lines, invisible Unicode, eval, Function constructors or dynamic imports (\(path)).")
            }
        }
        guard let manifest = files["manifest.json"], let data = manifest.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["manifest_version"] as? Int == 3,
              let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              value["version"] as? String != nil else { throw Invalid("Supply an MV3 manifest with a name and version.") }
        let allowed: Set<String> = ["manifest_version", "name", "version", "description", "content_scripts", "yab"]
        guard Set(value.keys).isSubset(of: allowed) else { throw Invalid("Boosts support named-site stylesheets and page scripts. Declare plugin capabilities inside yab metadata.") }
        guard value["yab"] == nil || value["yab"] is [String: Any],
              value["content_scripts"] == nil || value["content_scripts"] is [[String: Any]] else { throw Invalid("Invalid manifest structure.") }
        _ = try BoostContributions.read(files, sites: sites)
        let plugin = try BoostPlugin.parse(value["yab"] as? [String: Any] ?? [:], files: files)
        _ = try BoostExample.read(files["evals.yaml"], tools: plugin.tools)
        let scripts = value["content_scripts"] as? [[String: Any]] ?? []
        guard scripts.count <= 8, !scripts.isEmpty || !plugin.tools.isEmpty || plugin.app != nil || plugin.service != nil else {
            throw Invalid("The manifest needs content_scripts, tools, an app or a service.")
        }
        var content: [Content] = []
        for script in scripts {
            guard Set(script.keys).isSubset(of: ["matches", "css", "js", "run_at", "all_frames"]),
                  script["all_frames"] == nil || script["all_frames"] as? Bool == false,
                  script["run_at"] == nil || script["run_at"] as? String == "document_idle" || script["run_at"] as? String == "document_end",
                  let matches = script["matches"] as? [String], !matches.isEmpty,
                  matches.allSatisfy({ (sites == ["<all_urls>"] && $0 == "<all_urls>") || patternHost($0).map(sites.contains) == true }) else {
                throw Invalid("Content scripts must run in the main frame on the exact named sites, at document_end or document_idle.")
            }
            let css = script["css"] as? [String] ?? [], js = script["js"] as? [String] ?? []
            guard script["css"] == nil || script["css"] is [String], script["js"] == nil || script["js"] is [String],
                  !css.isEmpty || !js.isEmpty else { throw Invalid("Each content script needs css or js files.") }
            for file in css + js {
                guard validPath(file), files[file] != nil else { throw Invalid("Missing content file: \(file)") }
            }
            for file in css {
                let text = files[file]!
                // CSS can send page data through URLs. Look boosts have no network.
                // Reject escapes too: they can spell url/import without those bytes.
                guard !text.contains("\\"), text.range(of: #"(?i)url\s*\(|@import|image-set\s*\(|-webkit-image-set\s*\("#, options: .regularExpression) == nil else {
                    throw Invalid("Stylesheets must not load URLs, import rules, image sets or escaped names.")
                }
            }
            // Parsed as a function body before embedding outside the trusted
            // wrapper. This also rejects a brace/statement escape from it.
            guard validBody(js.compactMap { files[$0] }.joined(separator: "\n;\n")) else {
                throw Invalid("Page scripts must be valid JavaScript function bodies.")
            }
            content.append(Content(matches: matches, css: css, js: js))
        }
        guard plugin.siteActions.isEmpty || (sites != ["<all_urls>"] && content.contains(where: { !$0.js.isEmpty })) else {
            throw Invalid("Site actions need page scripts on exact named sites.")
        }
        guard sites != ["<all_urls>"] || (!content.isEmpty && plugin == .empty && files["commands.json"] == nil && !files.keys.contains(where: { $0.hasPrefix("skills/") })) else { throw Invalid("Every-site access is limited to page appearance and behavior. Native APIs and plugin tools need named sites.") }
        guard let description = files["BOOST.md"], description.hasPrefix("---\n"),
              let end = description.range(of: "\n---", range: description.index(description.startIndex, offsetBy: 4)..<description.endIndex) else {
            throw Invalid("Supply BOOST.md with frontmatter and the person's request below it.")
        }
        let intent = String(description[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty, intent.count <= 8000 else { throw Invalid("BOOST.md needs the person's request, up to 8,000 characters.") }
        let header = String(description[description.index(description.startIndex, offsetBy: 4)..<end.lowerBound])
        let checkLines = header.components(separatedBy: .newlines).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("- on ") ? String(line.dropFirst(2)) : nil
        }
        guard checkLines.count <= 30 else { throw Invalid("Use at most 30 checks.") }
        let checks = try checkLines.map(BoostCheck.parse)
        guard validBody(files["checks.js"] ?? "") else { throw Invalid("Checks must be valid JavaScript function bodies.") }
        guard !checks.contains(where: { $0.kind == .script }) || files["checks.js"] != nil else { throw Invalid("Script checks need checks.js and boost.check(name, function).") }
        return BoostPackage(id: id, name: name, sites: sites, intent: intent, checks: checks, files: files,
                            content: content,
                            rung: sites == ["<all_urls>"] || files["commands.json"] != nil || plugin.app != nil || plugin.service != nil || plugin.permissions.contains(where: { $0 != "yab:ask" }) ? .app
                                : !plugin.tools.isEmpty || !plugin.permissions.isEmpty || files.keys.contains(where: { $0.hasPrefix("skills/") }) ? .tool : content.allSatisfy(\.js.isEmpty) && files["checks.js"] == nil && plugin.hosts.isEmpty && plugin.siteActions.isEmpty ? .look : .page,
                            plugin: plugin)
    }
    private static func validBody(_ source: String) -> Bool {
        guard !source.isEmpty else { return true }
        guard let context = JSContext(), let constructor = context.objectForKeyedSubscript("Function") else { return false }
        // call(withArguments:) passes source as data; the created function is
        // never called, and no package statement executes during validation.
        let function = constructor.call(withArguments: ["boost", source])
        return context.exception == nil && function?.isObject == true
    }

    /// Only the native Keep control may broaden a named-site trial.
    func applyingEverywhere() throws -> BoostPackage {
        guard canApplyEverywhere, var manifest = try JSONSerialization.jsonObject(with: Data(files["manifest.json"]!.utf8)) as? [String: Any],
              var scripts = manifest["content_scripts"] as? [[String: Any]] else { throw Invalid("Only page styles and scripts can apply to every site.") }
        for index in scripts.indices { scripts[index]["matches"] = ["<all_urls>"] }
        manifest["content_scripts"] = scripts
        var changed = files; changed["manifest.json"] = BoostScript.json(manifest)
        return try Self.read(id: id, files: changed, sites: ["<all_urls>"])
    }

}

struct BoostCheck: Equatable, Codable {
    enum Kind: String, Codable { case none, some, rows, text, script }
    let line: String
    let path: String
    let kind: Kind
    let selector: String
    var count: Int? = nil
    var words: String? = nil

    static func parse(_ line: String) throws -> BoostCheck {
        guard line.hasPrefix("on /"), let colon = line.range(of: ": ") else {
            throw BoostPackage.Invalid("Invalid check: \(line)")
        }
        let path = String(line[line.index(line.startIndex, offsetBy: 3)..<colon.lowerBound])
        let expression = String(line[colon.upperBound...])
        for (prefix, kind) in [("none of ", Kind.none), ("some of ", .some)] where expression.hasPrefix(prefix) {
            let selector = String(expression.dropFirst(prefix.count))
            guard !selector.isEmpty else { throw BoostPackage.Invalid("A check needs a selector.") }
            return BoostCheck(line: line, path: path, kind: kind, selector: selector)
        }
        if expression.hasPrefix("script ") {
            let name = String(expression.dropFirst(7))
            guard name.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,63}$"#, options: .regularExpression) != nil else { throw BoostPackage.Invalid("A script check needs a function name.") }
            return BoostCheck(line: line, path: path, kind: .script, selector: name)
        }
        if let split = expression.range(of: " per row in "), let n = Int(expression[..<split.lowerBound]), n > 0, n <= 100 {
            let selector = String(expression[split.upperBound...])
            guard !selector.isEmpty else { throw BoostPackage.Invalid("A row check needs a selector.") }
            return BoostCheck(line: line, path: path, kind: .rows, selector: selector, count: n)
        }
        if expression.hasPrefix("text "), let split = expression.range(of: " in ", options: .backwards) {
            let words = String(expression[expression.index(expression.startIndex, offsetBy: 5)..<split.lowerBound])
            let selector = String(expression[split.upperBound...])
            guard !words.isEmpty, !selector.isEmpty else { throw BoostPackage.Invalid("A text check needs words and a selector.") }
            return BoostCheck(line: line, path: path, kind: .text, selector: selector, words: words)
        }
        throw BoostPackage.Invalid("Unsupported check: \(line). Use none of, some of, per row in, or text … in ….")
    }
}
