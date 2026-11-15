import Foundation

struct BoostContributions {
    let commands: [[String: String]]
    let actions: [[String: String]]
    let routines: [[String: String]]

    static func read(_ files: [String: String], sites: [String]) throws -> BoostContributions {
        guard let source = files["commands.json"] else { return .init(commands: [], actions: [], routines: []) }
        guard let value = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
              Set(value.keys).isSubset(of: ["commands", "actions", "routines"]) else { throw BoostPackage.Invalid("commands.json needs commands, actions and routines arrays.") }
        func rows(_ key: String) throws -> [[String: String]] {
            guard value[key] != nil else { return [] }
            guard let rows = value[key] as? [[String: String]], rows.count <= 10 else { throw BoostPackage.Invalid("Use at most ten \(key).") }
            var ids = Set<String>()
            for row in rows {
                guard let id = row["id"], id == BoostPackage.slug(id), !id.isEmpty, ids.insert(id).inserted,
                      let name = row["name"], !name.isEmpty, name.count <= 80 else { throw BoostPackage.Invalid("Every contribution needs a unique id and short name.") }
                if key != "actions" {
                    guard let prompt = row["prompt"], !prompt.isEmpty, prompt.count <= 8000, !prompt.contains("{memory}") else { throw BoostPackage.Invalid("A command or routine needs a prompt without the whole-memory template.") }
                } else {
                    guard let text = row["url"], let url = URL(string: text), url.scheme == "https", sites.contains(url.host ?? "") else { throw BoostPackage.Invalid("Quick actions must open a declared HTTPS site.") }
                }
                if key == "routines", row["when"].flatMap(Routines.schedule) == nil { throw BoostPackage.Invalid("A routine needs when.") }
            }
            return rows
        }
        return try .init(commands: rows("commands"), actions: rows("actions"), routines: rows("routines"))
    }

    /// Called by Skills' disk cache, also usable by the headless CLI. Plugin
    /// skills cannot mark POST requests as safe reads or shadow built-ins.
    static func skills() -> [Skills.Skill] {
        let library = BoostLibrary(root: Store.file("boosts"))
        let records = ((try? library.records()) ?? []).filter(\.enabled)
        let contributed = records.flatMap { record -> [Skills.Skill] in
            guard let files = try? library.files(record.id) else { return [] }
            return files.keys.sorted().filter { $0.hasPrefix("skills/") && $0.hasSuffix("/SKILL.md") }.compactMap { path in
                let location = library.folder(record.id).appendingPathComponent(path)
                guard let skill = Skills.parse(files[path]!, own: true, path: location) else { return nil }
                let name = record.id + ":" + skill.name
                let actions = skill.actions.map { Skills.Action(title: $0.title, pattern: $0.pattern, prompt: $0.prompt, skill: name, draft: $0.draft) }
                return Skills.Skill(name: name, description: "\(record.name): \(skill.description)", sites: record.sites,
                                    keywords: skill.keywords, body: skill.body, own: true, path: location, actions: actions)
            }
        }
        let tools = records.compactMap { record -> String? in
            guard let files = try? library.files(record.id), let package = try? BoostPackage.read(id: record.id, files: files, sites: record.sites), !package.plugin.tools.isEmpty else { return nil }
            return package.plugin.tools.map { "- " + package.id + "." + $0.name + ": " + $0.description + " on " + package.sites.joined(separator: ", ") + ($0.acts.map { " (" + $0 + "; requires approval)" } ?? "") }.joined(separator: "\n") + package.examples.map { "\n  Example (data): " + BoostScript.json($0.ask) + " → " + package.id + "." + $0.tool + " " + $0.arguments }.joined()
        }
        guard !tools.isEmpty else { return contributed }
        let installed = Skills.Skill(name: "installed", description: "Tools provided by your kept plugins.", sites: Array(Set(records.flatMap(\.sites))).sorted(),
                                     keywords: ["plugin", "tools"], body: "# Installed plugin tools\n\nOpen the named site in your task to expose its tools over MCP. The CLI also supports yab <plugin> <tool> '<JSON>'. Never use a write tool without the native action approval.\n\n" + tools.joined(separator: "\n"), own: true, path: library.index)
        return [installed] + contributed
    }

    static func pluginID(_ contribution: String) -> String? {
        let parts = contribution.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "boost" ? String(parts[1]) : nil
    }
    @MainActor static func charge(_ contribution: String) throws {
        guard let id = pluginID(contribution) else { return }
        guard Boosts.shared.isEnabled(id), let package = Boosts.shared.packages[id] else { throw BoostPackage.Invalid("This plugin is turned off or was removed.") }
        try BoostAI.shared.charge(package)
    }

    private struct Choices: Codable {
        var commands: [String: SelectionCommand] = [:]
        var actions: [String: QuickAction] = [:]
        var routines: [String: Routine] = [:]
    }
    private static var choicesFile: URL { Store.file("boosts/choices.json") }
    private static func choices() -> Choices { (try? JSONDecoder().decode(Choices.self, from: Data(contentsOf: choicesFile))) ?? Choices() }
    private static func save(_ choices: Choices) {
        do {
            try FileManager.default.createDirectory(at: choicesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(choices).write(to: choicesFile, options: .atomic)
        } catch { NSLog("yab: could not preserve plugin command preferences") }
    }
    static func forget(_ id: String) {
        var kept = choices(); let prefix = "boost:" + id + ":"
        kept.commands = kept.commands.filter { !$0.key.hasPrefix(prefix) }
        kept.actions = kept.actions.filter { !$0.key.hasPrefix(prefix) }
        kept.routines = kept.routines.filter { !$0.key.hasPrefix(prefix) }
        save(kept)
    }

    @MainActor static func reconcile() {
        let prefix = "boost:"
        var kept = choices()
        for browser in BrowserWindows.shared.browsers {
            for item in browser.selectionCommands.commands where item.id.hasPrefix(prefix) { kept.commands[item.id] = item }
        }
        for item in QuickActions.shared.actions where item.id.hasPrefix(prefix) { kept.actions[item.id] = item }
        for item in Routines.shared.all where item.id.hasPrefix(prefix) { kept.routines[item.id] = item }
        save(kept)
        let packages = Boosts.shared.records.filter { Boosts.shared.isEnabled($0.id) }.compactMap { Boosts.shared.packages[$0.id] }
        var commands: [SelectionCommand] = [], actions: [QuickAction] = [], routines: [Routine] = []
        for package in packages {
            guard let parsed = try? read(package.files, sites: package.sites) else { continue }
            for row in parsed.commands {
                commands.append(SelectionCommand(id: prefix + package.id + ":" + row["id"]!, name: row["name"]! + " · " + package.name,
                                                 prompt: row["prompt"]!, executor: "agent", custom: true, site: package.sites.first ?? ""))
            }
            for row in parsed.actions {
                actions.append(QuickAction(id: prefix + package.id + ":" + row["id"]!, name: row["name"]! + " · " + package.name,
                                           url: row["url"]!, alias: package.id + "-" + row["id"]!, custom: true))
            }
            for row in parsed.routines {
                var routine = Routine(id: prefix + package.id + ":" + row["id"]!, when: row["when"]!, prompt: row["prompt"]!,
                                      title: row["name"]! + " · " + package.name, tabs: package.sites.map { "https://" + $0 + "/" }, may: "read", tell: "found")
                // Each Mac makes these from its own plugins (they don't sync
                // as routines), and runs them only where the plugin ticks.
                routine.runsOn = Boosts.shared.records.first { $0.id == package.id }.map { $0.runsHere ? SyncCenter.deviceID : $0.runsOn } ?? nil
                routines.append(routine)
            }
        }
        for browser in BrowserWindows.shared.browsers {
            let old = kept.commands
            browser.selectionCommands.commands.removeAll { $0.id.hasPrefix(prefix) }
            browser.selectionCommands.commands += commands.map { command in
                var command = command
                if let previous = old[command.id] {
                    command.enabled = previous.enabled; command.shortcut = previous.shortcut
                    command.model = previous.model; command.effort = previous.effort
                    command.result = previous.result
                }
                return command
            }
            browser.selectionCommands.save()
        }
        let wantedActions = Set(actions.map(\.id))
        for action in QuickActions.shared.actions where action.id.hasPrefix(prefix) && !wantedActions.contains(action.id) { QuickActions.shared.remove(action.id) }
        for var action in actions {
            if let old = kept.actions[action.id] { action.enabled = old.enabled; action.shortcut = old.shortcut }
            _ = QuickActions.shared.put(action)
        }
        let wantedRoutines = Set(routines.map(\.id))
        for routine in Routines.shared.all where routine.id.hasPrefix(prefix) && !wantedRoutines.contains(routine.id) { Routines.shared.remove(routine.id) }
        for var routine in routines {
            if let old = kept.routines[routine.id] {
                routine.last = old.last; routine.off = old.off; routine.chat = old.chat; routine.session = old.session
                routine.cli = old.cli; routine.model = old.model; routine.effort = old.effort
                routine.said = old.said; routine.found = old.found; routine.ended = old.ended
            }
            _ = Routines.shared.put(routine)
        }
        Skills.reload()
    }
}
