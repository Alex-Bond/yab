import Foundation

/// The connected managers Yab reads itself (ManagerVault), for one site:
/// what each has, in connection order, unlocked first by Yab where it keeps
/// the unlock password. What the field's list and an agent's sign_in both
/// ask. Names only come back; a password only from `fill`, straight into
/// the page.
@MainActor
enum ManagerVaults {
    /// One manager's answer for a site.
    struct Found: Equatable {
        let provider: String
        var state: ManagerVault.State
        var logins: [ManagerVault.Login]
    }

    /// The connected managers with an adapter that reads a vault, whose
    /// extension being off doesn't matter: Yab doesn't go through it.
    static var readable: [String] {
        PasswordManagers.Connections.shared.list.map(\.provider)
            .filter { ManagerVault.adapter($0)?.depth == .vault }
    }

    /// The connected managers Yab lists in its own rows: read by Yab and
    /// open, or being unlocked by it, with no manager's extension on in
    /// Yab. One that is on has the box to itself (fieldOwner): Yab never
    /// hides an extension's icon or menu to draw its own list instead.
    static var listed: [String] {
        guard PasswordManagers.fieldOwner == nil else { return [] }
        return readable.filter { lastState[$0] == .open || ManagerLists.shared.unlocking[$0] != nil }
    }

    /// A short memory a site, so a field's focus and every keystroke
    /// don't each run the tools again.
    private static var recent: [String: (at: Date, found: [Found])] = [:]
    /// Unlocks tried this launch that didn't take: never tried again until
    /// the password is changed (as `ManagerUnlock.run`).
    private static var refused: Set<String> = []

    static func forget() {
        recent = [:]
    }

    /// Each readable manager's logins for `host`. A locked one Yab unlocks
    /// with its saved password, once; one the person unlocks is answered
    /// as it is, for the list to say so.
    static func look(_ host: String, fresh: Bool = false) async -> [Found] {
        let key = Vault.registrable(host)
        if !fresh, let kept = recent[key], Date().timeIntervalSince(kept.at) < 30 { return kept.found }
        var out: [Found] = []
        for id in readable {
            guard let adapter = ManagerVault.adapter(id) else { continue }
            var state = await adapter.state()
            if state == .locked, let opened = await unlock(id, adapter) { state = opened }
            var logins: [ManagerVault.Login] = []
            if state == .open {
                logins = (try? await adapter.logins(for: host)) ?? []
            } else if state == .needsApproval, fresh, let read = try? await adapter.logins(for: host) {
                // 1Password's app asks the person on the first read: only
                // when they asked for the list (`fresh`), never on focus.
                logins = read
                state = .open
            }
            lastState[id] = state
            out.append(Found(provider: id, state: state, logins: logins))
        }
        recent[key] = (Date(), out)
        return out
    }

    /// Each manager's state as last seen, for the list to know whom to ask.
    static var lastState: [String: ManagerVault.State] = [:]

    /// Unlocked with the password Yab keeps for it, once a launch; true
    /// when it is open now.
    static func unlockIfKept(_ id: String, _ adapter: any ManagerAdapter) async -> Bool {
        await unlock(id, adapter) == .open
    }

    private static func unlock(_ id: String, _ adapter: any ManagerAdapter) async -> ManagerVault.State? {
        let connections = PasswordManagers.Connections.shared
        guard connections.connection(id)?.mode == .yab, !refused.contains(id), case .found(let secret) = ManagerUnlock.fetch(id)
        else { return nil }
        let ok = await adapter.unlock(secret)
        if !ok { refused.insert(id) }
        connections.unlocked(id, ok: ok)
        return ok ? .open : nil
    }

    /// The saved unlock password changed: try it again.
    static func passwordChanged(_ id: String) {
        refused.remove(PasswordManagers.canonical(id))
        recent = [:]
    }

    /// One login read from its manager and put into the page: Touch ID
    /// first when Settings asks for it (Tab.fill), only into the site it
    /// was listed for. The secret lives for this call.
    static func fill(_ login: ManagerVault.Login, into tab: Tab, agent: Bool = false,
                     done: @escaping @MainActor (Tab.Filled) -> Void) {
        guard let adapter = ManagerVault.adapter(login.provider),
              let host = tab.address?.host()?.lowercased(),
              ManagerVault.matches(login.urls, host: host) || login.urls.isEmpty
        else { done(.gone); return }
        Task { @MainActor in
            guard let secret = try? await adapter.secret(login) else { done(.gone); return }
            if login.provider == PasswordManagers.apple {
                AppleVault.filled.insert(Vault.registrable(host) + "\u{1}" + (secret.user.isEmpty ? login.user : secret.user))
            }
            tab.fill(user: secret.user.isEmpty ? login.user : secret.user, password: secret.password, agent: agent) { done($0) }
        }
    }
}

extension Bench {
    /// sign_in where Yab keeps nothing for the site, before the managers'
    /// in-page menus: a manager Yab reads itself fills the sign-in from its
    /// vault, and the agent sees names only. `otherwise` when none has a
    /// login here, so the menus are tried next (managerMenus).
    static func vaultSignIn(_ c: AgentCall, tab: Tab, host: String, session: String,
                            otherwise: @escaping @MainActor () -> Void) {
        guard !ManagerVaults.readable.isEmpty else { otherwise(); return }
        Task { @MainActor in
            let logins = await ManagerVaults.look(host).flatMap(\.logins)
            guard !logins.isEmpty else { otherwise(); return }
            let names = Array(Set(logins.map(\.user))).sorted()
            let wanted = (c.request["user"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let login: ManagerVault.Login
            if !wanted.isEmpty {
                guard let match = logins.first(where: { $0.user.lowercased() == wanted })
                    ?? logins.first(where: { $0.user.lowercased().contains(wanted) }) else {
                    // Not in a manager Yab reads: perhaps in one's own menu.
                    otherwise()
                    return
                }
                login = match
            } else if names.count > 1 {
                c.answer(["error": "The connected password managers have \(names.count) logins for \(Vault.registrable(host)): \(names.joined(separator: ", ")). Call sign_in again with user set to the one this task is for; if the task doesn't say, ask the user"])
                return
            } else {
                login = logins[0]
            }
            let name = PasswordManagers.name(login.provider)
            // Ask asks first, as Yab's own logins do.
            let permit = AgentPermit(kind: .signIn(host: Vault.registrable(host), users: [login.user]), session: session,
                                     detail: "as \(login.user), from \(name)")
            if c.browser.prefs.asking(session) == .ask {
                if let yes = tab.approved, yes.session == session, yes.ref == permit.key, Date().timeIntervalSince(yes.at) < 120 {
                    tab.approved = nil
                } else if tab.declined.remove(session) != nil {
                    c.answer(["error": "the person said not now to signing in: call handoff if they should do it themselves, or stop"])
                    return
                } else {
                    c.agents.ask(tab, permit)
                    c.answer(["error": "signing in waits for the person's yes; asking them now", "asking": true])
                    return
                }
            }
            c.agents.touch(session, "sign in · \(host)")
            AgentFeed.shared.did(tab, .type)
            AgentPage.run(tab, AgentFiles.submit, ["phase": "focus"]) { _ in
                // Said under the box while it fills: who, from where, never
                // the password.
                let agent = c.agents.session(session)?.name ?? "The agent"
                if let spot = tab.fieldSpot {
                    c.browser.agentFilling = AgentFilling(tab: tab.id, spot: spot, title: "\(agent) is signing in",
                                                          detail: "\(login.user), from \(name). Password hidden.", dark: tab.fieldDark)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if c.browser.agentFilling?.tab == tab.id { c.browser.agentFilling = nil }
                }
                ManagerVaults.fill(login, into: tab, agent: true) { filled in
                    if filled == .filled { c.browser.markFilled(tab, from: name) }
                    if filled == .refused { c.answer(["error": "the person didn't confirm with \(Vault.proof): call handoff, or stop"]); return }
                    if filled == .unasked { c.answer(["error": "the Mac couldn't ask for \(Vault.proof), so nothing was filled: call handoff so the person signs in"]); return }
                    guard filled == .filled else {
                        c.answer(["error": "\(name) didn't hand over the login, or the sign-in fields are gone: call handoff"])
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        AgentPage.run(tab, AgentFiles.submit, ["phase": "submit"]) { result in
                            let out = (try? result.get()) as? [String: Any] ?? [:]
                            let step = out["password"] as? Bool == true ? "the password" : "the name"
                            c.answer(["ok": true, "manager": login.provider,
                                      "said": "Filled \(step) for \(login.user) from \(name) and sent it. Take a snapshot: if a password page follows, call sign_in again; a code or captcha is a handoff."])
                        }
                    }
                }
            }
        }
    }
}
