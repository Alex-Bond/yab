import Foundation
import CryptoKit
import Darwin
import JavaScriptCore
import WebKit

/// An ad blocker's declarativeNetRequest rules on every page from its first
/// request, as in Chrome.
///
/// WebKit compiles an extension's rules into one content rule list file in
/// its storage and hands that list to a page only after the page is made,
/// by looking the file up on WebKit's shared rule list store. That store
/// does one thing at a time, and compiling AdBlock's 61,000 rules (100,000
/// once WebKit has translated them, a 36 MB list) holds it for 13 to 17 s,
/// again for every change: AdBlock disables and enables its rule sets and
/// adds its dynamic rules in batches for minutes after it is added, and
/// after each filter update. A tab opened meanwhile waited behind the
/// compiles and loaded its page, ads and all, with no rules; an extension
/// compiling held every other's rules back too (uBlock Origin Lite's page
/// "lapsed" while AdBlock compiled).
///
/// So each extension's last compiled list is kept here, looked up on a
/// store of Yab's own that nothing compiles on, and put on a page's
/// controller as the page is made, before it loads. WebKit's own lookup
/// replaces it with the same list, or a newer one, under the same
/// identifier. Lists follow WebKit's file: a new compile is picked up as it
/// lands. A transient removal is kept in memory but not given to new pages;
/// unloading the extension drops it.
///
/// WebKit also fails `updateEnabledRulesets` when the last rule set is
/// disabled before it has compiled anything: with no rules left it deletes
/// the compiled file, and a file not there yet is an error ("Failed to apply
/// rules"), and it turns the rule sets back on. AdBlock disables all of its
/// rule sets as it starts, then enables the ones it wants; so the file is
/// always there, empty when there is nothing compiled, which WebKit reads as
/// no list.
@available(macOS 15.4, *)
@MainActor
enum ExtensionRules {
    nonisolated static let fileName = "DeclarativeNetRequestContentRuleList.data"

    /// What a compiled file was when its list was read.
    struct Stamp: Equatable {
        let file: UInt64
        let modified: Date
        let size: Int
    }

    private struct Held {
        let list: WKContentRuleList
        let stamp: Stamp
        let base: URL
    }

    private final class Registration {
        weak var owner: WKWebExtensionController?
        let token = UUID()
        init(owner: WKWebExtensionController?) { self.owner = owner }
    }

    private static var held: [String: Held] = [:]
    private static var registrations: [String: Registration] = [:]
    private static var reading: [String: UUID] = [:]
    private static var lookupErrors: [String: String] = [:]
    private static var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private static var folders: [String: URL] = [:]
    private static var bases: [String: URL] = [:]
    /// The bridge's own store: lookups here never wait behind a compile.
    private static var links: URL { Store.folder.appendingPathComponent("ExtensionRules", isDirectory: true) }
    private static var store: WKContentRuleListStore? = {
        try? FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: links)
    }()

    /// Told each time an extension's newly compiled list is held, and when
    /// its compiled file couldn't be read: the ad blocker's handover and its
    /// countdown follow it (Blockers).
    static var landed: ((String) -> Void)?
    static var lookupFailed: ((String, String) -> Void)?

    /// Whether an extension's compiled list is held, ready for new pages.
    static func holds(_ id: String) -> Bool { held[id] != nil }

    /// An extension's held list taken off a page, or put back on it.
    static func drop(_ controller: WKUserContentController, _ id: String, off: Bool) {
        guard let kept = held[id] else { return }
        if off { controller.remove(kept.list) } else { add(kept.list, base: kept.base, to: controller) }
    }

    /// Held, and its compiled file there for new pages to be given.
    static func ready(_ id: String) -> Bool {
        guard held[id] != nil, let folder = folders[id] else { return false }
        return stamp(folder.appendingPathComponent(fileName)) != nil
    }

    /// A test run may go without, to measure WebKit alone against it.
    private static var off: Bool {
        Store.testing && Store.settings.object(forKey: "extensions.rulesBridge") as? Bool == false
    }

    /// Whether an extension's rules are WebKit's to compile.
    static func uses(_ webExtension: WKWebExtension) -> Bool {
        // An optional permission can be granted after the bridge is prepared.
        let permissions = webExtension.requestedPermissions.union(webExtension.optionalPermissions)
        return permissions.contains(.declarativeNetRequest)
            || permissions.contains(.declarativeNetRequestWithHostAccess)
    }

    /// The stamp of a compiled file there, nil for none or an empty one.
    nonisolated static func stamp(_ file: URL) -> Stamp? {
        guard let info = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (info[.size] as? NSNumber)?.intValue, size > 0,
              let number = (info[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = info[.modificationDate] as? Date
        else { return nil }
        return Stamp(file: number, modified: modified, size: size)
    }

    /// An empty file where WebKit keeps the compiled list, when none is
    /// there, so disabling every rule set has a file to remove. Never over
    /// one that is.
    nonisolated static func placeholder(in folder: URL) {
        let file = folder.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let handle = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if handle >= 0 { close(handle) }
    }

    /// Keep the exact compiled generation readable while WebKit atomically
    /// replaces its source file during a rule update.
    nonisolated static func snapshot(_ file: URL, at copy: URL) throws {
        try? FileManager.default.removeItem(at: copy)
        if clonefile(file.path, copy.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: file, to: copy)
    }

    /// Before WebKit loads it: its storage readied, and its compiled list
    /// followed from then on.
    static func prepare(_ context: WKWebExtensionContext, storage folder: URL?, owner: WKWebExtensionController? = nil) {
        let id = context.uniqueIdentifier
        guard !off, uses(context.webExtension), let folder else { return }
        let owner = owner ?? context.webExtensionController
        // Another controller's live registration is not this load's to replace.
        if let current = registrations[id]?.owner, current !== owner { return }
        if registrations[id] != nil { forget(id) }
        registrations[id] = Registration(owner: owner)
        placeholder(in: folder)
        folders[id] = folder
        bases[id] = context.baseURL
        follow(id)
    }

    /// Unloaded or removed: its list is no longer given to new pages.
    static func forget(_ id: String, owner: WKWebExtensionController? = nil) {
        if let owner, registrations[id]?.owner !== owner { return }
        watchers.removeValue(forKey: id)?.cancel()
        registrations[id] = nil
        reading[id] = nil
        held[id] = nil
        lookupErrors[id] = nil
        folders[id] = nil
        bases[id] = nil
        try? FileManager.default.removeItem(at: links.appendingPathComponent("ContentRuleList-" + id))
    }

    /// A cached lookup can finish before the context is registered at launch.
    static func activated(_ id: String) {
        if let latest = held[id] { refreshOpenPages(id, with: latest) }
    }

    /// A page's controller as its view is made: every loaded extension's
    /// last compiled list, where WebKit will put it, before the page loads.
    /// A private page only gets those allowed in private tabs.
    static func give(_ controller: WKUserContentController, contexts: [String: WKWebExtensionContext], persistent: Bool) {
        for (id, context) in contexts {
            guard let folder = folders[id] else { continue }
            if !persistent, !context.hasAccessToPrivateData { continue }
            guard let now = stamp(folder.appendingPathComponent(fileName)) else {
                // A missing file can be a brief step while WebKit recompiles.
                // Do not apply the old list now, but keep it for the new file.
                continue
            }
            if let kept = held[id] {
                add(kept.list, base: kept.base, to: controller)
                if kept.stamp != now { read(id) }
            } else {
                read(id)
            }
        }
    }

    /// The list WebKit compiled last for an extension, for the bench.
    static func report(_ id: String) -> [String: Any] {
        guard let folder = folders[id] else { return [:] }
        let now = stamp(folder.appendingPathComponent(fileName))
        return ["held": held[id] != nil, "current": held[id].map { $0.stamp == now } ?? false,
                "reading": reading[id] != nil, "lookup_error": lookupErrors[id] ?? "",
                "compiled_mb": now.map { Double($0.size) / 1_000_000 } ?? 0]
    }

    private static func add(_ list: WKContentRuleList, base: URL, to controller: WKUserContentController) {
        // With the extension's address, as WebKit adds it: a redirect to one
        // of its own files resolves against it.
        let spi = NSSelectorFromString("_addContentRuleList:extensionBaseURL:")
        if controller.responds(to: spi) {
            typealias Add = @convention(c) (AnyObject, Selector, WKContentRuleList, NSURL) -> Void
            unsafeBitCast(controller.method(for: spi), to: Add.self)(controller, spi, list, base as NSURL)
        } else {
            controller.add(list)
        }
    }

    private static func refreshOpenPages(_ id: String, with latest: Held) {
        let extensions = Extensions.shared
        guard let context = extensions.contexts[id] else { return }
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.tabs + browser.parkedTabs + browser.outside + [browser.peeking].compactMap({ $0 }) {
                guard let controller = tab.extensionRulesController,
                      tab.store.isPersistent || context.hasAccessToPrivateData,
                      // A site turned off keeps the list off (Shield.fit).
                      !Shield.shared.dropped(controller)
                else { continue }
                add(latest.list, base: latest.base, to: controller)
            }
        }
    }

    private static func follow(_ id: String) {
        guard watchers[id] == nil, let folder = folders[id] else { return }
        let handle = open(folder.path, O_EVTONLY)
        if handle >= 0 {
            // WebKit writes a compiled list to a new file in that folder and
            // renames it over the old one: the folder changes.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { changed(id) }
            }
            source.setCancelHandler { close(handle) }
            source.resume()
            watchers[id] = source
        }
        changed(id)
    }

    private static func changed(_ id: String) {
        guard let folder = folders[id] else { return }
        let file = folder.appendingPathComponent(fileName)
        guard let now = stamp(file) else {
            // Removed with the last rule set: empty again, so the next
            // "disable" has a file to remove too.
            if !FileManager.default.fileExists(atPath: file.path) { placeholder(in: folder) }
            return
        }
        if held[id]?.stamp != now { read(id) }
    }

    private static func read(_ id: String) {
        guard reading[id] == nil, let token = registrations[id]?.token,
              let folder = folders[id], let store, let base = bases[id] else { return }
        let file = folder.appendingPathComponent(fileName)
        guard let before = stamp(file) else { return }
        // A private APFS clone, named as the store names its lists. A symlink
        // to the live file could change underneath an in-flight lookup.
        let link = links.appendingPathComponent("ContentRuleList-" + id)
        do { try snapshot(file, at: link) }
        catch {
            lookupErrors[id] = "snapshot: \(error)"
            return
        }
        reading[id] = token
        store.lookUpContentRuleList(forIdentifier: id) { list, error in
            MainActor.assumeIsolated {
                // A failed load or a later registration cannot inherit this lookup.
                guard registrations[id]?.token == token, reading[id] == token else { return }
                reading[id] = nil
                guard folders[id] != nil else { return }
                lookupErrors[id] = error.map { String(describing: $0) } ?? (list == nil ? "no compiled list" : nil)
                let after = stamp(file)
                if let list {
                    let latest = Held(list: list, stamp: before, base: base)
                    held[id] = latest
                    if after != nil { refreshOpenPages(id, with: latest) }
                    landed?(id)
                } else if let error = lookupErrors[id], after == before {
                    lookupFailed?(id, error)
                }
                // Compiled again while it was read: read the new one.
                if after != nil, after != before { read(id) }
            }
        }
    }
}

/// An extension's rule sets put the way WebKit's translator takes them, at
/// install, before WebKit reads them (ExtensionShims.prepare). Dynamic and
/// session rules get the same from the shim as the extension adds them.
enum ExtensionRuleMends {
    /// The resource types WebKit's translator has a name for.
    static let knownTypes: Set<String> = ["main_frame", "sub_frame", "stylesheet", "script", "image", "font",
                                          "xmlhttprequest", "ping", "media", "websocket", "other"]
    static let redirectFolder = "yab-redirects"

    /// One rule, mended, or nil when it needs nothing.
    ///
    /// Resource types: a rule naming one WebKit doesn't know (csp_report,
    /// object, webbundle, webtransport) beside ones it does lost more than
    /// that one. WebKit's translator renames the known types to its own
    /// words as it takes the unknown out, then looks the renamed list up
    /// again by Chrome's words, and sub_frame, xmlhttprequest, stylesheet
    /// and main_frame are no longer found: EasyList's "-ad-manager/" rule
    /// stopped blocking ads in frames and fetches, 143 of AdBlock's default
    /// rules among them. The unknown ones are left out here, so WebKit
    /// renames nothing. A rule naming only unknown types is left for WebKit
    /// to refuse, as it does.
    ///
    /// Redirects to a data: address: WebKit takes only http and https
    /// redirect addresses and drops the rule (AdBlock's blank pictures, 54
    /// rules). `file` writes the data into the extension's folder, and the
    /// rule redirects to that file by path, as WebKit takes it.
    static func mend(_ rule: [String: Any], file: (String) -> String?) -> [String: Any]? {
        var rule = rule
        var changed = false
        if var condition = rule["condition"] as? [String: Any], let types = condition["resourceTypes"] as? [String] {
            let known = types.filter { knownTypes.contains($0) }
            if !known.isEmpty, known.count != types.count {
                condition["resourceTypes"] = known
                rule["condition"] = condition
                changed = true
            }
        }
        // requestMethods: WebKit compiles none ("The request-method string
        // must be …", for "get" itself) and the whole change fails with it.
        // A GET-only one is left out (a navigation is a GET); others widen
        // if left out, so they stay for WebKit (extension-shims.js does the
        // same to dynamic and session rules).
        if var condition = rule["condition"] as? [String: Any], let methods = condition["requestMethods"] as? [String],
           !methods.isEmpty, methods.allSatisfy({ $0.lowercased() == "get" }) {
            condition["requestMethods"] = nil
            rule["condition"] = condition
            changed = true
        }
        if var action = rule["action"] as? [String: Any], action["type"] as? String == "redirect",
           let redirect = action["redirect"] as? [String: Any], let url = redirect["url"] as? String,
           url.lowercased().hasPrefix("data:"), let path = file(url) {
            action["redirect"] = ["extensionPath": path]
            rule["action"] = action
            changed = true
        }
        return changed ? rule : nil
    }

    /// A static rule set's regexFilters with alternatives, which WebKit
    /// leaves out, one rule per alternative, as the shim does to dynamic and
    /// session rules (extension-shims.js, "regex split"): AdGuard's
    /// \/(Zodiak_horiz|banner_SV-okna|pravo_by)\.(jpg|gif) is six rules
    /// WebKit takes. AdGuard ships 146 of these, AdBlock 11. The first part
    /// keeps the rule's id and the others take ids the set doesn't use, as
    /// static ids are any number (AdGuard's run past two billion) and no
    /// range is left for the shim's SPLIT + id * PARTS. Nil when nothing
    /// splits.
    static func split(_ rules: [Any]) -> [Any]? {
        let wanted = rules.contains { item in
            ((item as? [String: Any])?["condition"] as? [String: Any])?["regexFilter"].map { ($0 as? String)?.contains("|") == true } == true
        }
        guard wanted, let splitter = Splitter() else { return nil }
        var used = Set(rules.compactMap { ($0 as? [String: Any])?["id"] as? Int })
        var next = 1
        let fresh = { () -> Int in
            while used.contains(next) { next += 1 }
            used.insert(next)
            return next
        }
        var changed = false
        var out: [Any] = []
        for item in rules {
            guard let rule = item as? [String: Any], var condition = rule["condition"] as? [String: Any],
                  let regex = condition["regexFilter"] as? String, regex.contains("|"),
                  let parts = splitter.parts(substitutes(rule) ? regex : uncaptured(regex)), parts.count > 1
            else { out.append(item); continue }
            changed = true
            for (n, part) in parts.enumerated() {
                var made = rule
                condition["regexFilter"] = part
                made["condition"] = condition
                if n > 0 { made["id"] = fresh() }
                out.append(made)
            }
        }
        return changed ? out : nil
    }

    private static func substitutes(_ rule: [String: Any]) -> Bool {
        ((rule["action"] as? [String: Any])?["redirect"] as? [String: Any])?["regexSubstitution"] != nil
    }

    /// A regex's groups as non-capturing ones, for a rule that substitutes
    /// nothing: its parts then come out as plain words, and DuckDuckGo's
    /// (:|/|$) at an address's end is :, / and $, not (:), (/) and ($).
    static func uncaptured(_ regex: String) -> String {
        var out = ""
        var inClass = false
        var escaped = false
        let characters = Array(regex)
        for (i, c) in characters.enumerated() {
            if escaped { escaped = false; out.append(c); continue }
            if c == "\\" { escaped = true; out.append(c); continue }
            if inClass {
                if c == "]" { inClass = false }
                out.append(c)
                continue
            }
            if c == "[" { inClass = true; out.append(c); continue }
            if c == "(", i + 1 >= characters.count || characters[i + 1] != "?" { out += "(?:"; continue }
            out.append(c)
        }
        return out
    }

    /// The shim's own `alternatives` and `plain`, run here, so a static rule
    /// splits exactly as a dynamic one does.
    final class Splitter {
        private let context: JSContext
        private let alternatives: JSValue
        private let plain: JSValue

        init?() {
            let script = ExtensionShims.script
            guard let start = script.range(of: "    // regex split: from here"),
                  let end = script.range(of: "    // regex split end", range: start.upperBound..<script.endIndex),
                  let context = JSContext() else { return nil }
            context.evaluateScript(String(script[start.lowerBound..<end.lowerBound]))
            guard context.exception == nil, let alternatives = context.evaluateScript("alternatives"),
                  let plain = context.evaluateScript("plain"), alternatives.isObject, plain.isObject else { return nil }
            self.context = context
            self.alternatives = alternatives
            self.plain = plain
        }

        /// The regex's alternatives as plain regexes WebKit reads, or nil
        /// when it can't be split.
        func parts(_ regex: String) -> [String]? {
            guard let made = alternatives.call(withArguments: [regex]), !made.isNull, !made.isUndefined,
                  let parts = made.toArray() as? [String] else { return nil }
            let out = parts.compactMap { plain.call(withArguments: [$0])?.toString() }
            return out.count == parts.count ? out : nil
        }
    }

    /// A data: address's bytes and the file extension its type has.
    static func decode(_ url: String) -> (data: Data, suffix: String)? {
        guard url.lowercased().hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let head = url[url.index(url.startIndex, offsetBy: 5)..<comma].lowercased()
        let body = String(url[url.index(after: comma)...])
        let parts = head.split(separator: ";").map(String.init)
        let text = body.removingPercentEncoding ?? body
        guard let data = parts.contains("base64") ? Data(base64Encoded: text, options: .ignoreUnknownCharacters) : text.data(using: .utf8)
        else { return nil }
        let suffixes = ["image/png": "png", "image/gif": "gif", "image/jpeg": "jpg", "image/svg+xml": "svg", "image/webp": "webp",
                        "text/javascript": "js", "application/javascript": "js", "text/css": "css", "text/html": "html",
                        "text/plain": "txt", "application/json": "json", "audio/mpeg": "mp3", "video/mp4": "mp4", "audio/wav": "wav"]
        return (data, suffixes[parts.first ?? ""] ?? "txt")
    }

    /// Every rule set the manifest names, mended where it needs it; a file
    /// is written only when a rule in it changed. A redirect's file is made
    /// reachable from websites, as a redirect's target has to be.
    ///
    /// And each set's rules that match every address, counted
    /// (ExtensionRuleBudget), by id: the shim keeps an extension's enabled
    /// sets under WebKit's limit with them. A set on by default that would
    /// take the ones before it over the limit is turned off in the manifest
    /// and kept in ExtensionRuleBudget.leftOffFile, for its row to say.
    @discardableResult
    static func mendRuleSets(in folder: URL, manifest: inout [String: Any]) -> [String: Int] {
        // Dynamic and session rules redirect to data: addresses too (the
        // shim's dnr.redirect writes their files as they come), so the
        // folder is reachable from websites for any extension that may.
        let permissions = Set((manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String })
        var wrote = !permissions.isDisjoint(with: ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"])
        defer { if wrote { reachable(&manifest) } }
        guard var dnr = manifest["declarative_net_request"] as? [String: Any],
              var sets = dnr["rule_resources"] as? [[String: Any]] else { return [:] }
        let file = { (url: String) -> String? in
            guard let path = redirectFile(url, in: folder) else { return nil }
            wrote = true
            return path
        }
        var counted: [String: Int] = [:]
        for set in sets {
            // JSON's bridged objects belong to this set, not every set
            // prepared by the same background task.
            autoreleasepool {
                guard let path = set["path"] as? String else { return }
                let url = folder.appendingPathComponent(path)
                // A manifest is not a way out of its own package.
                guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
                      let data = try? Data(contentsOf: url),
                      let rules = try? JSONSerialization.jsonObject(with: data) as? [Any]
                else { return }
                // Read through every set, AdBlock's 170 MB too, once for each
                // Yab that prepares it: the count needs every rule.
                if let id = set["id"] as? String { counted[id] = ExtensionRuleBudget.universal(in: rules) }
                // Mended only when there is something to mend.
                guard ["\"csp_report\"", "\"object\"", "\"webbundle\"", "\"webtransport\"", "\"data:", "\"requestMethods\"", "\"regexFilter\""]
                    .contains(where: { data.range(of: Data($0.utf8)) != nil }) else { return }
                var changed = false
                var mended = rules.map { item -> Any in
                    guard let rule = item as? [String: Any], let new = mend(rule, file: file) else { return item }
                    changed = true
                    return new
                }
                if let split = split(mended) {
                    mended = split
                    changed = true
                }
                if changed, let out = try? JSONSerialization.data(withJSONObject: mended, options: [.withoutEscapingSlashes]) {
                    try? out.write(to: url, options: .atomic)
                }
            }
        }
        let over = ExtensionRuleBudget.over(sets.compactMap { set in
            (set["id"] as? String).map { (id: $0, enabled: set["enabled"] as? Bool == true, universal: counted[$0] ?? 0) }
        })
        if !over.isEmpty {
            for n in sets.indices where over.contains(sets[n]["id"] as? String ?? "") { sets[n]["enabled"] = false }
            dnr["rule_resources"] = sets
            manifest["declarative_net_request"] = dnr
        }
        // Prepared again, a set turned off by an earlier Yab reads as off
        // by default: it stays said.
        let known = Set(counted.keys)
        ExtensionRuleBudget.keep(Array(Set(ExtensionRuleBudget.leftOff(in: folder) + over)).filter(known.contains).sorted(), in: folder)
        if let data = try? JSONSerialization.data(withJSONObject: counted, options: [.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent(ExtensionRuleBudget.countsFile), options: .atomic)
        }
        return counted
    }

    /// A data: address's bytes as a file in the extension's redirect folder,
    /// named for the address, and its path for a rule's extensionPath; nil
    /// when the address can't be read.
    nonisolated static func redirectFile(_ url: String, in folder: URL) -> String? {
        guard let (data, suffix) = decode(url) else { return nil }
        let name = SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + "." + suffix
        let target = folder.appendingPathComponent(redirectFolder, isDirectory: true)
        let file = target.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return "/\(redirectFolder)/\(name)" }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return "/\(redirectFolder)/\(name)"
    }

    /// The redirect folder reachable from websites, as a redirect's target
    /// has to be.
    private static func reachable(_ manifest: inout [String: Any]) {
        let pattern = "\(redirectFolder)/*"
        var entries = manifest["web_accessible_resources"] as? [Any] ?? []
        if manifest["manifest_version"] as? Int == 2 {
            if !entries.contains(where: { $0 as? String == pattern }) { entries.append(pattern) }
        } else if !entries.contains(where: { (($0 as? [String: Any])?["resources"] as? [String])?.contains(pattern) == true }) {
            entries.append(["resources": [pattern], "matches": ["<all_urls>"]])
        }
        manifest["web_accessible_resources"] = entries
    }
}

/// How many rules that match every address an extension's rules give
/// WebKit, kept under the number it can compile.
///
/// WebKit translates all of an extension's enabled rule sets, its dynamic
/// and its session rules into one content rule list and compiles it. Every
/// translated rule whose url-filter matches every address puts an action on
/// the root of the list's first DFA, and WebKit traps, taking Yab down with
/// it, when one root holds 65,535 of them (crash #39,
/// WebCore::ContentExtensions::addUniversalActionsToDFA, "Too many
/// uncombined actions that match everything"; Filters.UniversalActions
/// keeps Shield's own lists under it). A rule with no urlFilter, regexFilter
/// or requestDomains is one; an allowAllRequests rule always is, once for
/// each of its requestDomains and excludedRequestDomains (WebKit's
/// _WKWebExtensionDeclarativeNetRequestRule, ruleInWebKitFormat). AdBlock's
/// and Adblock Plus's Acceptable Ads set alone gives 42,023 (1,180
/// allowAllRequests rules over 41,269 sites); uBlock Origin Lite's default
/// sets 206, AdGuard's 122, Ghostery's every set together 498
/// (docs/extension-ad-blockers.md).
///
/// Counted as WebKit makes them before it combines any: it merges only
/// unconditioned actions of one kind and flags, so the count is never below
/// what WebKit puts on the root. The shim counts dynamic and session rules
/// the same way (extension-shims.js, "universal").
enum ExtensionRuleBudget {
    /// What WebKit takes on one root: fewer than UInt16.max.
    static let limit = Int(UInt16.max) - 1
    /// Beside the extension: the rule sets it wanted on that Yab keeps off,
    /// a JSON list of their ids.
    static let leftOffFile = ".yab-rules-left-off"
    /// Beside the extension: each rule set's count, by id, for the shim.
    static let countsFile = ".yab-rules-universal"

    /// How many of WebKit's translated rules this rule makes whose
    /// url-filter matches every address.
    static func universal(_ rule: [String: Any]) -> Int {
        let condition = rule["condition"] as? [String: Any] ?? [:]
        let type = (rule["action"] as? [String: Any])?["type"] as? String
        let regex = condition["regexFilter"] as? String
        // With a regexFilter, WebKit leaves requestDomains out of the filter.
        let domains = regex == nil ? (condition["requestDomains"] as? [Any])?.count ?? 0 : 0
        let excluded = (condition["excludedRequestDomains"] as? [Any])?.count ?? 0
        if type == "allowAllRequests" { return max(domains, 1) + excluded }
        guard domains == 0, everything(url: condition["urlFilter"] as? String, regex: regex) else { return 0 }
        var made = max((condition["requestMethods"] as? [Any])?.count ?? 0, 1)
        if condition["initiatorDomains"] != nil, condition["excludedInitiatorDomains"] != nil { made *= 2 }
        if type == "upgradeScheme" { made *= 2 }
        return made
    }

    static func universal(in rules: [Any]) -> Int {
        rules.reduce(0) { $0 + (($1 as? [String: Any]).map(universal) ?? 0) }
    }

    /// Whether WebKit's url-filter for these matches every address: none,
    /// "*", "|*|", a regex of nothing but ".*". Anchored or not, counted.
    static func everything(url: String?, regex: String?) -> Bool {
        if let regex { return regex.range(of: #"^\^?(\.\*)*\$?$"#, options: .regularExpression) != nil }
        guard let url, !url.isEmpty else { return true }
        if url.hasPrefix("||") { return false }
        return url.allSatisfy { $0 == "*" || $0 == "|" }
    }

    /// Of the sets on by default, in the manifest's order, each stays on
    /// while it and the ones kept before it stay under the limit; the ids of
    /// the ones that don't.
    static func over(_ sets: [(id: String, enabled: Bool, universal: Int)], room: Int = limit) -> [String] {
        var total = 0
        var off: [String] = []
        for set in sets where set.enabled {
            if total + set.universal > room { off.append(set.id) } else { total += set.universal }
        }
        return off
    }

    /// The sets kept off, as written beside the extension.
    static func leftOff(in folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(leftOffFile)),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return ids
    }

    static func counts(in folder: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(countsFile)),
              let counts = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return [:] }
        return counts
    }

    static func keep(_ ids: [String], in folder: URL) {
        let file = folder.appendingPathComponent(leftOffFile)
        guard !ids.isEmpty else { try? FileManager.default.removeItem(at: file); return }
        if let data = try? JSONSerialization.data(withJSONObject: ids) { try? data.write(to: file, options: .atomic) }
    }

    /// The line under the extension's name, or nil when nothing is off.
    static func line(_ count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "A rule list is off: too large to load"
        default: return "\(count) rule lists are off: too large to load"
        }
    }
}
