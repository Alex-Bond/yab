import AppKit
import WebKit

// Bench.agentCommand's verbs (AgentBench). Memory, the profile for forms,
// form answers and what getting to know the person keeps.

extension Bench {
    static let memoryVerbs: [String: AgentHandler] = [
        "agent-memory-search": { $0.handleAgentMemorySearch($1) },
        "agent-memory-read": { $0.handleAgentMemoryRead($1) },
        "agent-profile": { $0.handleAgentProfile($1) },
        "agent-form-answers": { $0.handleAgentFormAnswers($1) },
        "agent-keep-address": { $0.handleAgentKeepAddress($1) },
        "agent-know-report": { $0.handleAgentKnowReport($1) },
        "agent-memory-write": { $0.handleAgentMemoryWrite($1) },
    ]

    func handleAgentMemorySearch(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        let queries = request["queries"] as? [String] ?? [request["query"] as? String ?? ""]
        let hits = Memory.search(queries, limit: request["max"] as? Int ?? 8, mail: agents.mailed(session))
        agents.touch(session, "recall")
        answer(["hits": hits.map { ["file": $0.file, "line": $0.line, "text": $0.text] }, "folder": Memory.folder.path])
    }

    func handleAgentMemoryRead(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        let name = request["file"] as? String ?? "MEMORY"
        if let body = Memory.read(name, mail: agents.mailed(session)) { answer(["text": body]) }
        else { answer(["text": "", "files": Memory.files(mail: agents.mailed(session))]) }
    }

    func handleAgentProfile(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // The profile forms are filled from (Profile): read, or written
        // key by key from the user's own pages.
        // What the person wrote themselves stays theirs.
        if let set = request["set"] as? [String: Any], !set.isEmpty {
            guard browser.prefs.agentsRemember else { answer(["error": "the user has asked agents not to remember"]); return }
            // Written by getting to know the person, yab's own quiet passes
            // (memory, the weekly look), the person's own agent in a
            // terminal, or a task the person asked about their profile:
            // not by any task a page could talk into it.
            let known = agents.session(session)
            let may = known.map { $0.knowing || $0.quiet || $0.cli == "external" || $0.prompt.lowercased().contains("profile") } ?? true
            guard may else {
                answer(["error": "the profile is written while getting to know the user, or when they ask for it: say in your answer what you would change"])
                return
            }
            let unknown = set.keys.filter { !Profile.keys.contains($0) }
            guard unknown.isEmpty else { answer(["error": "no such keys: \(unknown.sorted().joined(separator: ", ")); the keys are \(Profile.keys.joined(separator: ", "))"]); return }
            var profile = Profile.load()
            let given = set.compactMapValues { $0 as? String }
            let from = (request["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
            guard let known, known.state.live, ContextPrivacy.shared.current(known.memoryEpoch) else { answer(["error": "This task can no longer keep context."]); return }
            let result: (changed: [String], kept: [String])
            if known.knowing {
                guard let grant = known.contextGrant, let kept = ContextPrivacy.shared.profilePatch(given, source: from, grant: grant) else { answer(["error": "This context permission expired."]); return }
                result = kept
                profile = Profile.load()
            } else {
                result = ContextPrivacy.shared.transaction {
                    var latest = Profile.load()
                    let result = latest.merge(given, source: from)
                    if !result.changed.isEmpty { _ = Profile.save(latest) }
                    return result
                }
                profile = Profile.load()
            }
            agents.touch(session, "profile")
            answer(["profile": profile.said, "changed": result.changed, "kept": result.kept])
            return
        }
        answer(["profile": Profile.load().said])
    }

    func handleAgentFormAnswers(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Answers forms kept on their own (FormAnswers): read by any
        // agent, as the profile is; looked over only by yab's own quiet
        // passes (the morning look) or the person's own agent.
        let drop = Set(request["drop"] as? [String] ?? []), keep = Set(request["keep"] as? [String] ?? [])
        if !drop.isEmpty || !keep.isEmpty {
            let known = agents.session(session)
            guard known.map({ $0.quiet || $0.cli == "external" }) ?? true else {
                answer(["error": "saved answers are looked over by yab's own morning look: say in your answer what you would drop"])
                return
            }
            let result = FormAnswers.review(drop: drop, keep: keep)
            agents.touch(session, "form_answers")
            answer(["dropped": result.dropped, "kept": result.kept, "left": FormAnswers.unchecked().count])
            return
        }
        answer(["answers": FormAnswers.unchecked().map { ["id": $0.id, "site": $0.site, "question": $0.question, "answer": $0.answer] }])
    }

    func handleAgentKeepAddress(_ c: AgentCall) {
        let browser = c.browser
        let request = c.request
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // Home or work, into the Wallet with no question: only while
        // getting to know the user, the task they started themselves.
        guard let known = agents.session(session), known.knowing, known.state.live,
              browser.prefs.agentsRemember, let grant = known.contextGrant, ContextPrivacy.shared.valid(grant) else {
            answer(["error": "keep_address is only for getting to know the user (Get to know me)"])
            return
        }
        func field(_ key: String) -> String { (request[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var address = StreetAddress(id: UUID().uuidString)
        address.name = field("name")
        address.organization = field("organization")
        address.street = field("street")
        address.city = field("city")
        address.region = field("region")
        address.postal = field("postal")
        address.country = field("country")
        address.phone = field("phone")
        address.email = field("email")
        let kind = field("kind").lowercased() == "work" ? "work" : "home"
        address.source = "Get to know me, \(kind)"
        if !field("found").isEmpty { address.found = String(field("found").prefix(80)) }
        guard address.whole else { answer(["error": "an address needs its street and its city or postal code"]); return }
        guard !known.kept.contains(kind) else {
            answer(["error": "a \(kind) address was already kept in this pass and it stands; if you found a different one, mention it in your answer"])
            return
        }
        known.kept.insert(kind)
        let admission = known.admission
        DispatchQueue.global(qos: .userInitiated).async {
            ContextPrivacy.shared.transaction {
            guard admission.valid, ContextPrivacy.shared.valid(grant) else { DispatchQueue.main.async { answer(["error": "This context was cleared."]) }; return }
            if var same = Wallet.addresses().first(where: { $0.same(as: address) }) {
                // Kept already, from another browser or by hand: now
                // their home (or work) too, with where it was found and
                // what the copy lacked (docs/get-to-know.md).
                same.source = address.source
                if let found = address.found { same.found = found }
                for field in [\StreetAddress.phone, \.email, \.region, \.country, \.organization, \.city, \.postal] where same[keyPath: field].isEmpty {
                    same[keyPath: field] = address[keyPath: field]
                }
                let ok = Wallet.save(same, origin: .learned(grant))
                DispatchQueue.main.async {
                    agents.touch(session, "wallet")
                    answer(ok ? ["ok": true, "said": "Already in the Wallet: \(same.title). Kept it as their \(kind) address."] : ["error": "the keychain didn't take it"])
                }
                return
            }
            let ok = Wallet.save(address, origin: .learned(grant))
            DispatchQueue.main.async {
                agents.touch(session, "wallet")
                answer(ok ? ["ok": true, "said": "Kept the \(kind) address \(address.title) in the Wallet."] : ["error": "the keychain didn't take it"])
            }
            }
        }
    }

    func handleAgentKnowReport(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        // What the notes page shows beside the stores (KnowPage): only
        // getting to know the user writes it, the task they started.
        guard let known = agents.session(session), known.knowing, known.state.live, !known.quiet,
              let grant = known.contextGrant, ContextPrivacy.shared.valid(grant) else {
            answer(["error": "know_report is only for getting to know the user (Get to know me)"])
            return
        }
        guard browser.prefs.agentsRemember else { answer(["error": "the user has asked agents not to remember"]); return }
        var report = KnowReport.given(request)
        report.minutes = max(1, Int((Date().timeIntervalSince(known.began) / 60).rounded()))
        report.sites = known.seen.count
        guard ContextPrivacy.shared.transaction({ ContextPrivacy.shared.valid(grant) && KnowReport.save(report) }) else { answer(["error": "This context was cleared."]); return }
        // The faces it saw, fetched by Yab and kept beside each person's page.
        KnowFaces.keep(request["photos"] as? [[String: Any]] ?? [], grant: grant)
        agents.touch(session, "know_report")
        answer(["ok": true, "said": "Kept for their notes page: \(report.story.count) paragraph\(report.story.count == 1 ? "" : "s"), \(report.setups.count) thing\(report.setups.count == 1 ? "" : "s") to set up, \(report.doubts.count) question\(report.doubts.count == 1 ? "" : "s"), \(report.left.count) left alone, \(report.skipped.count) skipped."])
    }

    func handleAgentMemoryWrite(_ c: AgentCall) {
        let request = c.request
        let browser = c.browser
        let answer = c.answer
        let agents = c.agents
        let session = c.session
        guard agents.session(session)?.cli != nil || session == nil else { answer(["error": "no session"]); return }
        guard browser.prefs.agentsRemember else { answer(["error": "the user has asked agents not to remember"]); return }
        guard let known = agents.session(session), (known.state.live || known.remembering), ContextPrivacy.shared.current(known.memoryEpoch) else { answer(["error": "This task can no longer keep context."]); return }
        let admission = known.admission
        if known.remembering, !(request["file"] as? String ?? "").hasPrefix("episodic/") {
            answer(["error": "This extraction may only add to the episodic log."]); return
        }
        agents.touch(session, "remember")
        let trouble = ContextPrivacy.shared.transaction { () -> String? in
            guard admission.valid else { return "This context was cleared." }
            return Memory.write(request["file"] as? String ?? "memory", text: request["text"] as? String ?? "", replacing: request["replacing"] as? String,
                                   mail: agents.mailed(session))
        }
        answer(trouble.map { ["error": $0] } ?? ["ok": true])
    }
}
