import Foundation

@MainActor
extension AssistantGrant {
    /// Narrowing the menu also revokes access to tabs opened in other spaces.
    func permits(_ tab: Tab, in browser: Browser) -> Bool {
        if allSpaces == true { return true }
        guard let home = selectedSpace(in: browser.spaces) else { return false }
        var page: Tab? = tab
        var seen: Set<Tab.ID> = []
        while let current = page, seen.insert(current.id).inserted {
            if current.everywhere != nil, browser.showsShared(home) { return true }
            let place = current.assistantSpace ?? (browser.tabs.contains { $0 === current } ? browser.spaceID : browser.spaceHolding(current.id))
            if let place { return place == home }
            // A user's sign-in popup lives outside the tab row but inherits
            // the opener's space, just as an assistant's popup does.
            page = current.opener.flatMap { id in (browser.everyTab + browser.outside).first { $0.id == id } }
        }
        return false
    }
}

@MainActor
extension Browser {
    /// An assistant's grant names a tab's home as well as its cookie store.
    /// Run when ownership is assigned, including tasks and window.open tabs.
    /// A local agent's tab signed in as a space's own sign-ins has that
    /// space for its home too: it, and the task's folder it is in, show
    /// only there, never in a space signed in as someone else (feedback
    /// #448). One with the shared sign-ins still follows you.
    func placeAssistantTab(_ tab: Tab) {
        guard tab.bench else { return }
        let home: Space?
        if let grant = Agents.shared.assistant(of: tab.agent) {
            if grant.allSpaces == true {
                // Keep each tab in the space chosen when it opened, even
                // when several spaces share the same website data store.
                let chosen = tab.assistantSpace ?? Spaces.ownSpace(of: tab.store) ?? spaceID
                home = spaces.first(where: { $0.id == chosen }) ?? space
            } else {
                home = spaces.first(where: { $0.id == grant.space }) ?? spaces.first
            }
        } else if tab.agent != nil, tab.agent != Agents.script {
            home = Spaces.ownSpace(of: tab.store).flatMap { id in spaces.first { Spaces.signIn(of: $0.id) == id && $0.ownSignIns } }
        } else {
            home = nil
        }
        guard let home else {
            tab.assistantSpace = nil
            return
        }
        tab.assistantSpace = home.id
        guard home.id != spaceID, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        var row = parked[home.id] ?? loadRow(home.id)
        var remaining = tabs
        remaining.remove(at: index)
        lay(remaining)
        row.tabs.append(tab)
        parked[home.id] = row
    }
}
