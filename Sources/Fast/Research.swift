import AppKit
import Foundation

// With Settings › Tabs' "⌘-clicking links makes folders" on, a search
// gathers what it found. A page opened from a results page with ⌘ or the
// middle button starts a folder named for the words searched, the
// results page first in it; what is opened from it, or from any page in it,
// goes in after the last of its tabs. The folder is yours in every way (a
// Nest, Kept.swift), but among today's tabs, not above the line: it opens and
// shuts, is renamed, ungrouped and dragged out of as a folder of yours is,
// and goes with tidying up as today's tabs go, all of it at once.
//
// Grouped by where the tabs came from, never by what a model makes of them:
// the rule always holds and is said in one sentence. Inside the folder a tab
// is called by what sets it apart, the words searched taken out of its title.
//
// With Settings › Tabs' "⌘-clicking links makes folders" on, as in Dia, any
// other page of today's does the same (gatherLinks): the folder is what a
// ⌘-click made, and only its name is the model's, since the user asked for
// Dia's (2026-10-16, LinkFolders.swift). A search's folder keeps its words.
//
// Left alone twenty minutes, the folder shuts and its tabs sleep; the row
// stays as it is, and a click brings them all back where they were.

extension Engine {
    /// The words a results page was asked for, or nil when the address isn't
    /// one: any of the engines yab knows, whichever is picked, and the
    /// address of your own in Settings.
    static func terms(of url: URL, custom: String? = nil) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        func value(_ name: String) -> String? { Engine.value(name, in: parts) }
        var found: String?
        // Google's many countries, google.com, google.co.uk, google.de.
        if bare.hasPrefix("google."), path == "/search" {
            found = value("q")
        } else {
            switch bare {
            case "duckduckgo.com", "html.duckduckgo.com", "lite.duckduckgo.com": found = value("q")
            case "bing.com": found = path == "/search" ? value("q") : nil
            case "ecosia.org": found = path == "/search" ? value("q") : nil
            case "startpage.com": found = path.hasPrefix("/sp/search") || path.hasPrefix("/do/search") ? value("query") ?? value("q") : nil
            case "kagi.com": found = path == "/search" ? value("q") : nil
            case "search.brave.com": found = path == "/search" ? value("q") : nil
            case "qwant.com": found = value("q")
            case "yandex.com", "yandex.ru", "ya.ru": found = path.hasPrefix("/search") ? value("text") : nil
            case "perplexity.ai": found = path == "/search" ? value("q") : nil
            default: found = nil
            }
        }
        if found == nil, let words = own(url, parts: parts, custom: custom ?? customTemplate) { found = words }
        guard let words = found?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        return words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Your own template's words: its host and path, and the parameter that
    /// holds `%s`.
    private static func own(_ url: URL, parts: URLComponents, custom: String) -> String? {
        let template = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accepts(template),
              let shape = URLComponents(string: template.replacingOccurrences(of: "%s", with: mark)),
              shape.host?.lowercased() == parts.host?.lowercased(),
              shape.path.lowercased() == parts.path.lowercased(),
              let name = shape.queryItems?.first(where: { $0.value == mark })?.name
        else { return nil }
        return value(name, in: parts)
    }

    /// A query's value as the form sent it: a plus is a space there, and a
    /// plus typed is %2B.
    static func value(_ name: String, in parts: URLComponents) -> String? {
        guard let raw = parts.percentEncodedQueryItems?.first(where: { $0.name == name })?.value else { return nil }
        return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

enum Research {
    /// A folder's name from the words searched: as typed, the first letter
    /// made a capital, the spaces made single.
    static func name(_ words: String) -> String {
        let clean = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = clean.first else { return "Search" }
        return first.uppercased() + clean.dropFirst()
    }

    /// Two searches are the same inquiry when the later one keeps at least
    /// half the words of the first: "flights lisbon" then "cheap flights
    /// lisbon may" stays in its folder, "hotels porto" starts another.
    static func alike(_ before: String, _ after: String) -> Bool {
        let a = Set(words(before)), b = Set(words(after))
        guard !a.isEmpty else { return false }
        return Double(a.intersection(b).count) >= Double(a.count) / 2
    }

    /// Lowercased words, letters and digits only, the small ones that join
    /// others left out.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !filler.contains($0) }
    }

    /// Words that only join others, in the languages people search in most
    /// here.
    private static let filler: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "for", "and", "or", "with", "at", "by", "from", "vs",
        "de", "la", "le", "el", "en",
    ]

    /// What a tab in a search's folder is called in its row: its title less
    /// the words searched and the site's own name at its end, so the rows
    /// say what sets each page apart. Nothing much left, the site's name.
    /// Nil when the plain title is as good.
    static func label(title raw: String, host: String, search: String) -> String? {
        let title = MarkdownLink.title(raw, host: host)
        let asked = Set(words(search).map(stem))
        guard !asked.isEmpty, !title.isEmpty else { return nil }
        // The title's own words in order, each kept with what follows it,
        // so what is left reads as it was written.
        var kept: [Substring] = []
        var took = false
        for token in title.split(separator: " ", omittingEmptySubsequences: true) {
            let bare = stem(token.lowercased().replacingOccurrences(of: "’s", with: "").replacingOccurrences(of: "'s", with: "")
                .filter { $0.isLetter || $0.isNumber })
            if !bare.isEmpty, asked.contains(bare) {
                took = true
                continue
            }
            kept.append(token)
        }
        guard took else { return nil }
        // Joining words and marks left hanging at either end go.
        let loose: Set<String> = filler.union(["-", "|", "–", "—", ":", "·", "•", "/", "&", "+"])
        while let first = kept.first, loose.contains(first.lowercased()) || first.allSatisfy({ !$0.isLetter && !$0.isNumber }) { kept.removeFirst() }
        while let last = kept.last, loose.contains(last.lowercased()) || last.allSatisfy({ !$0.isLetter && !$0.isNumber }) { kept.removeLast() }
        var left = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -|–—:·•,"))
        if left.filter({ $0.isLetter || $0.isNumber }).count < 3 { left = "" }
        if left.isEmpty { return site(host) }
        return left.prefix(1).uppercased() + left.dropFirst()
    }

    /// A word and its plural as one: "trams" is "tram", "lisbon's" was made
    /// "lisbon" before this.
    static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    /// A site as its row says it: the host less "www.".
    static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - the tab's row

extension Tab {
    /// What its row says: in a search's folder, what sets it apart from the
    /// others (Research.label); anywhere else, or named by you, its label.
    var rowLabel: String {
        guard name == nil, let search = nest?.search, let host = address?.host(),
              let short = Research.label(title: title, host: host, search: search) else { return counted(label) }
        return short
    }

    /// The label without the title's count, while its mark shows it
    /// (Corner.swift).
    private func counted(_ label: String) -> String {
        guard name == nil else { return label }
        // A live folder's pull request: its own title, not the page's.
        if live != nil { return LiveGitHub.shortTitle(label) }
        // A kept tab: its short name (ShortNames.swift).
        if let short = ShortNames.shared.name(for: self) { return short }
        guard countCorner != nil else { return label }
        return Counts.untitled(label)
    }
}

// MARK: - born and grown

extension Browser {
    /// ⌘-click or the middle button: a tab after `source` and what it
    /// already opened, behind it unless ⇧ too, and with the folder switch
    /// on, from a results page or a page a search already gathered, into
    /// that search's folder.
    @discardableResult
    func openBeside(_ url: URL, from source: Tab?, foreground: Bool) -> Tab {
        let label = LinkStatus.shared.label(of: url, in: source?.id)
        let opened = open(url, foreground: foreground, from: source, linked: true, userLink: true)
        gatherSearch(opened, from: source)
        if !foreground { sayBehind(opened, url, label: label, from: source) }
        return opened
    }

    /// A tab just opened behind the page, whichever way it was asked for:
    /// with the tabs out of sight no row says so, and the corner does.
    func sayBehind(_ tab: Tab, _ url: URL, label: String? = nil, from source: Tab?) {
        guard tabsOutOfSight, source?.bench != true else { return }
        sayOpened(tab, url, label: label)
    }

    /// The corner naming it, Go There beside: the link's words when the
    /// pointer was on it, or else the page's title as soon as it has one,
    /// a second at most, or else its site. Said only while the tabs are
    /// still out of sight, and the tab still open and still behind.
    private func sayOpened(_ tab: Tab, _ url: URL, label: String?, waited: TimeInterval = 0) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if label == nil, tab.title.isEmpty, waited < 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak tab] in
                guard let self, let tab else { return }
                sayOpened(tab, url, label: nil, waited: waited + 0.1)
            }
            return
        }
        guard tabsOutOfSight, activeID != tab.id else { return }
        let name = label ?? (tab.title.isEmpty ? nil : tab.title)
        toaster.pop(Self.openedName(url, label: name) { Notice.headWidth($0) < Notice.longest }, stay: Toaster.undoable, undo: { [weak self, weak tab] in
            guard let self, let tab, tabs.contains(where: { $0 === tab }) else { return }
            select(tab)
        }, act: "Go There", page: tab)
    }

    /// Neither the column nor the strip across the top shows: put away by
    /// ⌘S and not out over the page. A tab opened behind the page then has
    /// no new row to say so, and the corner does (#239).
    var tabsOutOfSight: Bool {
        tabsAway && !(prefs.sidebar ? sidePeek : stripPeek)
    }

    /// What the corner calls a page opened in a tab behind this one: the
    /// link's own words, or else its site, cut to what `fits`.
    nonisolated static func openedName(_ url: URL, label: String?, fits: (String) -> Bool = { _ in true }) -> String {
        let said = label.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
        let site = url.host().map { IDN.shownAddress($0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0) }
        // An address for words, or none: the site reads better.
        let wordy = !said.isEmpty && !said.contains("://") && said.count <= 120
        var name = wordy ? said : site ?? LinkStatus.place(url)
        while !fits(name), name.count > 4 {
            name = String(name.dropLast(name.hasSuffix("\u{2026}") ? 2 : 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return name
    }

    /// A tab just opened from `source` with ⌘ or the middle button, with
    /// Settings › Tabs' switch on: into `source`'s search folder, after its
    /// last tab, or the start of one when `source` is a results page of its
    /// own, or any other page of today's (gatherLinks). From a pin or a kept
    /// tab, the second link on (gatherFromAbove). Never for an agent's tab
    /// or a pair's.
    func gatherSearch(_ tab: Tab, from source: Tab?) {
        guard prefs.linkFolders else { return }
        if let source, source.pin != nil || source.kept {
            gatherFromAbove(tab, from: source)
            return
        }
        guard let source, source !== tab, source.pin == nil, !source.kept, !source.bench,
              tab.pin == nil, !tab.kept, !tab.bench, tabs.contains(where: { $0 === source }) else { return }
        // From any folder of today's (a search's, one a ⌘-click made,
        // one you made): into it, after its last tab.
        if let nest = source.nest, nest.today {
            join(tab, nest)
            return
        }
        guard source.nest == nil, pair(of: source.id) == nil else { return }
        guard let address = source.address, let words = Engine.terms(of: address), !Research.declined(words, on: address) else {
            gatherLinks(tab, from: source)
            return
        }
        let nest = Nest(name: Research.name(words), open: true, search: words)
        nest.born = Date()
        nest.opened = true
        source.nest = nest
        tab.nest = nest
        // The new tab just after the results page, the folder's first two.
        if let at = tabs.firstIndex(where: { $0 === source }), let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
            move(tab, to: here > at ? at + 1 : at)
        }
        folderBook.born(nest)
        writeSession()
    }

    /// Any other page of today's, with Settings › Tabs' switch on, as Dia's
    /// "⌘-clicking links creates tab groups": the page and the tab it opened
    /// made a folder of today's where the page stood, open, named by the
    /// model on this Mac (LinkFolders); what is opened from either goes in
    /// after them, and it goes when one tab is left (Folders.settle). The
    /// rows move on Dia's spring.
    private func gatherLinks(_ tab: Tab, from source: Tab) {
        guard prefs.linkFolders else { return }
        let nest = Nest(name: "")
        nest.fleeting = true
        nest.linked = true
        nest.born = Date()
        LinkFolders.name(nest, in: self)
        ColumnMotion.next(.folder)
        source.nest = nest
        tab.nest = nest
        if let at = tabs.firstIndex(where: { $0 === source }), let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
            move(tab, to: here > at ? at + 1 : at)
        }
        folderBook.refresh()
        writeSession()
    }

    /// From a pin or a kept tab, with the switch on, as Dia's favorites
    /// (CmdClickFavoriteTabLinksGroupingController, measured 2026-10-16):
    /// the first ⌘-click opens a tab of today's as Arc's does, the second
    /// makes a folder of the two links, the pin or kept tab staying where it
    /// is; later ones join it.
    private func gatherFromAbove(_ tab: Tab, from source: Tab) {
        guard prefs.linkFolders, !source.bench, tab.pin == nil, !tab.kept, !tab.bench else { return }
        guard let earlier = tabs.last(where: { $0 !== tab && $0.linkedFrom == source.id && $0.pin == nil && !$0.kept }) else { return }
        if let nest = earlier.nest {
            if nest.today, !nest.research { join(tab, nest) }
            return
        }
        guard pair(of: earlier.id) == nil else { return }
        let nest = Nest(name: "")
        nest.fleeting = true
        nest.linked = true
        nest.born = Date()
        LinkFolders.name(nest, in: self)
        ColumnMotion.next(.folder)
        earlier.nest = nest
        tab.nest = nest
        if let at = tabs.firstIndex(where: { $0 === earlier }), let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
            move(tab, to: here > at ? at + 1 : at)
        }
        folderBook.refresh()
        writeSession()
    }

    /// Into the folder, after its last tab: what a search found stays in the
    /// order it was opened. A ⌘-click folder keeps Arc's order inside it
    /// (docs/tab-placement.md): a link's own link right after that link, as
    /// it landed; the page's next after its last, the folder's end, as Dia's.
    private func join(_ tab: Tab, _ nest: Nest) {
        tab.nest = nest
        let others = tabs.filter { $0 !== tab && $0.nest === nest }
        let inside: Bool = {
            guard !nest.research, let first = others.first, let last = others.last,
                  let from = tabs.firstIndex(where: { $0 === first }), let to = tabs.firstIndex(where: { $0 === last }),
                  let here = tabs.firstIndex(where: { $0 === tab }) else { return false }
            return here > from && here <= to + 1
        }()
        if !inside, let last = others.last, let at = tabs.firstIndex(where: { $0 === last }),
           let here = tabs.firstIndex(where: { $0 === tab }), here != at + 1 {
            move(tab, to: here > at ? at + 1 : at)
        }
        if !nest.research { ColumnMotion.next(.folder) }
        folderBook.refresh()
        writeSession()
    }

    /// ⌥⇧-click on a tab's row, with Settings › Tabs' switch on, as Dia's
    /// "⌥-⇧-click opens tab in group" (measured 2026-10-20 on Dia 1.52,
    /// docs/link-folders.md): the page in front in a folder, the tab joins
    /// it after its last; in none, the two become a folder of their own at
    /// the end of the kept (Dia puts it at the end of its pinned), the page
    /// in front first, named as a ⌘-click's is. The rows move on Dia's
    /// spring. Neither leaves the page in front. False when it can't be
    /// done (a pin, the page in front itself, an agent's tab): the click
    /// opens the tab as a plain one would.
    func groupClick(_ tab: Tab) -> Bool {
        if startsArranging { return arranging { groupClick(tab) } }
        guard let page = active, page !== tab, tab.keepable, page.keepable, tab.agent == nil, page.agent == nil else { return false }
        cancelTabEdit()
        if let nest = page.nest {
            guard tab.nest !== nest else { return true }
            ColumnMotion.next(.folder)
            if nest.today {
                tab.kept = false
                join(tab, nest)
            } else {
                keepTabs([tab], in: nest)
            }
            return true
        }
        let nest = Nest(name: "")
        nest.linked = true
        nest.born = Date()
        ColumnMotion.next(.folder)
        keepTabs([page, tab], in: nest, at: tabs.filter(\.kept).filter { $0 !== page && $0 !== tab }.count)
        // The page in front first, as Dia's.
        if let at = tabs.firstIndex(where: { $0 === page }), let here = tabs.firstIndex(where: { $0 === tab }), here < at {
            move(tab, to: at)
        }
        LinkFolders.name(nest, in: self)
        folderBook.refresh()
        writeSession(now: true)
        return true
    }

    /// The results page searched again: words alike keep the folder, renamed
    /// to them; words of another inquiry take the page out of it, the rest
    /// staying together, and it may start a folder of its own.
    func searched(_ tab: Tab) {
        guard let nest = tab.nest, let before = nest.search, let address = tab.address,
              let words = Engine.terms(of: address), words != before else { return }
        // Only the page the folder grew from, its first.
        guard tabs.first(where: { $0.nest === nest }) === tab else { return }
        if Research.alike(before, words) {
            let named = nest.name == Research.name(before)
            nest.search = words
            if named { nest.name = Research.name(words) }
        } else {
            tab.nest = nil
            folderBook.refresh()
        }
        writeSession()
    }

    /// Ungroup, a search's folder: its tabs stay where they are, today's.
    /// Twice for searches that begin the same on the same engine, and such
    /// searches aren't gathered again until yab starts over.
    func ungroupSearch(_ nest: Nest) {
        if startsArranging { return arranging { ungroupSearch(nest) } }
        if let words = nest.search, let first = tabs.first(where: { $0.nest === nest })?.address {
            Research.ungrouped(words, on: first)
        }
        ungroup(nest)
    }
}

extension Research {
    /// Searches ungrouped this run, by engine and first word, and how often.
    @MainActor private static var refused: [String: Int] = [:]

    private static func refusal(_ words: String, on url: URL) -> String {
        (url.host() ?? "") + " " + (Self.words(words).first ?? words.lowercased())
    }

    @MainActor static func ungrouped(_ words: String, on url: URL) {
        refused[refusal(words, on: url), default: 0] += 1
    }

    @MainActor static func declined(_ words: String, on url: URL) -> Bool {
        (refused[refusal(words, on: url)] ?? 0) >= 2
    }
}
