import Foundation

// Filter lists, the ones uBlock Origin reads, turned into rules WebKit
// enforces itself (see Shield). Only what a WebKit rule says exactly is
// kept; everything else is left out rather than stretched to fit, because
// a rule that blocks a little more than its list meant is how a blocker
// breaks a checkout. Left out: scriptlets, redirects, $csp, $removeparam,
// regular expressions, procedural cosmetics, rules that name both sites to
// act on and sites to spare.
//
// WebKit is strict about what it reads. One url-filter it cannot parse (a
// disjunction, a {n} repetition, a character outside ASCII) or one domain
// with a capital in it fails the whole list, not the rule, so what is made
// here stays inside that grammar. An invalid CSS selector only costs its
// own rule.
//
// One more thing WebKit does its own way: an exception (ignore-previous-rules)
// only cancels the rules before it in the same list. Split into several
// lists, an exception would reach only the block rules that happened to
// land in its own, so every list carries all of them at its end, and the
// $important rules after those, where no exception reaches.
//
// The hiding rules for every site are a list of their own for the same
// reason turned around: a site that asks for them off ($generichide) is
// named at that list's end, where the exception reaches those rules and no
// block. And what a list doesn't say of a rule it says of all of them, the
// page itself included: a rule without kinds of load is given every kind
// but the page, so "/adv/" hides a banner and doesn't stop you opening a
// page under /adv/, "||tracker.example^" doesn't stop a mail's link that
// passes through it, and an exception without kinds doesn't turn a page's
// hiding off.

enum Filters {
    /// As many rules a list as WebKit takes (150 000), less a margin. Every
    /// load a page makes is matched against every list, in the web
    /// process's main thread, and each list ends with every exception
    /// (see above), so a list costs each load its own run over the address
    /// and its own copy of those 3 800 exceptions. In six lists of 40 000
    /// that was 0.8 ms a load, 1.15 ms for a long image address, on adhd;
    /// mobbin.com's screens make about two thousand such checks while their
    /// HTML is read, which held DOMContentLoaded at 2.8 s instead of 0.6.
    /// One list of blocks and one of generic hiding take a third less, and
    /// the one list compiles in 5 s off the main thread where six took 9.
    /// YAB_SHIELD_PERLIST at launch tries another size, for measuring.
    static let perList = Int(ProcessInfo.processInfo.environment["YAB_SHIELD_PERLIST"] ?? "") ?? 149_000
    /// Beyond this, the lists are left as they are: three lists, room for
    /// blocking to grow into a second one with the hiding for every site
    /// still given its own, and never less than the 240 000 rules six lists
    /// of 40 000 held. Every page's rules are looked through for every
    /// request, so more is not free.
    static let cap = max(perList * 3, 240_000)

    struct Rule: Hashable {
        enum Action: Hashable {
            case block
            case allow
            case hide(String)
        }

        var action: Action
        var filter: String
        var caseSensitive = false
        var types: [String] = []
        var party: String?
        var context: String?
        var ifDomain: [String] = []
        var unlessDomain: [String] = []

        /// The rule as WebKit reads it, written out by hand: this is done
        /// for a couple of hundred thousand rules, and JSONSerialization of
        /// as many dictionaries took seconds.
        var json: String {
            var trigger = "\"url-filter\":\(Filters.quote(filter))"
            if caseSensitive { trigger += ",\"url-filter-is-case-sensitive\":true" }
            if !types.isEmpty { trigger += ",\"resource-type\":\(Filters.quote(types))" }
            if let party { trigger += ",\"load-type\":[\"\(party)\"]" }
            if let context { trigger += ",\"load-context\":[\"\(context)\"]" }
            if !ifDomain.isEmpty { trigger += ",\"if-domain\":\(Filters.quote(ifDomain.map { "*" + $0 }))" }
            if !unlessDomain.isEmpty { trigger += ",\"unless-domain\":\(Filters.quote(unlessDomain.map { "*" + $0 }))" }
            let action: String
            switch self.action {
            case .block: action = "{\"type\":\"block\"}"
            case .allow: action = "{\"type\":\"ignore-previous-rules\"}"
            case .hide(let selector): action = "{\"type\":\"css-display-none\",\"selector\":\(Filters.quote(selector))}"
            }
            return "{\"trigger\":{\(trigger)},\"action\":\(action)}"
        }
    }

    /// What came out of the lists, sorted by where each rule has to stand.
    struct Rules {
        var blocks: [Rule] = []
        var exceptions: [Rule] = []
        var important: [Rule] = []
        /// Hiding rules for every site, or every site but a few, and the
        /// exceptions that end their list: the sites and pages that turn
        /// them off.
        var generic: [Rule] = []
        var unhide: [Rule] = []
        /// Lines that were rules of a kind left out, comments not counted.
        var skipped = 0
        /// The sites with hiding rules of their own: a page of one of them
        /// (or of a part of one) always gets the lists, never what Shield
        /// learned of the site.
        var hidingSites = Set<String>()

        var count: Int { blocks.count + exceptions.count + important.count + generic.count + unhide.count }
    }

    /// Where a rule made from a network line goes.
    enum Place: Hashable {
        case plain
        case important
        /// $generichide: the generic hiding rules off where it matches.
        case unhide
        /// $elemhide: all hiding off, the site's own rules too.
        case unhideAll
    }

    private struct PlacedRule: Hashable {
        var rule: Rule
        var place: Place
    }

    // MARK: - converting

    static func convert(_ texts: [String]) -> Rules {
        // Lines cut on bytes rather than characters: a few megabytes of
        // text, and walking it character by character was most of the time.
        var lines: [String] = []
        for text in texts {
            for line in text.utf8.split(separator: UInt8(ascii: "\n")) {
                if let trimmed = trim(Substring(line)) { lines.append(trimmed) }
            }
        }

        // $badfilter takes back the rule it repeats, in whichever list.
        var taken = Set<String>()
        for line in lines where line.contains("badfilter") {
            if let undone = unbadfilter(line) { taken.insert(undone) }
        }

        var rules = Rules()
        // An identical block after the exceptions still has work to do.
        // Deduplicate within its output group, not across rule precedence.
        var seen = Set<PlacedRule>()
        var hides = Hides()
        for line in lines {
            if line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if taken.contains(line) || line.contains("badfilter") {
                rules.skipped += 1
                continue
            }
            if let host = hostsLine(line) {
                // A hosts entry is the same whole-site rule as ||host^.
                // uBlock's $badfilter may name that form in another list.
                if taken.contains("||\(host.lowercased())^") {
                    rules.skipped += 1
                    continue
                }
                for rule in hostRule(host).map(ofLoads) ?? [] where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted {
                    rules.blocks.append(rule)
                }
                continue
            }
            if line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") && !line.hasPrefix("#?#") && !line.hasPrefix("#$#") {
                continue // a comment in a hosts file
            }
            if let marker = cosmeticMarker(line) {
                if !hides.take(line, marker) { rules.skipped += 1 }
                continue
            }
            guard let made = network(line) else {
                rules.skipped += 1
                continue
            }
            for (rule, place) in made {
                // $elemhide and $generichide emit the same generic-list
                // exception, but only the former removes site-owned hiding.
                if place == .unhideAll { hides.unhidden.formUnion(rule.ifDomain) }
                let group: Place = place == .unhideAll ? .unhide : place
                guard seen.insert(PlacedRule(rule: rule, place: group)).inserted else { continue }
                switch place {
                case .unhide, .unhideAll:
                    rules.unhide.append(rule)
                case .important:
                    rules.important.append(rule)
                case .plain:
                    if rule.action == .allow { rules.exceptions.append(rule) } else { rules.blocks.append(rule) }
                }
            }
        }
        let (generic, own, dropped, sites) = hides.rules()
        rules.hidingSites = sites
        rules.skipped += dropped
        for rule in generic where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted { rules.generic.append(rule) }
        for rule in own where seen.insert(PlacedRule(rule: rule, place: .plain)).inserted { rules.blocks.append(rule) }
        return rules
    }

    /// A line without the spaces, tabs and carriage return around it, or
    /// nil if nothing is left.
    private static func trim(_ line: Substring) -> String? {
        let bytes = line.utf8
        let blank: (UInt8) -> Bool = { $0 == 32 || $0 == 9 || $0 == 13 }
        guard let first = bytes.firstIndex(where: { !blank($0) }), let last = bytes.lastIndex(where: { !blank($0) }) else { return nil }
        return String(Substring(bytes[first...last]))
    }

    /// The rules as lists WebKit compiles one by one, and how many were
    /// left out to stay under the cap.
    struct Split {
        var lists: [String]
        var left: Int
        /// How many of the lists, at the end, hold only the generic hiding
        /// and the exceptions that reach it: what a quiet site keeps.
        var hiding = 0
    }

    /// The block and site hiding rules shared out, and after them, in every
    /// list, every exception, then every $important rule; then the generic
    /// hiding rules, each of their lists ended by the exceptions that reach
    /// a page's hiding. Select at most `cap / perList` full-sized lists first;
    /// unsafe action sets may need more, smaller lists, with the same rules.
    /// This adds matching work only for those sets. Over the selection cap, the
    /// rules read last are the ones left out, the lists being read in the
    /// order they are named, the most useful first, and generic hiding
    /// after blocking. Nil when the exceptions alone would crowd the lists,
    /// which is a list gone wrong rather than one to cut: the build before
    /// is kept.
    static func lists(_ rules: Rules, perList: Int = perList, cap: Int = cap) -> Split? {
        guard let plan = plan(rules, perList: perList, cap: cap) else { return nil }
        return Split(lists: plan.parts.map(\.json), left: plan.left, hiding: plan.hiding)
    }

    struct Part {
        var body: ArraySlice<Rule>
        var tail: [Rule]
        var json: String {
            "[" + (body + tail).map(\.json).joined(separator: ",") + "]"
        }
    }

    struct Plan {
        var parts: [Part]
        var left: Int
        var hiding: Int
    }

    /// Keep the rule slices until needed, rather than every list's JSON
    /// alongside WebKit's compiler. The iPhone compiles one part at a time.
    static func plan(_ rules: Rules, perList: Int = perList, cap: Int = cap) -> Plan? {
        let most = max(1, cap / perList)
        // Exceptions and $important rules end every list; past a quarter
        // of one, the lists would be mostly the same rules over and over.
        let limit = perList / 4
        guard rules.exceptions.count <= limit else { return nil }
        let important = rules.important.prefix(limit - rules.exceptions.count)
        // An exception with no kind of load is one for the whole page,
        // @@||site^$document, and turns its hiding off too.
        let whole = rules.exceptions.filter { $0.types.isEmpty }
        let unhide = rules.unhide.prefix(max(0, limit - whole.count))
        var left = rules.important.count - important.count + rules.unhide.count - unhide.count

        let tail = rules.exceptions + important
        let room = perList - tail.count
        var blocks = rules.blocks[...]
        let needed = blocks.isEmpty && important.isEmpty ? 0 : max(1, (blocks.count + room - 1) / room)
        if needed > most {
            left += blocks.count - most * room
            blocks = blocks.prefix(most * room)
        }
        let hidingTail = whole + unhide
        let hidingRoom = perList - hidingTail.count
        var generic = rules.generic[...]
        let spare = most - min(needed, most)
        if generic.count > spare * hidingRoom {
            left += generic.count - spare * hidingRoom
            generic = generic.prefix(spare * hidingRoom)
        }

        var parts: [Part] = []
        func share(_ body: ArraySlice<Rule>, room: Int, tail: [Rule]) -> Bool {
            // Any tail action may be distinct, including after an exception
            // clears WebKit's combining maps. Reserve all of them each time.
            guard tail.count <= UniversalActions.limit else { return false }
            var start = body.startIndex
            repeat {
                var actions = UniversalActions()
                var end = start
                while end < body.endIndex, end - start < room {
                    let rule = body[end]
                    guard actions.count + actions.cost(rule) + tail.count <= UniversalActions.limit else { break }
                    actions.append(rule)
                    end += 1
                }
                guard end > start || start == body.endIndex else { return false }
                if start < end || !tail.isEmpty { parts.append(Part(body: body[start..<end], tail: tail)) }
                start = end
            } while start < body.endIndex
            return true
        }
        if needed > 0, !share(blocks, room: room, tail: tail) { return nil }
        let blocking = parts.count
        if !generic.isEmpty, !share(generic, room: hidingRoom, tail: hidingTail) { return nil }
        return Plan(parts: parts, left: left, hiding: parts.count - blocking)
    }

    /// A conservative bound on distinct actions in any universal DFA root.
    /// WebKit requires fewer than UInt16.max, even below its rule-count cap.
    /// Conditions prevent combining; plain blocks share an action by flags,
    /// and plain CSS selectors share one by trigger, until an allow resets it.
    /// Source: WebKit ContentExtensionCompiler.cpp, serializeActions and
    /// addUniversalActionsToDFA, blob 576a1d54820fd497996d0bd512d1fd8403e768bd.
    struct UniversalActions {
        static let limit = Int(UInt16.max) - 1
        private(set) var count = 0
        private var blocks = Set<Rule>()
        private var hides = Set<Rule>()

        private func key(_ rule: Rule) -> Rule {
            var key = rule
            switch rule.action {
            case .block: key.filter = ""
            case .hide: key.action = .hide("")
            case .allow: break
            }
            return key
        }

        func cost(_ rule: Rule) -> Int {
            if rule.action == .allow || !rule.ifDomain.isEmpty || !rule.unlessDomain.isEmpty { return 1 }
            switch rule.action {
            case .block:
                // Counting even non-universal blocks is safe and stays small.
                return blocks.contains(key(rule)) ? 0 : 1
            case .hide:
                // onSite requires characters. URLFilterParser cannot put it
                // on the universal root. Other patterns are counted, even if
                // they too need characters, instead of guessing their regex.
                if rule.filter.hasPrefix("^[a-z-]+://") { return 0 }
                return hides.contains(key(rule)) ? 0 : 1
            case .allow: return 1
            }
        }

        mutating func append(_ rule: Rule) {
            count += cost(rule)
            if rule.action == .allow {
                blocks.removeAll(keepingCapacity: true)
                hides.removeAll(keepingCapacity: true)
            } else if rule.ifDomain.isEmpty && rule.unlessDomain.isEmpty {
                switch rule.action {
                case .block: blocks.insert(key(rule))
                case .hide where !rule.filter.hasPrefix("^[a-z-]+://"): hides.insert(key(rule))
                default: break
                }
            }
        }
    }

    // MARK: - network rules

    /// A network filter as rules, each with where it goes. Most lines are
    /// one rule; one that names frames and other things beside is two,
    /// because a frame is told apart by where it loads, which WebKit can
    /// only say of a whole rule, and so is one that names no kind at all:
    /// every kind but the page, and pages in frames.
    static func network(_ line: String) -> [(Rule, Place)]? {
        var pattern = Substring(line)
        let exception = pattern.hasPrefix("@@")
        if exception { pattern = pattern.dropFirst(2) }
        // /regex/: WebKit's grammar is too small to carry one faithfully.
        if pattern.hasPrefix("/"), pattern.count > 2, pattern.hasSuffix("/") || pattern.contains("/$") { return nil }

        var options: [(name: String, value: String?)] = []
        if let dollar = optionsStart(pattern) {
            for token in pattern[pattern.index(after: dollar)...].split(separator: ",", omittingEmptySubsequences: false) {
                guard !token.isEmpty else { return nil }
                if let equals = token.firstIndex(of: "=") {
                    options.append((token[..<equals].lowercased(), String(token[token.index(after: equals)...])))
                } else {
                    options.append((token.lowercased(), nil))
                }
            }
            pattern = pattern[..<dollar]
        }

        var rule = Rule(action: exception ? .allow : .block, filter: "")
        var important = false
        var wanted = Set<String>()
        var unwanted = Set<String>()
        var frames: String?
        var whole = false
        var includes: [String] = []
        var excludes: [String] = []
        var documentOnly = false
        var webrtc = false
        var hiding: Place?
        var odd = 0

        for (name, value) in options {
            switch name {
            case "third-party", "3p", "~first-party", "~1p":
                guard rule.party != "first-party" else { return nil }
                rule.party = "third-party"
            case "first-party", "1p", "~third-party", "~3p":
                guard rule.party != "third-party" else { return nil }
                rule.party = "first-party"
            case "match-case":
                rule.caseSensitive = true
            case "important":
                important = true
            case "all":
                whole = true
            case "reason":
                continue // a note for people, it changes nothing
            case "domain", "from":
                guard let value else { return nil }
                for domain in value.split(separator: "|") {
                    if domain.hasPrefix("~") {
                        guard let clean = plainDomain(domain.dropFirst()) else { return nil }
                        excludes.append(clean)
                    } else if let clean = plainDomain(domain) {
                        includes.append(clean)
                    } else {
                        odd += 1 // left out below, unless it only narrows an exception to hiding
                    }
                }
            case "doc", "document":
                if exception { documentOnly = true } else { frames = frames == "child-frame" ? "any" : "top-frame" }
            case "subdocument", "frame":
                frames = frames == "top-frame" ? "any" : "child-frame"
            case "popup":
                wanted.insert("popup")
            case "generichide", "ghide":
                guard exception else { return nil }
                if hiding == nil { hiding = .unhide }
            case "elemhide", "ehide":
                guard exception else { return nil }
                hiding = .unhideAll
            default:
                if name.hasPrefix("~"), let type = kinds[String(name.dropFirst())] {
                    unwanted.formUnion(type)
                } else if let type = kinds[name] {
                    wanted.formUnion(type)
                } else if name == "webrtc" {
                    // WebKit has no such load. Beside other kinds it can be
                    // dropped, the rule only narrows; on its own, not.
                    webrtc = true
                } else if name == "~webrtc" {
                    continue // every kind WebKit has
                } else {
                    return nil // $redirect, $csp, $removeparam, $to, …
                }
            }
        }
        if webrtc, wanted.isEmpty, frames == nil { return nil }
        guard includes.isEmpty || excludes.isEmpty else { return nil }
        guard wanted.isEmpty || unwanted.isEmpty else { return nil }
        rule.ifDomain = Array(Set(includes)).sorted()
        rule.unlessDomain = Array(Set(excludes)).sorted()

        // @@||site^$generichide, @@*$ghide,domain=a.com|b.*: the page's
        // hiding off, which is decided by the page's own address, so the
        // pattern is matched against it at the end of the hiding list.
        // Sites WebKit can't name are dropped from the list, which only
        // leaves them hidden as before; with nothing else said, it stands.
        if let hiding {
            let said = options.filter { !["generichide", "ghide", "elemhide", "ehide", "domain", "from"].contains($0.name) }
            guard said.isEmpty, excludes.isEmpty else { return nil }
            if let host = pureHost(pattern), rule.ifDomain.isEmpty {
                rule.filter = ".*"
                rule.ifDomain = [host]
            } else if pattern.isEmpty || pattern == "*" {
                guard !rule.ifDomain.isEmpty else { return nil }
                rule.filter = ".*"
            } else {
                guard let filter = urlFilter(pattern), !everywhere(pattern) || !rule.ifDomain.isEmpty else { return nil }
                rule.filter = filter
            }
            // $elemhide reaches a site's own hiding rules only by the sites
            // it names.
            if hiding == .unhideAll, rule.ifDomain.isEmpty || rule.filter != ".*" { return nil }
            return [(rule, hiding)]
        }
        guard odd == 0 else { return nil }

        // @@||site^$document: nothing is blocked on that site's pages.
        if documentOnly {
            guard options.count == 1, rule.ifDomain.isEmpty, rule.unlessDomain.isEmpty,
                  let host = pureHost(pattern) else { return nil }
            rule.filter = ".*"
            rule.ifDomain = [host]
            return [(rule, .plain)]
        }

        if pattern.isEmpty || pattern == "*" || everywhere(pattern) {
            // Everything, narrowed only by what it is or where: fine on the
            // sites it names, a way to block the web otherwise. "|https://"
            // is everything too, said another way.
            guard !rule.ifDomain.isEmpty else { return nil }
            rule.filter = pattern.isEmpty || pattern == "*" ? ".*" : (urlFilter(pattern) ?? ".*")
        } else {
            guard let filter = urlFilter(pattern) else { return nil }
            rule.filter = filter
        }

        if !unwanted.isEmpty {
            wanted = Set(everything).subtracting(unwanted)
        }
        if whole {
            wanted = []
            frames = nil
        }
        let place: Place = important && !exception ? .important : .plain
        var made: [(Rule, Place)] = []
        if !wanted.isEmpty {
            var r = rule
            r.types = wanted.sorted()
            made.append((r, place))
        }
        if let frames {
            var r = rule
            r.types = ["document"]
            if frames != "any" { r.context = frames }
            made.append((r, place))
        }
        if made.isEmpty {
            if whole || (!exception && rule.party == "third-party" && pureHost(pattern) != nil) {
                // $all: the site's own pages too, as the badware lists mean
                // it. And a whole site's third-party loads: one rule, as a
                // page you open is never one.
                made.append((rule, place))
            } else {
                made += ofLoads(rule).map { ($0, place) }
            }
        }
        return made
    }

    /// A rule said of what a page loads and of pages in frames, never of
    /// the page itself: WebKit would otherwise refuse to open a page whose
    /// address matches, or take a page's hiding off for an exception that
    /// matches it. A whole site too, "||ads.example^" or a hosts line: a
    /// link that only passes through a tracker (a mail's click tracking, an
    /// ad's redirect) opens. uBlock stops such a page with a warning you
    /// can pass; WebKit has no warning, only a page that never opens. Only
    /// $doc and $all, what the badware lists write, stop the page itself.
    private static func ofLoads(_ rule: Rule) -> [Rule] {
        var loads = rule
        loads.types = (everything + ["popup"]).sorted()
        var framed = rule
        framed.types = ["document"]
        framed.context = "child-frame"
        return [loads, framed]
    }

    /// Kinds of load in the lists' words, as WebKit names them. "object"
    /// was a plug-in, which WebKit loads as "other".
    private static let kinds: [String: Set<String>] = [
        "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"], "media": ["media"], "xmlhttprequest": ["fetch"], "xhr": ["fetch"],
        "websocket": ["websocket"], "ping": ["ping"], "beacon": ["ping"], "other": ["other"], "object": ["other"],
    ]
    /// What a page loads, frames and pop-ups aside: what "~image" leaves.
    private static let everything = ["script", "image", "svg-document", "style-sheet", "font", "media", "fetch", "websocket", "ping", "other"]

    /// A pattern every address matches, or every one of a scheme: "|",
    /// "|http", "|https://", "://". Without sites named it would reach the
    /// whole web, the way "*" would.
    static func everywhere(_ pattern: Substring) -> Bool {
        var rest = pattern.lowercased()[...]
        let anchored = rest.hasPrefix("|") && !rest.hasPrefix("||")
        if anchored { rest = rest.dropFirst() }
        while rest.last == "*" || rest.last == "^" { rest = rest.dropLast() }
        if rest.isEmpty { return true }
        let schemes = ["https://", "http://", "wss://", "ws://"]
        return anchored ? schemes.contains { $0.hasPrefix(rest) } : schemes.contains { $0.contains(rest) }
    }

    /// Where the options start: the last "$" followed by something that
    /// reads as options, not a "$" in an address.
    private static func optionsStart(_ pattern: Substring) -> Substring.Index? {
        guard let dollar = pattern.lastIndex(of: "$") else { return nil }
        let tail = pattern[pattern.index(after: dollar)...]
        guard let first = tail.first, first.isLetter || first == "~" || first.isNumber else { return nil }
        return dollar
    }

    /// An ABP pattern as a url-filter WebKit's grammar accepts, or nil.
    /// Worked on bytes: only ASCII gets this far.
    static func urlFilter(_ source: Substring) -> String? {
        guard source.utf8.allSatisfy({ $0 < 0x80 && $0 != 32 }) else { return nil }
        var pattern = Array(source.utf8)[...]
        var out: [UInt8] = []
        out.reserveCapacity(pattern.count * 2 + 24)
        var endAnchor = false
        let star = UInt8(ascii: "*"), caret = UInt8(ascii: "^"), bar = UInt8(ascii: "|")

        if pattern.starts(with: [bar, bar]) {
            pattern = pattern.dropFirst(2)
            let end = pattern.firstIndex(where: { "/^?*|:".utf8.contains($0) }) ?? pattern.endIndex
            let host = pattern[..<end].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            guard host.contains(UInt8(ascii: ".")), host.allSatisfy({ isHostByte($0) }) else { return nil }
            out += Array("^[a-z-]+://([^/]*\\.)?".utf8)
            escape(host[...], into: &out)
            pattern = pattern[end...]
            // Right after the host the separator can only be where the
            // path or the port starts.
            if pattern.first == caret {
                out += Array("[/:]".utf8)
                pattern = pattern.dropFirst()
            }
        } else if pattern.first == bar {
            out.append(caret)
            pattern = pattern.dropFirst()
        }
        if pattern.last == bar {
            endAnchor = true
            pattern = pattern.dropLast()
        }
        // A trailing * says nothing; a leading one neither, unanchored.
        if !endAnchor { while pattern.last == star { pattern = pattern.dropLast() } }
        if out.isEmpty { while pattern.first == star { pattern = pattern.dropFirst() } }
        guard !out.isEmpty || pattern.count >= 3 else { return nil }

        for index in pattern.indices {
            switch pattern[index] {
            case star:
                out += Array(".*".utf8)
            case caret:
                if index == pattern.index(before: pattern.endIndex) {
                    // Last: a separator, or the end of the address.
                    out += Array((endAnchor ? "[^a-zA-Z0-9_.%-]?" : "([^a-zA-Z0-9_.%-].*)?").utf8)
                    endAnchor = true
                } else {
                    out += Array("[^a-zA-Z0-9_.%-]".utf8)
                }
            default:
                escape(pattern[index...index], into: &out)
            }
        }
        if endAnchor { out.append(UInt8(ascii: "$")) }
        guard out.count <= 1024 else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 46 || byte == 45 || byte == 95
    }

    private static let special = Set(".?+()[]{}$|\\^*".utf8)

    private static func escape(_ bytes: ArraySlice<UInt8>, into out: inout [UInt8]) {
        for byte in bytes {
            if special.contains(byte) { out.append(UInt8(ascii: "\\")) }
            out.append(byte)
        }
    }

    static func escape(_ text: String) -> String {
        var out: [UInt8] = []
        escape(Array(text.utf8)[...], into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Every address on `site` and its subdomains, as `||site^` reads.
    static func onSite(_ site: String) -> String {
        "^[a-z-]+://([^/]*\\.)?" + escape(site) + "[/:]"
    }

    /// `||example.com^` and nothing else: the site it names.
    private static func pureHost(_ pattern: Substring) -> String? {
        guard pattern.hasPrefix("||"), pattern.hasSuffix("^") else { return nil }
        return plainDomain(pattern.dropFirst(2).dropLast())
    }

    /// A domain as WebKit takes it: lowercase ASCII, no wildcards, no
    /// uBO "example.*" that means every top-level domain.
    static func plainDomain(_ value: Substring) -> String? {
        let domain = value.lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return domain
    }

    /// The line a $badfilter line takes back: itself without that option.
    private static func unbadfilter(_ line: String) -> String? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let options = line[line.index(after: dollar)...].split(separator: ",").filter { $0 != "badfilter" }
        let head = String(line[..<dollar])
        return options.isEmpty ? head : head + "$" + options.joined(separator: ",")
    }

    // MARK: - hosts files

    /// `0.0.0.0 ads.example.com`, as Peter Lowe's list writes them.
    private static func hostsLine(_ line: String) -> String? {
        guard let first = line.first, first == "0" || first == "1" || first == ":" else { return nil }
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, ["127.0.0.1", "0.0.0.0", "::1", "::"].contains(parts[0]) else { return nil }
        return String(parts[1])
    }

    private static func hostRule(_ host: String) -> Rule? {
        guard let domain = plainDomain(Substring(host)), domain != "localhost.localdomain" else { return nil }
        return Rule(action: .block, filter: "^[a-z-]+://([^/]*\\.)?" + escape(domain) + "[/:]")
    }

    // MARK: - cosmetic rules

    private static func cosmeticMarker(_ line: String) -> Range<String.Index>? {
        // The earliest of them, and never inside an attribute selector.
        guard let hash = line.firstIndex(of: "#") else { return nil }
        if let bracket = line.firstIndex(of: "["), bracket < hash { return nil }
        for marker in ["##", "#@#", "#?#", "#@?#", "#$#", "#@$#", "#%#"] {
            if let range = line.range(of: marker), range.lowerBound == hash { return range }
        }
        return nil
    }

    /// Hiding rules, gathered first because an exception anywhere in the
    /// lists ("site#@#.ad") changes the rule for that selector everywhere.
    private struct Hides {
        var everywhere = Set<String>()
        var sparing: [String: Set<String>] = [:]
        var only: [String: Set<String>] = [:]
        var order: [String] = []
        var spared: [String: Set<String>] = [:]
        var anywhereSpared = Set<String>()
        /// Sites with all their hiding off ($elemhide).
        var unhidden = Set<String>()

        mutating func take(_ line: String, _ marker: Range<String.Index>) -> Bool {
            let kind = line[marker]
            guard kind == "##" || kind == "#@#" else { return false }
            let selector = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard Filters.selector(selector) else { return false }
            let domains = line[..<marker.lowerBound]
            var includes: [String] = []
            var excludes: [String] = []
            for piece in domains.split(separator: ",") {
                let part = piece.trimmingCharacters(in: .whitespaces)
                if part.hasPrefix("~") {
                    guard let clean = plainDomain(Substring(part.dropFirst())) else { return false }
                    excludes.append(clean)
                } else {
                    guard let clean = plainDomain(Substring(part)) else { return false }
                    includes.append(clean)
                }
            }
            if kind == "#@#" {
                // An exception with no site takes the selector away.
                guard excludes.isEmpty else { return false }
                if includes.isEmpty { anywhereSpared.insert(selector) } else { spared[selector, default: []].formUnion(includes) }
                return true
            }
            guard includes.isEmpty || excludes.isEmpty else { return false }
            if everywhere.contains(selector) == false, sparing[selector] == nil, only[selector] == nil { order.append(selector) }
            if !includes.isEmpty {
                only[selector, default: []].formUnion(includes)
            } else if !excludes.isEmpty {
                sparing[selector, default: []].formUnion(excludes)
            } else {
                everywhere.insert(selector)
            }
            return true
        }

        /// The generic rules, the sites' own, how many of the sites' own
        /// were dropped whole, and the sites that kept some.
        func rules() -> (generic: [Rule], own: [Rule], dropped: Int, sites: Set<String>) {
            var generic: [Rule] = []
            var own: [Rule] = []
            var dropped = 0
            var named = Set<String>()
            for selector in order where !anywhereSpared.contains(selector) {
                let spare = spared[selector] ?? []
                if everywhere.contains(selector) || sparing[selector] != nil {
                    // Everywhere but where it is excepted. A generic rule
                    // with sites to spare is no longer in the stylesheet
                    // WebKit gives every page; it is matched per page, as a
                    // site's own rules are.
                    let unless = everywhere.contains(selector) ? spare : spare.union(sparing[selector] ?? [])
                    generic.append(Rule(action: .hide(selector), filter: ".*", unlessDomain: unless.sorted()))
                } else if let sites = only[selector] {
                    // A site stays only if nothing spares it: not itself, not
                    // a domain above it, and not a part of it, since WebKit
                    // can't say "example.com but not shop.example.com" in
                    // one rule and the rule for the whole site would reach
                    // the part.
                    let off = spare.union(unhidden)
                    let left = sites.filter { site in
                        !off.contains(where: { site == $0 || site.hasSuffix("." + $0) || $0.hasSuffix("." + site) })
                    }
                    // One rule a site, matched by the address of the page
                    // (and anything else loaded from the site), not a rule
                    // for every address with the site as a condition: WebKit
                    // gives every load of every page each rule whose
                    // url-filter matches before it looks at conditions, and
                    // ten thousand ".*" hiding rules held every script and
                    // image nytimes.com loads while it was being read, its
                    // HTML parsed in 1.4 s instead of 0.2.
                    if left.isEmpty { dropped += 1 }
                    for site in left.sorted() { own.append(Rule(action: .hide(selector), filter: Filters.onSite(site))) }
                    named.formUnion(left)
                }
            }
            return (generic, own, dropped, named)
        }
    }

    /// A selector CSS can read, uBO's own additions ruled out. WebKit checks
    /// again when it compiles and drops what it can't parse, but those are
    /// best not counted against the cap.
    static func selector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count <= 1024, selector.allSatisfy(\.isASCII) else { return false }
        if selector.hasPrefix("+js(") || selector.hasPrefix("^") || selector.hasPrefix("{") { return false }
        for token in [":has-text(", ":contains(", ":xpath(", ":upward(", ":nth-ancestor(", ":-abp-", ":matches-css",
                      ":matches-attr", ":matches-path", ":matches-prop", ":matches-media", ":min-text-length(",
                      ":watch-attr(", ":remove", ":style(", ":others(", ":if(", ":if-not(", "{", "}"] where selector.contains(token) {
            return false
        }
        return true
    }

    // MARK: - JSON

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func quote(_ list: [String]) -> String {
        "[" + list.map { quote($0) }.joined(separator: ",") + "]"
    }
}
