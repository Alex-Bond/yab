import AppKit

// Every way into making a boost goes through here: New Boost… in the
// sidebar's plus and in Site Controls, the field's New Boost command, the
// Store's Build It, Remix and Check (register #447). Before, each opened a
// chat with the words in it whatever was there to answer: with no agent
// connected its Return opened Settings with no word why, and Build It with
// no page in front did nothing at all.

extension Browser {
    /// The page a boost would be for: the one in front, when it is a site.
    var boostPage: Tab? {
        guard let tab = active, !tab.shy, let url = tab.address, ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return tab
    }

    /// The words to the chat, about the page when there is one, or why it
    /// can't be done yet.
    func startBoost(_ words: String, about tab: Tab?) {
        guard Agents.ready else { boostNeedsAgent(); return }
        if let tab {
            askInChat(about: tab, words: words)
            return
        }
        // No page: the chat starts with the words alone, and the agent
        // opens the site the words name.
        newChat()
        chatAttach.set([])
        chatDraft = words
        if !chatOpen { moveChat(open: true) }
    }

    /// New Boost… for the page in front.
    func newBoost() {
        let tab = boostPage
        startBoost(tab.map { "Create a boost for \($0.address?.host ?? "this site"): " } ?? "Create a boost: ", about: tab)
    }

    /// Making a boost needs an agent: said, with the way to connect one
    /// and the boosts that need none.
    func boostNeedsAgent() {
        Task {
            let yes = await Questions.shared.ask(Question(
                title: "Boosts are made by Claude or ChatGPT",
                detail: "Connect one on your own plan: it writes the boost, tries it on your page and asks you to keep it. Ready-made boosts in the Store need neither.",
                glyph: "wand.and.stars", yes: "Connect", no: "Cancel", other: "Open Store", place: .plain))
            guard yes else { return }
            if Questions.shared.ticked {
                openPlace(.store)
            } else {
                openSettings(.agents)
            }
        }
    }
}
