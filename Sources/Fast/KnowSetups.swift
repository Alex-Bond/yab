import Foundation

// Set up for you, on yab://you (docs/get-to-know.md, Set up for you): what
// Yab can set up from what Get to Know read, each with why, and Add, Not Now
// and Undo. The run's own ideas are kept in its report (KnowReport.setups);
// beside them the ones Yab already finds in history, a Quick Action you make
// things with and a routine for a site you open daily, kept here as you
// answer them. Add makes the thing as Settings would, and the page says
// where it went; Not Now puts it away on this page only.
@MainActor
enum KnowSetups {
    /// The local ideas you've answered, and what Add made of each.
    private static let keptKey = "know.setups.local"

    /// What the page offers, in order, each as the page draws it.
    static func offered(_ report: KnowReport?) -> [[String: Any]] {
        var rows = (report?.setups ?? []).map(row)
        var said = Set((report?.setups ?? []).map(key))
        for setup in kept() where said.insert(key(setup)).inserted { rows.append(row(setup)) }
        for setup in local() where said.insert(key(setup)).inserted { rows.append(row(setup)) }
        return rows
    }

    /// The same thing offered twice, once by the run and once by history, is one offer.
    private static func key(_ setup: KnowReport.Setup) -> String {
        switch setup.kind {
        case "action": return "action:" + (setup.what["maker"] ?? setup.what["alias"] ?? setup.title)
        case "live": return "live:" + (setup.what["repo"] ?? setup.what["source"] ?? setup.title)
        case "routine": return "routine:" + (setup.what["site"] ?? setup.title)
        default: return setup.kind + ":" + setup.title
        }
    }

    private static func row(_ setup: KnowReport.Setup) -> [String: Any] {
        var out: [String: Any] = ["id": setup.id, "kind": setup.kind, "title": setup.title, "why": setup.why, "from": setup.from,
                                  "state": setup.state ?? ""]
        if setup.state == "added" { out["where"] = setup.what["made.where"] ?? "" }
        return out
    }

    // MARK: what history already says

    private static func kept() -> [KnowReport.Setup] {
        guard let data = Store.settings.data(forKey: keptKey) else { return [] }
        return (try? JSONDecoder().decode([KnowReport.Setup].self, from: data)) ?? []
    }

    private static func keep(_ list: [KnowReport.Setup]) {
        Store.settings.set(try? JSONEncoder().encode(list), forKey: keptKey)
    }

    /// Quick Actions history suggests, and routines for the sites you open
    /// most, as offers; the ones you've answered here are in `kept`.
    private static func local() -> [KnowReport.Setup] {
        var out: [KnowReport.Setup] = []
        for suggestion in QuickActions.shared.suggestions.prefix(2) where suggestion.replacing == nil {
            out.append(KnowReport.Setup(id: "local:action:" + suggestion.id, kind: "action",
                                        title: "\(suggestion.alias) opens \(suggestion.name)", why: suggestion.detail, from: "",
                                        what: ["suggestion": suggestion.id, "alias": suggestion.alias, "name": suggestion.name, "url": suggestion.url]))
        }
        for idea in RoutineIdeas.shared.offered(Routines.shared.all).prefix(2) where idea.id != RoutineIdea.anyone.id {
            out.append(KnowReport.Setup(id: "local:routine:" + idea.id, kind: "routine", title: idea.title,
                                        why: idea.site.map { "You open \($0) most days" } ?? "",
                                        from: "", what: ["when": idea.when, "prompt": idea.task, "title": idea.title, "site": idea.site ?? ""]))
        }
        return out
    }

    // MARK: answering

    /// Add, Not Now, or Undo of either. What Add made is kept with the offer,
    /// so Undo takes it away again; the words for where it went, or nil
    /// when it couldn't be made.
    static func answer(_ id: String, _ act: String, in browser: Browser?) -> String? {
        if id.hasPrefix("local:") {
            var list = kept()
            guard var found = list.first(where: { $0.id == id }) ?? local().first(where: { $0.id == id }) else { return nil }
            let said = apply(&found, act, in: browser)
            list.removeAll { $0.id == id }
            if found.state != nil { list.append(found) }
            keep(list)
            return said
        }
        guard var report = KnowReport.load(), let at = report.setups.firstIndex(where: { $0.id == id }) else { return nil }
        let said = apply(&report.setups[at], act, in: browser)
        KnowReport.save(report)
        return said
    }

    private static func apply(_ setup: inout KnowReport.Setup, _ act: String, in browser: Browser?) -> String? {
        switch act {
        case "add":
            guard setup.state == nil, let made = make(setup, in: browser) else { return nil }
            setup.state = "added"
            setup.what["made.id"] = made.id
            setup.what["made.where"] = made.where
            return made.where
        case "away":
            guard setup.state == nil else { return nil }
            setup.state = "away"
            return ""
        case "undo":
            if setup.state == "added" { unmake(setup, in: browser) }
            setup.state = nil
            setup.what["made.id"] = nil
            setup.what["made.where"] = nil
            return ""
        default:
            return nil
        }
    }

    /// The thing made, as Settings or a native action makes it: its id, to
    /// take it away again, and where it is now in words.
    private static func make(_ setup: KnowReport.Setup, in browser: Browser?) -> (id: String, where: String)? {
        let what = setup.what
        switch setup.kind {
        case "live":
            guard let browser, Folders.shared.browser === browser else { return nil }
            let nest: Nest?
            if let repo = what["repo"], !repo.isEmpty { nest = LiveFolders.shared.followRepo(repo, in: browser) }
            else { nest = LiveFolders.shared.make(what["source"] ?? "github.pulls", in: browser, name: what["name"]) }
            guard let nest else { return nil }
            return (nest.id.uuidString, "In your sidebar, under your pins")
        case "action":
            if let id = what["suggestion"], let suggestion = QuickActions.shared.suggestion(id) {
                QuickActions.shared.accept(suggestion)
                return (id, "Type \(suggestion.alias) in ⌘T")
            }
            guard let maker = Maker.all.first(where: { $0.id == what["maker"] }), let action = maker.action else { return nil }
            let alias = what["alias"].map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.flatMap { $0.isEmpty ? nil : $0 } ?? action.alias
            QuickActions.shared.accept(QuickActionSuggestion(id: action.id, name: action.name, detail: "", url: maker.url, alias: alias))
            let kept = QuickActions.shared.actions.first { $0.id == action.id }?.alias ?? alias
            return (action.id, "Type \(kept) in ⌘T")
        case "routine":
            guard let when = what["when"], Routines.schedule(when) != nil, let prompt = what["prompt"], !prompt.isEmpty else { return nil }
            var routine = Routine(id: Routines.newID("know"), when: when, prompt: prompt, last: nil, title: what["title"] ?? setup.title)
            if let site = what["site"], !site.isEmpty { routine.tabs = ["https://" + site] }
            guard case .success(let made) = Routines.shared.put(routine) else { return nil }
            return (made.id, "Runs \(when), in Settings › AI › Routines")
        case "snippet":
            guard let words = what["words"], !words.isEmpty else { return nil }
            let name = MailSnippets.shared.freeName((what["name"] ?? "").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" })
            let snippet = MailSnippets.shared.add(name: name, body: words, mailOnly: false)
            return (snippet.id, "Type ;\(snippet.name) in any field")
        case "space":
            guard let browser, let name = what["name"], !name.isEmpty else { return nil }
            browser.prefs.usesSpaces = true
            let space = browser.addSpace(named: name, ownSignIns: what["ownSignIns"] == "true", show: false)
            return (space.uuidString, "A new space, \(name), at the column’s foot")
        default:
            return nil
        }
    }

    private static func unmake(_ setup: KnowReport.Setup, in browser: Browser?) {
        guard let id = setup.what["made.id"] else { return }
        switch setup.kind {
        case "live":
            guard let browser, let nest = browser.nests.first(where: { $0.id.uuidString == id }) else { return }
            let tabs = browser.tabs.filter { $0.nest === nest }
            LiveFolders.shared.stop(nest, in: browser)
            browser.ungroup(nest)
            for tab in tabs { browser.close(tab) }
        case "action":
            QuickActions.shared.remove(id)
        case "routine":
            _ = Routines.shared.remove(id)
        case "snippet":
            MailSnippets.shared.remove(id)
        case "space":
            guard let browser, let space = UUID(uuidString: id) else { return }
            browser.deleteSpace(space)
        default:
            break
        }
    }
}
