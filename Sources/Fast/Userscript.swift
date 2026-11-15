import CryptoKit
import Foundation

/// A `.user.js` file, read (docs/userscripts.md): its `==UserScript==`
/// header, where it runs, and what it may do in the Keep card's one
/// sentence, the way BoostPackage.permission says it for boosts. Reading
/// runs nothing and fetches nothing; `@require` and `@resource` files are
/// fetched once by Userscripts and pinned by their SHA-256.
struct Userscript: Equatable {
    /// One `@require` or `@resource` file, as fetched at Keep.
    struct File: Equatable, Codable {
        /// The resource's name; empty for a `@require`.
        var name: String
        var url: String
        var sha256: String
        var text: String
        var mime: String = ""
    }

    let source: String
    /// Every `@key` of the header, lowercased, with its values in order.
    /// Localized keys keep their suffix (`name:ru`).
    let header: [String: [String]]
    var requires: [File] = []
    var resources: [File] = []

    // MARK: reading

    struct Invalid: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Whether the text is a userscript: a `==UserScript==` block near its
    /// top, as a `.user.js` is, wherever it was served from.
    static func looks(_ text: String) -> Bool {
        let head = text.prefix(4000)
        return head.range(of: #"(?m)^\s*//\s*==UserScript==\s*$"#, options: .regularExpression) != nil
    }

    static func read(_ source: String) throws -> Userscript {
        guard source.utf8.count <= 5_000_000 else { throw Invalid("This userscript is larger than 5 MB.") }
        guard let start = source.range(of: #"(?m)^\s*//\s*==UserScript==\s*$"#, options: .regularExpression),
              let end = source.range(of: #"(?m)^\s*//\s*==/UserScript==\s*$"#, options: .regularExpression, range: start.upperBound..<source.endIndex) else {
            throw Invalid("This file has no ==UserScript== header.")
        }
        var header: [String: [String]] = [:]
        for line in source[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else { continue }
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("@") else { continue }
            let body = rest.dropFirst()
            let key = body.prefix { !$0.isWhitespace }.lowercased()
            let value = body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            header[key, default: []].append(value)
        }
        let script = Userscript(source: source, header: header)
        guard !script.name.isEmpty else { throw Invalid("The header has no @name.") }
        guard script.name.count <= 200 else { throw Invalid("The @name is too long.") }
        return script
    }

    func first(_ key: String) -> String? { header[key]?.first(where: { !$0.isEmpty }) }
    func all(_ key: String) -> [String] { (header[key] ?? []).filter { !$0.isEmpty } }

    var name: String { first("name") ?? "" }
    var namespace: String { first("namespace") ?? "" }
    var version: String { first("version") ?? "" }
    var summary: String { first("description") ?? "" }
    var author: String { first("author") ?? "" }
    var matches: [String] { all("match") }
    var includes: [String] { all("include") }
    var excludes: [String] { all("exclude") + all("exclude-match") }
    var grants: [String] { all("grant") }
    var connects: [String] { all("connect").map { $0.lowercased() } }
    var requireURLs: [String] { all("require") }
    var resourceSpecs: [(name: String, url: String)] {
        all("resource").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1].trimmingCharacters(in: .whitespaces))
        }
    }
    var runAt: String {
        switch first("run-at")?.lowercased() {
        case "document-start": return "document-start"
        case "document-end", "document-body": return "document-end"
        default: return "document-idle"
        }
    }
    var noframes: Bool { header["noframes"] != nil }
    var icon: String? { first("icon") ?? first("iconurl") ?? first("defaulticon") }
    var updateURL: URL? { first("updateurl").flatMap(URL.init(string:)).flatMap(Self.web) }
    var downloadURL: URL? { first("downloadurl").flatMap(URL.init(string:)).flatMap(Self.web) }
    private static func web(_ url: URL) -> URL? { ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil }

    /// The code itself with whatever it uses, header and all.
    var code: String { source }

    /// A short lowercase id for its folder, from its namespace and name.
    var id: String {
        let slug = BoostPackage.slug(name)
        let digest = SHA256.hash(data: Data((namespace + "\n" + name).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return String((slug.isEmpty ? "script" : slug).prefix(48)) + "-" + digest
    }

    /// The SHA-256 of a file's text, as pinned.
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: what it uses

    /// The GM calls it makes, granted or not: a script written for
    /// `@grant none` that calls them anyway gets them too.
    func uses(_ api: String) -> Bool {
        grants.contains { $0 == api || $0 == api.replacingOccurrences(of: "GM_", with: "GM.") }
            || source.range(of: "\\b" + NSRegularExpression.escapedPattern(for: api) + "\\b", options: .regularExpression) != nil
    }
    var storesValues: Bool {
        ["GM_setValue", "GM.setValue", "GM_setValues", "GM.setValues"].contains(where: uses)
    }
    /// It wants the page's own globals: run in the page's world.
    var inPage: Bool {
        if let into = first("inject-into")?.lowercased() { return into == "page" }
        return grants.contains("none") || grants.isEmpty && !usesAnyGM || uses("unsafeWindow")
    }
    private var usesAnyGM: Bool { source.range(of: #"\bGM[_.][A-Za-z]"#, options: .regularExpression) != nil }
    /// What only Tampermonkey answers: such a script stays there.
    var onlyTampermonkey: [String] { ["GM_cookie", "GM.cookie", "GM_webRequest", "GM_audio", "GM.audio"].filter(uses) }

    // MARK: where it runs

    /// Where one `@match` or `@include` can run.
    enum Scope: Hashable {
        case everywhere
        /// A host and every host under it.
        case site(String)
        /// A host with wildcards in it (`google.*`), said as it is written.
        case written(String)
    }

    /// The regular expression (source, flags) for a `@match`, Chrome's
    /// match pattern as Tampermonkey reads it, the port allowed.
    static func regex(match pattern: String) -> (String, String)? {
        if pattern == "<all_urls>" || pattern == "*" { return (#"^(?:https?|file):\/\/.*$"#, "") }
        guard let scheme = pattern.range(of: "://") else { return regex(include: pattern) }
        let schemePart = String(pattern[..<scheme.lowerBound])
        let rest = pattern[scheme.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = String(rest[..<slash])
        let path = rest[slash...].isEmpty ? "/*" : String(rest[slash...])
        let schemes = schemePart == "*" ? "https?" : schemePart.lowercased() == "http*" ? "https?" : NSRegularExpression.escapedPattern(for: schemePart.lowercased())
        let hostPattern: String
        if host == "*" { hostPattern = "[^/]*" }
        else if host.hasPrefix("*.") { hostPattern = "(?:[^/]*\\.)?" + Self.hostGlob(String(host.dropFirst(2))) }
        else { hostPattern = Self.hostGlob(host) }
        return ("^" + schemes + ":\\/\\/" + hostPattern + "(?::\\d+)?" + glob(path) + "$", "i")
    }

    private static func hostGlob(_ host: String) -> String {
        host.lowercased().split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[^/]*")
            .replacingOccurrences(of: "\\.tld", with: #"\.[a-z]{2,}(?:\.[a-z]{2,})?"#)
    }

    private static func glob(_ text: String) -> String {
        text.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
    }

    /// The regular expression for an `@include` or `@exclude`: a glob over
    /// the whole address, or a `/regex/` as written.
    static func regex(include pattern: String) -> (String, String)? {
        if pattern == "*" || pattern == "<all_urls>" { return (".*", "") }
        if pattern.count > 2, pattern.hasPrefix("/"), let close = pattern.lastIndex(of: "/"), close > pattern.startIndex {
            let body = String(pattern[pattern.index(after: pattern.startIndex)..<close])
            let flags = String(pattern[pattern.index(after: close)...]).filter { "imsu".contains($0) }
            return body.isEmpty ? nil : (body, flags)
        }
        return ("^" + glob(pattern).replacingOccurrences(of: "\\.tld", with: #"\.[a-z]{2,}(?:\.[a-z]{2,})?"#) + "$", "i")
    }

    /// What the page wrapper tests `location.href` against.
    var runs: (include: [(String, String)], exclude: [(String, String)]) {
        var include = matches.compactMap(Self.regex(match:)) + includes.compactMap(Self.regex(include:))
        if matches.isEmpty && includes.isEmpty { include = [(".*", "")] }
        let exclude = all("exclude").compactMap(Self.regex(include:)) + all("exclude-match").compactMap(Self.regex(match:))
        return (include, exclude)
    }

    func matches(_ url: URL) -> Bool {
        let href = url.absoluteString
        func test(_ rule: (String, String)) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: rule.0, options: rule.1.contains("i") ? [.caseInsensitive] : []) else { return false }
            return regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)) != nil
        }
        let rules = runs
        return rules.include.contains(where: test) && !rules.exclude.contains(where: test)
    }

    /// Where a pattern can run, for the card and for arming a tab.
    static func scope(_ pattern: String) -> Scope? {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        if ["*", "<all_urls>", "*://*/*", "*://*", "http*://*/*", "http*://*", "https://*/*", "http://*/*", "*://*/"].contains(pattern) { return .everywhere }
        if pattern.hasPrefix("/"), pattern.count > 2 {
            // A regular expression: the first name in it that reads as a host.
            let unescaped = pattern.replacingOccurrences(of: "\\.", with: ".")
            guard let found = unescaped.range(of: #"[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}"#, options: [.regularExpression, .caseInsensitive]) else { return .everywhere }
            return .site(Self.bare(String(unescaped[found]).lowercased()))
        }
        var rest = Substring(pattern)
        if let scheme = pattern.range(of: "://") { rest = pattern[scheme.upperBound...] }
        let host = String(rest.prefix { $0 != "/" }).lowercased().split(separator: ":").first.map(String.init) ?? ""
        if host.isEmpty || host == "*" || host.allSatisfy({ $0 == "*" || $0 == "." }) { return .everywhere }
        var bare = host
        while bare.hasPrefix("*.") || bare.hasPrefix("*") || bare.hasPrefix(".") { bare.removeFirst() }
        if bare.isEmpty { return .everywhere }
        if bare.contains("*") || bare.hasSuffix(".tld") { return .written(bare) }
        return .site(Self.bare(bare))
    }

    private static func bare(_ host: String) -> String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    var scopes: [Scope] {
        let patterns = matches + includes
        if patterns.isEmpty { return [.everywhere] }
        var seen: [Scope] = []
        for scope in patterns.compactMap(Self.scope) where !seen.contains(scope) { seen.append(scope) }
        if seen.contains(.everywhere) { return [.everywhere] }
        // A site under another listed one is that one.
        let sites = seen.compactMap { if case .site(let host) = $0 { return host } else { return nil } }
        return seen.filter { scope in
            guard case .site(let host) = scope else { return true }
            return !sites.contains { host != $0 && host.hasSuffix("." + $0) }
        }
    }
    var everywhere: Bool { scopes == [.everywhere] }

    /// The named sites, for the card and Site Controls.
    var sites: [String] {
        scopes.compactMap { scope in
            switch scope {
            case .everywhere: return nil
            case .site(let host), .written(let host): return host
            }
        }
    }

    /// Whether it could run anywhere on a host: arming a tab sends only
    /// the scripts that can.
    func mayRun(on host: String?) -> Bool {
        guard let host = host?.lowercased() else { return everywhere }
        let bare = Self.bare(host)
        return scopes.contains { scope in
            switch scope {
            case .everywhere: return true
            case .site(let site): return bare == site || host == site || host.hasSuffix("." + site)
            case .written(let written):
                let stem = written.split(separator: "*").first.map(String.init) ?? written
                return host.contains(stem.replacingOccurrences(of: ".tld", with: ""))
            }
        }
    }

    /// Whole hosts left out under a named site: "not music.youtube.com".
    var excludedSites: [String] {
        var out: [String] = []
        for pattern in all("exclude") + all("exclude-match") {
            guard case .site(let host)? = Self.scope(pattern) else { continue }
            let path = pattern.range(of: "://").map { pattern[$0.upperBound...].drop { $0 != "/" } } ?? ""
            guard path == "/*" || path.isEmpty, sites.contains(where: { host != $0 && host.hasSuffix("." + $0) }), !out.contains(host) else { continue }
            out.append(host)
        }
        return out
    }

    // MARK: where it talks to

    /// Hosts it declares with `@connect`, `self` and `*` left out.
    var declaredHosts: [String] {
        connects.filter { $0 != "*" && $0 != "self" }
            .map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var anyHost: Bool { connects.contains("*") }

    /// Hosts the code calls without saying so in `@connect`, read from the
    /// code as boosts' code is read: an address in quotes on a line that
    /// fetches, requests or names an API, a server or a base.
    static func codeHosts(_ code: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"["'`](?:https?:)?//([a-z0-9-]+(?:\.[a-z0-9-]+)+)"#, options: [.caseInsensitive]) else { return [] }
        let words = try? NSRegularExpression(pattern: #"(?i)fetch|xmlhttprequest|\.open\s*\(|websocket|eventsource|sendbeacon|\bapi|url\b|_url|endpoint|server|base|request|ajax|\$\.get|\$\.post|connect"#)
        var hosts: [String] = []
        let text = code as NSString
        for found in regex.matches(in: code, range: NSRange(location: 0, length: text.length)) {
            let host = text.substring(with: found.range(at: 1)).lowercased()
            guard host.contains("."), !host.hasSuffix(".js"), !host.hasSuffix(".css"), !hosts.contains(host) else { continue }
            // The line it is on, up to the address: the words around a call.
            let lineStart = text.rangeOfCharacter(from: .newlines, options: .backwards, range: NSRange(location: 0, length: found.range.location)).location
            let from = lineStart == NSNotFound ? 0 : lineStart + 1
            let span = NSRange(location: from, length: min(found.range.location - from + found.range.length, 400))
            let line = text.substring(with: span)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") || line.trimmingCharacters(in: .whitespaces).hasPrefix("*") { continue }
            guard words?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { continue }
            hosts.append(host)
        }
        return hosts
    }

    /// Everything after the header: where hosts in the code are looked for.
    var body: String {
        guard let end = source.range(of: #"(?m)^\s*//\s*==/UserScript==\s*$"#, options: .regularExpression) else { return source }
        return String(source[end.upperBound...])
    }

    /// Hosts it may talk to through GM_xmlhttpRequest, other than its own
    /// sites: declared, then found in the code.
    var hosts: [String] {
        var out: [String] = []
        for host in declaredHosts + Self.codeHosts(body) where !out.contains(host) && !Self.covered(host, by: sites) && !Self.covered(host, by: out) {
            out.append(host)
        }
        return out
    }

    /// Hosts whose requests carry the person's sign-in: those declared,
    /// never those only read from the code.
    var signedHosts: [String] { declaredHosts.filter { !Self.covered($0, by: sites) } }

    /// The site a host belongs to, roughly as a registrable domain: the
    /// last two labels, three for a country's own second level (co.uk);
    /// an address like 127.0.0.1 whole.
    static func siteOf(_ host: String) -> String {
        let host = host.lowercased()
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let keep = labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    static func covered(_ host: String, by sites: [String]) -> Bool {
        let host = bare(host)
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: the card's words

    /// "jquery 3.7.1 from cdnjs".
    static func describe(require url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return url }
        let from: String = switch host {
        case "cdnjs.cloudflare.com": "cdnjs"
        case "cdn.jsdelivr.net", "fastly.jsdelivr.net": "jsDelivr"
        case "unpkg.com": "unpkg"
        case "code.jquery.com": "jquery.com"
        default: host.hasPrefix("update.") || host.hasPrefix("www.") ? String(host.drop { $0 != "." }.dropFirst()) : host
        }
        let path = parts.path.split(separator: "/").map(String.init)
        var file = path.last ?? host
        for ending in [".min.js", ".js", ".user.js"] where file.lowercased().hasSuffix(ending) { file = String(file.dropLast(ending.count)); break }
        file = file.removingPercentEncoding ?? file
        let version = path.dropLast().reversed().first { $0.range(of: #"^v?\d+(?:\.\d+)+"#, options: .regularExpression) != nil }
        let npm = path.first { $0.contains("@") && $0.range(of: #"@v?\d"#, options: .regularExpression) != nil }
        if let npm, let at = npm.lastIndex(of: "@") {
            return String(npm[..<at]) + " " + String(npm[npm.index(after: at)...]) + " from " + from
        }
        if let version, !file.contains(version) { return file + " " + version + " from " + from }
        return file + " from " + from
    }

    /// The Keep card's sentence: where it runs, how, whom it talks to,
    /// whether it keeps settings and what it brings along.
    var permission: String {
        var words: [String] = []
        if everywhere {
            words.append("Read and change every site you visit.")
        } else {
            let named = sites
            let shown = named.count > 3 ? named.prefix(2).joined(separator: ", ") + " and \(named.count - 2) other sites" : BoostPackage.list(named)
            let not = excludedSites
            words.append("Run code on " + shown + (not.isEmpty ? "" : ", not " + BoostPackage.list(not)) + ".")
        }
        if inPage { words.append("Runs inside the page, where it can see what you type.") }
        if anyHost {
            words.append("Can talk to any site.")
        } else {
            let signed = signedHosts, plain = hosts.filter { !signed.contains($0) }
            if !signed.isEmpty, !plain.isEmpty {
                words.append("Talks to " + BoostPackage.list(signed) + " with your sign-in, and to " + BoostPackage.list(plain) + ".")
            } else if !signed.isEmpty {
                words.append("Talks to " + BoostPackage.list(signed) + " with your sign-in.")
            } else if !plain.isEmpty {
                words.append("Talks to " + BoostPackage.list(plain) + ".")
            }
        }
        if storesValues { words.append("Keeps its own settings.") }
        let requires = requireURLs.map(Self.describe(require:))
        if !requires.isEmpty { words.append("Includes " + BoostPackage.list(requires) + ".") }
        return words.joined(separator: " ")
    }

    // MARK: updates

    /// What this version may do that the kept one may not, each in words:
    /// a new site, a new host, the page's world, a new or changed
    /// `@require`. Empty: the update installs quietly.
    func more(than kept: Userscript) -> [String] {
        var out: [String] = []
        if everywhere && !kept.everywhere { out.append("Reads and changes every site you visit") }
        else if !everywhere {
            for site in sites where !kept.everywhere && !Self.covered(site, by: kept.sites) { out.append("Runs on " + site) }
        }
        if anyHost && !kept.anyHost { out.append("Can talk to any site") }
        else if !kept.anyHost {
            for host in hosts where !kept.hosts.contains(host) && !Self.covered(host, by: kept.sites) {
                out.append("Talks to " + host + (signedHosts.contains(host) ? " with your sign-in" : ""))
            }
            for host in signedHosts where kept.hosts.contains(host) && !kept.signedHosts.contains(host) { out.append("Talks to " + host + " with your sign-in") }
        }
        if inPage && !kept.inPage { out.append("Runs inside the page, where it can see what you type") }
        let keptFiles = Dictionary(kept.requires.map { ($0.url, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        for url in requireURLs {
            if keptFiles[url] == nil { out.append("Includes " + Self.describe(require: url)) }
            else if let new = requires.first(where: { $0.url == url }), new.sha256 != keptFiles[url] { out.append("Changes " + Self.describe(require: url)) }
        }
        return out
    }

    /// "3.10.0" is newer than "3.9.2"; words after numbers count as lower.
    static func newer(_ a: String, than b: String) -> Bool {
        let parts = { (text: String) -> [Int] in
            text.split(whereSeparator: { !$0.isNumber }).map { Int($0.prefix(9)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0, r = index < y.count ? y[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Where it came from, for the card's source line: "greasyfork.org".
    static func from(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        if host.hasSuffix("greasyfork.org") { return "greasyfork.org" }
        if host.hasSuffix("openuserjs.org") { return "openuserjs.org" }
        if host == "raw.githubusercontent.com" || host == "gist.githubusercontent.com" || host.hasSuffix("github.com") { return "github.com" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The Greasy Fork id in an address: …/scripts/436115…
    static func greasyForkID(_ url: URL?) -> Int? {
        guard let url, url.host()?.lowercased().hasSuffix("greasyfork.org") == true,
              let found = url.path.range(of: #"/scripts/(\d+)"#, options: .regularExpression) else { return nil }
        return Int(url.path[found].dropFirst(9))
    }
}
