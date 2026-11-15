import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Boosts, plugins' tools and
// skills.

extension Bench {
    static let boostsVerbs: [String: AgentHandler] = [
        "agent-plugin-tools": { $0.handleAgentPluginTools($1) },
        "agent-plugin-call": { $0.handleAgentPluginCall($1) },
        "agent-boosts": { $0.handleAgentBoosts($1) },
        "agent-boost-read": { $0.handleAgentBoostRead($1) },
        "agent-boost": { $0.handleAgentBoost($1) },
        "agent-skills": { $0.handleAgentSkills($1) },
        "agent-skill": { $0.handleAgentSkill($1) },
        "agent-skill-save": { $0.handleAgentSkillSave($1) },
    ]

    func handleAgentPluginTools(_ c: AgentCall) {
        let answer = c.answer
        let session = c.session
        answer(["tools": BoostTools.list(session: session)])
    }

    func handleAgentPluginCall(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let session = c.session
        guard let session else { answer(["error": "A plugin call needs its task session."]); return }
        Task {
            answer(await BoostTools.run(request["name"] as? String ?? "", arguments: request["arguments"] as? [String: Any] ?? [:],
                                        requestID: request["requestID"] as? String ?? UUID().uuidString, session: session, browser: browser))
        }
    }

    func handleAgentBoosts(_ c: AgentCall) {
        let answer = c.answer
        answer(["boosts": Boosts.shared.records.map { record -> [String: Any] in
            ["name": record.id, "title": record.name, "rung": record.rung.rawValue,
             "sites": record.sites, "enabled": record.enabled, "failures": record.failures]
        }])
    }

    func handleAgentBoostRead(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let session = c.session
        do { answer(["files": try Boosts.shared.files(request["name"] as? String ?? "", session: session)]) }
        catch { answer(["error": error.localizedDescription]) }
    }

    func handleAgentBoost(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let session = c.session
        func own(going: Bool = false, asking: Bool = false) -> Tab? { c.own(going: going, asking: asking) }
        // A repair tries in its own tab, as before; every other boost
        // quietly, in a page of Yab's own (Boosts.fit).
        let repair = Boosts.shared.isRepairing(session)
        guard let session else { answer(["error": "boost needs its task's session"]); return }
        guard let tab = repair ? own() : find(request, in: browser) else { if !repair { answer(missing(request)) }; return }
        guard let name = request["name"] as? String, let files = request["files"] as? [String: Any],
              let sites = request["sites"] as? [String] else { answer(["error": "boost needs name, files and sites"]); return }
        Task {
            do {
                answer(repair ? try await Boosts.shared.stage(name: name, changes: files, sites: sites, tab: tab, session: session)
                       : try await Boosts.shared.fit(name: name, changes: files, sites: sites, from: tab, session: session, pages: request["pages"] as? [String] ?? []))
            } catch { answer(["error": error.localizedDescription]) }
        }
    }

    func handleAgentSkills(_ c: AgentCall) {
        let answer = c.answer
        answer(["text": Skills.index(query: c.request["query"] as? String)])
    }

    func handleAgentSkill(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard let skill = Skills.named(request["name"] as? String ?? "") else {
            answer(["error": "no skill “\(request["name"] as? String ?? "")”, there are: \(Skills.all().map(\.name).joined(separator: ", "))"])
            return
        }
        agents.touch(session, "skill · \(skill.name)")
        var said: [String: Any] = ["text": "# \(skill.name)\n\n\(skill.body)"]
        // The whole SKILL.md and its revision only where skill_save can
        // write: the user's folder, or a built-in a user copy may replace.
        // A plugin's skills (and the installed tools list, whose path is
        // the plugins' index.json) are read as their body alone.
        let yours = skill.own && skill.path.path.hasPrefix(Skills.mine.path + "/")
        if (yours || !skill.own), skill.path.lastPathComponent == "SKILL.md",
           let document = try? String(contentsOf: skill.path, encoding: .utf8) {
            said["document"] = document
            said["revision"] = SkillWriter.revision(document)
        }
        said["own"] = yours
        answer(said)
    }

    /// skill_save: checked, then on the card with its words and whether it
    /// replaces a built-in, and written only after the user's yes. Never in
    /// Bypass without it: a skill lasts into every later task.
    func handleAgentSkillSave(_ c: AgentCall) {
        let answer = c.answer
        guard let id = c.session, let session = c.agents.session(id), session.state.live,
              session.parent == nil, !session.quiet, !session.sealed, !session.unattended else {
            answer(["error": "Only the user's active main task can save skills."])
            return
        }
        let name = c.request["name"] as? String ?? "", document = c.request["document"] as? String ?? ""
        let replacing = c.request["replacing"] as? String
        do {
            try SkillWriter.check(name: name, document: document, replacing: replacing, in: Skills.mine)
            let key = SkillWriter.key(name: name, document: document)
            // The card stands on the task's own latest tab, or the one in front.
            let mine = c.agents.tabs(of: session).last
            guard let tab = mine ?? c.browser.active.flatMap({ $0.shy ? nil : $0 }) else {
                answer(["error": "no tab to ask in; say in your answer what you would save"])
                return
            }
            let yes = tab.approved.map { $0.session == id && $0.ref == key && Date().timeIntervalSince($0.at) < 120 } ?? false
            guard yes else {
                if tab.declined.remove(id) != nil {
                    answer(["error": "the person said not now to that skill: don't save it another way; say so in your answer"])
                    return
                }
                if tab.permit == nil {
                    c.agents.ask(tab, AgentPermit(kind: .saveSkill(name: name, key: key), session: id,
                                                  detail: SkillWriter.replaces(name, in: Skills.mine, builtIn: Skills.builtIn),
                                                  draft: document))
                }
                answer(["error": "saving a skill waits for the person's yes; asking them now", "asking": true, "tab": Bench.short(tab)])
                return
            }
            tab.approved = nil
            let file = try SkillWriter.save(name: name, document: document, replacing: replacing, in: Skills.mine)
            SkillShelf.shared.reload()
            c.agents.touch(id, "skill saved · \(name)")
            answer(["path": file.path, "revision": SkillWriter.revision(document), "saved": true])
        } catch { answer(["error": error.localizedDescription]) }
    }
}
