import Foundation

// A reload of Yab's own, not ⌘R: the site's blocker switched in Site
// Controls or Settings, an extension blocker's rules landing, the blocker
// let off from the corner (Unbreak), a userscript or a plugin put on or
// taken off. A page holding something typed and not sent asks first, on the
// card a page's question wears, over the page (Asks.swift): Later leaves the
// page as it is, the change waiting for its next load; Reload, or ⌘R, goes.
// With nothing typed it reloads at once, as it always did. Dia 1.22's
// ad-block reload prompt, for every reload Yab starts by itself.

/// What wants the page loaded again, said under the card's title.
enum ReloadCause {
    case blocking, userscript, plugin

    var words: String {
        switch self {
        case .blocking: return "Blocking changed for this site."
        case .userscript: return "A userscript for this site changed."
        case .plugin: return "A plugin for this site changed."
        }
    }
}

@MainActor
enum ReloadAsks {
    /// Tabs whose page is being asked whether it holds a draft: a second
    /// change in that moment waits on the same answer.
    static var checking: Set<UUID> = []
}

extension Tab {
    /// Loaded again for a change of Yab's own, asking first while the page
    /// holds something typed. A tab no window holds reloads at once.
    func reloadForChange(_ cause: ReloadCause) {
        let browser = BrowserWindows.shared.browsers.first { browser in
            (browser.tabs + browser.parkedTabs + browser.outside).contains { $0 === self }
        }
        guard let browser else { return reload() }
        browser.reloadForChange(self, cause)
    }
}

extension Browser {
    func reloadForChange(_ tab: Tab, _ cause: ReloadCause) {
        // Already asked, or asking: the one card stands for every change
        // since, and Reload applies them all.
        guard !tab.asks.contains(where: { $0.kind == .reload }), !ReloadAsks.checking.contains(tab.id) else { return }
        // Asleep there is no page to have typed in: waking it is the reload.
        guard tab.builtPage != nil, !tab.asleep, !tab.isBlank else { return tab.reload() }
        ReloadAsks.checking.insert(tab.id)
        // Asked afresh, since a draft said a moment ago may be sent by now;
        // a page that doesn't answer is taken at what it said last.
        tab.unsaved(within: Self.pageAnswer) { [weak self, weak tab] typed in
            guard let tab else { return }
            ReloadAsks.checking.remove(tab.id)
            guard !tab.gone else { return }
            guard let self, typed == true || (typed == nil && tab.draft) else { return tab.reload() }
            var question = PageAsk(kind: .reload, host: tab.address?.host() ?? "")
            question.message = cause.words + " Reloading loses what you typed."
            self.ask(question, on: tab) { [weak tab] reply, _ in
                guard case .yes = reply, let tab, !tab.gone else { return }
                tab.reload()
            }
        }
    }
}
