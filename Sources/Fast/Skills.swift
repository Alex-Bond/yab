import Foundation

// What agents know about sites before they get there.
//
// A skill is a folder with a SKILL.md in it, the format Claude Code
// reads too: frontmatter (name, description, the sites it is for, the words
// that call for it) and a page of Markdown on how the site works for an agent
// with yab's tools. yab ships its own (Skills/ beside the sources, copied
// into the app's Resources by build.sh); yours live in the browser's folder,
// under skills/, and win over a built-in one of the same name.
//
// An agent doesn't have to know to look. The first time in a task it opens,
// sends or reads a tab on a site a skill is for, the answer says so at its
// top, with the skill's name, and `skill(name)` gives the page.

enum Skills {
    struct Skill {
        let name: String
        let description: String
        let sites: [String]
        let keywords: [String]
        let body: String
        let own: Bool
        let path: URL
        /// What an agent can do for you on one of its pages, ⌘J.
        var actions: [Action] = []
        /// Addresses that give the site's data with no tab, `fetch` alone.
        var reads: [Read] = []
        /// `signed-in: [user_session]`: the cookies that are there only while
        /// someone is signed in to the site, which decide it (SignIns).
        var signedIn: [String] = []
        /// The things on its pages an action is about, each with a button
        /// of Yab's in the site's own row (SiteItems).
        var items: [Item] = []
    }

    /// `item: Message | in: [data-qa="message_container"] | anchor: … |
    /// button: Reply` in a skill's frontmatter: one kind of thing on the
    /// site's pages (a message, a thread, an issue) that actions marked
    /// `@Message` are about. Where it is (`in`, or `page` for the page
    /// itself), the site's own control Yab's button stands beside
    /// (`anchor`, the last of them in the thing; `min`, how many must
    /// stand together for a row to count; `text`, what one must say), on
    /// which side (`place`), whether it takes the anchor's classes or its
    /// look (`style: class|copy`), and where its sender, link and time
    /// are. SiteItems makes a page script of it (site-items.js).
    struct Item: Equatable, Codable {
        var kind: String
        var container = "page"
        var anchor = ""
        var place = "after"
        var min = 1
        var text = ""
        var style = "copy"
        /// Whose look the button takes, when not the anchor's: GitHub's
        /// grey button beside its blue Submit review.
        var like = ""
        /// What marks one as addressed to you, for the foot's offer: a
        /// selector in it, or `path:` and a pattern over the page's path
        /// (`path:/client/*/D*`, a Slack DM).
        var mine = ""
        var name = ""
        var link = ""
        var when = ""
        var body = ""
        var title = ""
        var button = ""
        var paths = ""
        /// Only where a control there says so: a selector, ` ~ ` and a
        /// pattern over its words (X's box whose button says Reply).
        var gate = ""
        /// The face's size and line in points, when the site's glyphs
        /// beside it don't say: `icon: 18 / 1.35`.
        var icon = 0.0
        var stroke = 0.0
        /// The hover a site's own script draws, as its ink's share: `10%`.
        var hover = ""

        /// The actions about it: `action: Reply | @Message | …`.
        var tag: String { "@" + kind }

        init?(_ raw: String) {
            let parts = raw.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let kind = parts.first, !kind.isEmpty, !kind.contains(":") else { return nil }
            self.kind = kind
            for part in parts.dropFirst() {
                guard let colon = part.firstIndex(of: ":") else { continue }
                let key = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "in": container = value
                case "anchor": anchor = value
                case "place": place = value == "before" ? "before" : "after"
                case "min": min = max(1, Int(value) ?? 1)
                case "text": text = value
                case "style": style = ["class", "clone"].contains(value) ? value : "copy"
                case "like": like = value
                case "mine": mine = value
                case "name": name = value
                case "link": link = value
                case "when": when = value
                case "body": body = value
                case "title": title = value
                case "button": button = value
                case "paths": paths = value
                case "if": gate = value
                case "icon":
                    let sizes = value.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
                    icon = sizes.first ?? 0
                    stroke = sizes.count > 1 ? sizes[1] : 0
                case "hover": hover = value
                default: break
                }
            }
            guard !anchor.isEmpty, !button.isEmpty else { return nil }
        }

        /// Whether its pages include this one: `paths` is a pattern as an
        /// action's, or any page of the site when it has none.
        func fits(_ url: URL) -> Bool {
            paths.isEmpty || Action(title: "", pattern: paths, prompt: "", skill: "").fits(url)
        }
    }

    /// `read: POST app.notion.com/api/v3/search | search pages` in a
    /// skill's frontmatter: an address that answers with the site's data,
    /// read with the user's cookies and no tab (AgentRead). A GET may go
    /// anywhere anyway; a POST goes only where a skill says it only reads.
    /// The pattern is over host and path, `*` matching anything.
    struct Read: Equatable {
        let method: String
        let pattern: String
        let note: String

        func fits(_ method: String, _ url: URL) -> Bool {
            guard method.uppercased() == self.method, var host = url.host()?.lowercased() else { return false }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            let place = host + (url.path.isEmpty ? "/" : url.path).lowercased()
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern.lowercased()).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return place.range(of: regex, options: .regularExpression) != nil
        }
    }

    /// Whether a POST with no tab only reads, as some skill says it does.
    static func reads(_ method: String, _ url: URL) -> Bool {
        all().contains { $0.reads.contains { $0.fits(method, url) } }
    }

    /// `action: Draft a reply | /mail/*#*/* | Draft a reply to this thread…`
    /// in a skill's frontmatter, as many as it has: a name, the pages it is
    /// for (a pattern over the address's path and fragment, `*` matching
    /// anything, or `re:` and a regular expression; the path has no
    /// trailing slash), for one that leaves a draft in the page what the
    /// line says then and the word that sends it (`draft: Reply drafted /
    /// Send`), and what the agent is asked.
    struct Action: Equatable {
        let title: String
        let pattern: String
        var prompt: String
        let skill: String
        /// The skill's own words, when yours (SkillPrompts) stand in their
        /// place.
        var written: String? = nil
        /// A draft it leaves in the page rather than an answer to read: the
        /// line said once it is there, and the word for sending it.
        var draft: Draft? = nil

        func fits(_ url: URL) -> Bool {
            var place = url.path.isEmpty ? "/" : url.path
            if let fragment = url.fragment, !fragment.isEmpty { place += "#" + fragment }
            // `re:` for a regular expression, when a glob can't tell a thread
            // from a list; otherwise `*` matches anything.
            let regex = pattern.hasPrefix("re:")
                ? String(pattern.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                : "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return place.range(of: regex, options: .regularExpression) != nil
        }
    }

    /// The actions for this page, from the skills for its site.
    /// `draft: Review drafted / Submit Review`, the field
    /// before the prompt: the agent writes into the page and stops there.
    struct Draft: Equatable {
        let line: String
        let verb: String

        init?(_ raw: String) {
            guard raw.lowercased().hasPrefix("draft:") else { return nil }
            let rest = raw.dropFirst(6).components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let line = rest.first, !line.isEmpty else { return nil }
            self.line = line
            verb = rest.count > 1 && !rest[1].isEmpty ? rest[1] : "Send"
        }
    }

    static func actions(for url: URL?) -> [Action] {
        guard let url else { return [] }
        return Skills.for(url).flatMap { $0.actions.filter { $0.fits(url) } }
    }

    /// The things on this page actions are about, each with its actions,
    /// the first of them its button's: never one with none.
    static func items(for url: URL?) -> [(item: Item, actions: [Action])] {
        guard let url else { return [] }
        return Skills.for(url).flatMap { skill in
            skill.items.filter { $0.fits(url) }.compactMap { item in
                let actions = skill.actions.filter { $0.pattern == item.tag }
                return actions.isEmpty ? nil : (item, actions)
            }
        }
    }

    static var mine: URL { Store.file("skills") }

    /// The built-in ones: in the app, or, run from the build folder, next to
    /// the sources.
    static var builtIn: URL? {
        if let inside = Bundle.main.resourceURL?.appendingPathComponent("skills"),
           FileManager.default.fileExists(atPath: inside.path) { return inside }
        let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Skills")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    /// Asked from more than one thread (the bench, the yab command, tests
    /// side by side), so read and written under a lock: two writes at once
    /// freed the old value twice (a test process, 2026-10-18).
    private static var cached: (at: Date, stamp: [String], skills: [Skill])?
    private static let cacheLock = NSLock()
    private static var cache: (at: Date, stamp: [String], skills: [Skill])? {
        get { cacheLock.lock(); defer { cacheLock.unlock() }; return cached }
        set { cacheLock.lock(); cached = newValue; cacheLock.unlock() }
    }

    /// All of them, yours first, looked at again at most every few
    /// seconds, and read again only when a SKILL.md came, went or changed:
    /// read and parsed each time, the two dozen of them cost ⌘J's line a
    /// few milliseconds of main thread whenever it came up.
    static func all() -> [Skill] {
        if let cache, Date().timeIntervalSince(cache.at) < 5 { return cache.skills }
        var files: [(file: URL, own: Bool)] = []
        for (root, own) in [(builtIn, false), (mine, true)] {
            guard let root, let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            files += folders.map { ($0.appendingPathComponent("SKILL.md"), own) }
        }
        // Each file's path and when it last changed, a stat apiece.
        files.append((Store.file("boosts/index.json"), false))
        let stamp = files.map { item -> String in
            var info = stat()
            guard stat(item.file.path, &info) == 0 else { return item.file.path }
            return "\(item.file.path) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_size)"
        }
        if let cache, cache.stamp == stamp {
            self.cache = (Date(), stamp, cache.skills)
            return cache.skills
        }
        var byName: [String: Skill] = [:]
        for (file, own) in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let skill = parse(text, own: own, path: file) else { continue }
            byName[skill.name] = skill
        }
        for skill in BoostContributions.skills() { byName[skill.name] = skill }
        let changed = SkillPrompts.all
        if !changed.isEmpty {
            for (name, skill) in byName {
                var skill = skill
                skill.actions = skill.actions.map { action in
                    guard let yours = changed[SkillPrompts.key(action)], yours != action.prompt else { return action }
                    var action = action
                    action.written = action.prompt
                    action.prompt = yours
                    return action
                }
                byName[name] = skill
            }
        }
        let skills = byName.values.sorted { ($0.own ? 0 : 1, $0.name) < ($1.own ? 0 : 1, $1.name) }
        cache = (Date(), stamp, skills)
        return skills
    }

    /// Read again at the next ask: a skill made, changed or deleted here.
    static func reload() { cache = nil }

    /// Whether any skill read so far is for this page's site, without
    /// looking at the files again: every link asks for its site's buttons
    /// (SiteItems.script), and the look, a stat of every SKILL.md, was
    /// ~1 ms of the main thread at each one (round 11 of
    /// docs/evidence/clean-gap-2026-10-13.md). True before the first read,
    /// so the full ask decides then.
    static func mayHave(_ url: URL?) -> Bool {
        guard let cache else { return true }
        guard let url, url.host() != nil else { return false }
        return cache.skills.contains { skill in !Skills.matching([skill], url).isEmpty }
    }

    static func named(_ name: String) -> Skill? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        return all().first { $0.name == wanted }
    }

    /// The skills for a page's site: its host, or any host it is under.
    /// A site may carry a path, for hosts several apps share:
    /// docs.google.com/spreadsheets is Sheets, not Docs.
    static func `for`(_ url: URL?) -> [Skill] {
        matching(all(), url)
    }

    private static func matching(_ skills: [Skill], _ url: URL?) -> [Skill] {
        guard let url, var host = url.host()?.lowercased() else { return [] }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let path = url.path.lowercased()
        return skills.filter { skill in
            skill.sites.contains { site in
                var site = site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
                var under = ""
                if let slash = site.firstIndex(of: "/") { under = String(site[slash...]); site = String(site[..<slash]) }
                return (host == site || host.hasSuffix("." + site)) && (under.isEmpty || path.hasPrefix(under))
            }
        }
    }

    // MARK: - reading a SKILL.md

    static func parse(_ text: String, own: Bool, path: URL) -> Skill? {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields: [String: String] = [:]
        var said: [String] = []
        var readLines: [String] = []
        var itemLines: [String] = []
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "action" { said.append(value) } else if key == "read" { readLines.append(value) }
            else if key == "item" { itemLines.append(value) } else { fields[key] = value }
        }
        let reads: [Read] = readLines.compactMap { raw in
            let parts = raw.components(separatedBy: " | ")
            let head = parts[0].split(separator: " ", maxSplits: 1).map(String.init)
            guard head.count == 2, ["GET", "POST"].contains(head[0].uppercased()) else { return nil }
            var pattern = head[1].trimmingCharacters(in: .whitespaces)
            for scheme in ["https://", "http://"] where pattern.hasPrefix(scheme) { pattern = String(pattern.dropFirst(scheme.count)) }
            if pattern.hasPrefix("www.") { pattern = String(pattern.dropFirst(4)) }
            return Read(method: head[0].uppercased(), pattern: pattern, note: parts.dropFirst().joined(separator: " | "))
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }
        func list(_ raw: String?) -> [String] {
            guard var raw else { return [] }
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            return raw.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let actions: [Action] = said.compactMap { raw in
            // " | " between the fields; a regular expression's own bars have
            // no spaces round them.
            let parts = raw.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, !parts[0].isEmpty, let prompt = parts.last, !prompt.isEmpty else { return nil }
            // A draft's line, when there is one, stands just before the prompt.
            let draft = parts.count >= 4 ? Draft(parts[parts.count - 2]) : nil
            let end = parts.count - (draft == nil ? 1 : 2)
            return Action(title: parts[0], pattern: parts[1..<end].joined(separator: " | "), prompt: prompt, skill: name.lowercased(), draft: draft)
        }
        return Skill(name: name.lowercased(), description: fields["description"] ?? "", sites: list(fields["sites"]).map { $0.lowercased() },
                     keywords: list(fields["keywords"]), body: body, own: own, path: path, actions: actions, reads: reads,
                     signedIn: list(fields["signed-in"]), items: itemLines.compactMap(Item.init))
    }

    /// The list an agent reads, a line each.
    static func index(query: String? = nil) -> String {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let skills = query.flatMap { $0.isEmpty ? nil : matching($0, in: all()) } ?? all()
        return skills.map { "- \($0.name): \($0.description)\($0.sites.isEmpty ? "" : " (\($0.sites.joined(separator: ", ")))")" }.joined(separator: "\n")
    }

    /// Keyword phrases are matched at word boundaries, so "map" does not
    /// select visual-reading for "roadmap". Sites still use hint(for:session:).
    static func matching(_ query: String, in skills: [Skill]) -> [Skill] {
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return skills.filter { skill in
            ([skill.name] + skill.keywords).contains { keyword in
                let word = keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard !word.isEmpty else { return false }
                let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
                return query.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }

    /// System skills have no site to trigger their page hint. Give agents
    /// their names and purposes up front, without loading every skill body.
    static var systemGuide: String {
        let system = all().filter { $0.sites.isEmpty }
        guard !system.isEmpty else { return "" }
        return "\n\nYab system skills: read the relevant skill(name) before this kind of work.\n"
            + system.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
            + "\nUse skills(query: your task) to find site and system skills by their keywords."
    }

    // MARK: - saying so, once per task

    /// Hosts each session has been told about, so it hears it once.
    @MainActor private static var told: [String: Set<String>] = [:]

    /// The line to put over an answer about this page, the first time a
    /// session is on one of a skill's sites.
    @MainActor static func hint(for url: URL?, session: String?) -> String? {
        let found = Skills.for(url).filter { !(told[session ?? "", default: []].contains($0.name)) }
        guard !found.isEmpty else { return nil }
        for skill in found { told[session ?? "", default: []].insert(skill.name) }
        return found.map { "skill: \($0.name), \($0.description) Read it with skill(\"\($0.name)\") before acting here." }.joined(separator: "\n")
    }
}

/// Prompts you changed in Settings › AI › Buttons on Sites, each over the
/// one its skill says, by skill, pattern and title; the button, ⌘J and
/// the agent all get yours. Kept apart from the skill, so a built-in one
/// still gets Yab's updates to everything else.
enum SkillPrompts {
    private static let stored = "skills.prompts"

    static func key(_ action: Skills.Action) -> String { "\(action.skill)|\(action.pattern)|\(action.title)" }

    static var all: [String: String] { Store.settings.dictionary(forKey: stored) as? [String: String] ?? [:] }

    /// Yours for this action; blank, or the skill's own words, is the
    /// skill's again.
    static func set(_ words: String, for action: Skills.Action) {
        var changed = all
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        changed[key(action)] = words.isEmpty || words == (action.written ?? action.prompt) ? nil : words
        Store.settings.set(changed, forKey: stored)
        Skills.reload()
    }
}
