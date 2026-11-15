import Foundation

// The bench's words for assistants in the cloud (docs/assistants.md): what
// one may do, the approval a call is waiting on, and asking the user for
// more. `yab mcp --assistant` speaks these; `agent-assistants` drives the
// linking a test would otherwise type in Settings.

extension Bench {
    static let assistantVerbs: [String: AgentHandler] = [
        "agent-assistant": { $0.handleAgentAssistant($1) },
        "agent-approval": { $0.handleAgentApproval($1) },
        "agent-approval-wait": { $0.handleAgentApprovalWait($1) },
        "agent-access-request": { $0.handleAgentAccessRequest($1) },
        "agent-assistants": { $0.handleAgentAssistants($1) },
    ]

    /// What an assistant may do, as its `yab mcp` lists its tools by.
    static func assistantCaps(_ grant: AssistantGrant, browser: Browser) -> [String: Any] {
        let space = browser.spaces.first { $0.id == grant.space } ?? browser.spaces.first
        return ["id": grant.id, "name": grant.name, "client": grant.client,
                "space": grant.spaceName(in: browser.spaces),
                "allSpaces": grant.allSpaces == true,
                "spaces": grant.allSpaces == true ? browser.spaces.map(\.name) : [space?.name].compactMap { $0 },
                "mode": grant.mode.rawValue, "mail": grant.mail && MailCenter.shared.connected, "messages": grant.messages,
                "cards": grant.cards, "paused": grant.paused, "never": grant.never,
                "allowedSites": grant.allowedSites ?? [], "only": grant.only,
                "approvalDevices": SyncCenter.shared.assistantAnswerers.map(\.name),
                "tasks": AgentSetupModel.shared.canRunTasks(),
                "mac": Host.current().localizedName ?? "Mac",
                // Its tasks, newest first: one started while the Mac was away
                // has an id the assistant never heard.
                "started": Agents.shared.sessions.filter { $0.assistant == grant.id && $0.cli != "external" }.sorted { $0.began > $1.began }.prefix(10).map(\.id)]
    }

    func handleAgentAssistant(_ c: AgentCall) {
        guard let grant = c.agents.assistant(of: c.request["callerSession"] as? String ?? c.session) else {
            c.answer(["error": "not an assistant's session"])
            return
        }
        c.answer(Bench.assistantCaps(grant, browser: c.browser))
    }

    /// The approval a call of this session's is waiting on, on its tab or
    /// any: what `needs_user` says.
    func handleAgentApproval(_ c: AgentCall) {
        guard let session = c.request["callerSession"] as? String ?? c.session else { c.answer(["error": "no session"]); return }
        let tab = find(c.request, in: c.browser)
        // A task this assistant started asks under its own session.
        let task = c.request["task"] as? String
        let approvals = AssistantApprovals.shared
        guard let record = approvals.current(tab: tab?.id, session: task ?? session) ?? (tab == nil ? nil : approvals.current(tab: nil, session: task ?? session)) else {
            c.answer(["none": true])
            return
        }
        c.answer(Bench.approval(record))
    }

    static func approval(_ record: AssistantApprovals.Record) -> [String: Any] {
        let out: [String: Any] = ["approval": record.id, "kind": record.kind.rawValue, "state": record.state.rawValue,
                                  "title": record.title, "lines": record.lines,
                                  "expires": ISO8601DateFormatter().string(from: record.expires), "tab": record.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? record.place.wire]
        return out
    }

    func handleAgentApprovalWait(_ c: AgentCall) {
        guard let id = c.request["approval"] as? String, let grant = c.agents.assistant(of: c.request["callerSession"] as? String ?? c.session) else {
            c.answer(["error": "approval_status needs an approval id"])
            return
        }
        guard let known = AssistantApprovals.shared.records[id], known.assistant == grant.id else {
            c.answer(["error": "No approval \(id): it was settled more than ten minutes ago, or isn't this assistant's."])
            return
        }
        AssistantApprovals.shared.wait(id, seconds: min(c.request["seconds"] as? Double ?? 20, 25)) { record in
            c.answer(record.map(Bench.approval) ?? ["error": "No approval \(id)."])
        }
    }

    /// An assistant asks for more than it has: put in Settings for the
    /// user to allow or not. Never granted from here.
    func handleAgentAccessRequest(_ c: AgentCall) {
        guard let grant = c.agents.assistant(of: c.request["callerSession"] as? String ?? c.session) else { c.answer(["error": "not an assistant's session"]); return }
        let what = c.request["what"] as? String ?? ""
        guard ["mail", "messages", "cards", "site"].contains(what) else { c.answer(["error": "what is mail, messages, cards or site"]); return }
        let reason = String((c.request["reason"] as? String ?? "").prefix(300))
        let site = (c.request["site"] as? String).map { AgentRules.site(Address.url(from: $0)) }
        Assistants.shared.ask(AssistantRequest(assistant: grant.id, what: what, site: site, reason: reason, at: Date()))
        c.answer(["asked": true])
    }

    /// For tests: what Settings › AI › Assistants would do by hand.
    func handleAgentAssistants(_ c: AgentCall) {
        guard Store.testing || Store.development else { c.answer(["error": "agent-assistants only works on a --test run"]); return }
        let assistants = Assistants.shared
        let request = c.request
        switch request["act"] as? String ?? "list" {
        case "connect-ui":
            assistantConnectBench(c)
        case "server":
            if let url = request["url"] as? String { Store.settings.set(url, forKey: "assistants.server") }
            c.answer(["origin": AssistantHost.origin.absoluteString, "host": AssistantHost.shared.id])
        case "link":
            // The code typed, and the consent page's yes or no.
            let code = request["code"] as? String ?? ""
            let allow = request["allow"] as? Bool ?? true
            Task { @MainActor in
                do {
                    let link = try await AssistantHost.shared.lookup(code)
                    if let expected = request["nonce"] as? String, link.nonce != expected {
                        c.answer(["error": "connection nonce does not match"])
                        return
                    }
                    var grant: AssistantGrant?
                    if allow {
                        var made = AssistantGrant(id: Assistants.newID(), name: request["name"] as? String ?? Assistants.name(client: link.client),
                                                  client: link.client, made: Date())
                        made.space = (request["space"] as? String).flatMap { name in c.browser.spaces.first { $0.name.lowercased() == name.lowercased() }?.id }
                            ?? c.browser.spaces.first?.id
                        made.allSpaces = request["allSpaces"] as? Bool
                        made.mail = request["mail"] as? Bool ?? false
                        made.messages = request["messages"] as? Bool ?? false
                        made.cards = request["cards"] as? Bool ?? false
                        if request["guarded"] as? Bool == true { made.never = Assistants.guarded }
                        if let mode = (request["mode"] as? String).flatMap(AgentAsking.init) { made.mode = mode }
                        grant = made
                    }
                    try await AssistantHost.shared.decide(link, grant: grant)
                    c.answer(["client": link.client, "kind": link.kind, "assistant": grant?.id ?? NSNull()])
                } catch {
                    c.answer(["error": error.localizedDescription])
                }
            }
        case "set":
            guard let id = request["assistant"] as? String, assistants.grant(id) != nil else { c.answer(["error": "no assistant"]); return }
            assistants.update(id) { grant in
                if let v = request["allSpaces"] as? Bool { grant.allSpaces = v }
                if let name = request["space"] as? String,
                   let space = c.browser.spaces.first(where: { $0.name.lowercased() == name.lowercased() }) {
                    grant.space = space.id
                }
                if let v = request["paused"] as? Bool { grant.paused = v }
                if let v = request["mail"] as? Bool { grant.mail = v }
                if let v = request["messages"] as? Bool { grant.messages = v }
                if let v = request["cards"] as? Bool { grant.cards = v }
                if let v = request["never"] as? [String] { grant.never = v }
                if let v = request["allowedSites"] as? [String] { grant.allowedSites = v }
                if let v = request["only"] as? [String] { grant.only = v }
                if let v = (request["mode"] as? String).flatMap(AgentAsking.init) { grant.mode = v }
            }
            c.answer(["ok": true])
        case "access":
            let site = request["site"] as? String
            guard let id = request["assistant"] as? String,
                  let what = request["what"] as? String,
                  let found = assistants.requests.first(where: { $0.assistant == id && $0.what == what && $0.site == site })
            else { c.answer(["error": "no access request"]); return }
            assistants.answer(found, yes: request["yes"] as? Bool ?? true)
            c.answer(["ok": true, "grantMail": assistants.grant(id)?.mail ?? false])
        case "grant":
            // An assistant as if linked, with no server: for pictures of
            // the page with one connected, and its own page.
            var made = AssistantGrant(id: Assistants.newID(), name: request["name"] as? String ?? "dots",
                                      client: request["client"] as? String ?? "dots", made: Date().addingTimeInterval(-3 * 86_400))
            made.space = c.browser.spaces.first?.id
            made.allSpaces = request["allSpaces"] as? Bool
            made.mail = request["mail"] as? Bool ?? false
            made.never = Assistants.guarded + ((request["never"] as? [String]) ?? [])
            made.allowedSites = request["allowed"] as? [String]
            if let mode = (request["mode"] as? String).flatMap(AgentAsking.init) { made.mode = mode }
            assistants.keep(made)
            if request["open"] as? Bool == true {
                c.browser.openSettings(.assistants)
                SettingsWindow.shared.model?.open(.assistants, item: AssistantPlace.detail + made.id)
            }
            // "session": the attached session its calls would speak for,
            // for a test to make them through the bench as its server would.
            var out: [String: Any] = ["assistant": made.id]
            if request["session"] as? Bool == true { out["session"] = AssistantRunner.shared.session(for: made.id) ?? NSNull() }
            c.answer(out)
        case "page":
            // Settings › Assistants › Enter a Code, opened as a code that
            // came in opens it: `code` (any part of one) in its field.
            AssistantCodeHandoff.revision += 1
            AssistantCodeHandoff.nonce = request["nonce"] as? String
            AssistantCodeHandoff.code = request["code"] as? String
            AssistantCodeHandoff.client = request["client"] as? String
            c.browser.openSettings(.assistants)
            SettingsWindow.shared.model?.open(.assistants, item: AssistantPlace.code)
            c.answer(["ok": true])
        case "remove":
            guard let id = request["assistant"] as? String else { c.answer(["error": "no assistant"]); return }
            assistants.remove(id)
            c.answer(["ok": true])
        case "answer":
            // The Mac's card pressed: yes or no on an approval.
            guard let id = request["approval"] as? String, let record = AssistantApprovals.shared.records[id],
                  record.kind == .yes, record.state == .open,
                  let tab = c.browser.everyTab.first(where: { $0.id == record.tab }),
                  tab.permit?.key == record.key,
                  tab.permit?.session == record.session
            else { c.answer(["error": "no live approval"]); return }
            c.agents.answer(tab, yes: request["yes"] as? Bool ?? true)
            c.answer(["ok": true])
        default:
            let state: String
            switch AssistantHost.shared.state {
            case .off: state = "off"
            case .connecting: state = "connecting"
            case .online: state = "online"
            case .offline(let why): state = "offline: \(why)"
            }
            c.answer(["host": AssistantHost.shared.id, "state": state, "origin": AssistantHost.origin.absoluteString,
                      "assistants": assistants.grants.map { Bench.assistantCaps($0, browser: c.browser) },
                      "requests": assistants.requests.map { ["assistant": $0.assistant, "what": $0.what] },
                      "approvals": AssistantApprovals.shared.records.values.map(Bench.approval)])
        }
    }
}
