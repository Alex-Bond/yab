import AppKit

// A page that stops answering where you can see it.
//
// A page's script can go round a loop it never leaves while you look at it:
// X's player did, on 2026-10-09, in a pinned tab open all day, and the
// window stood blank and deaf, ⌘R and all, until the process was ended by
// hand. Out of sight, Stuck.swift puts such a page down after five minutes.
// In front of you nothing did, and Yab looked dead when only one page was.
//
// WebKit notices first: an input, or a load, that the page's process hasn't
// taken in three seconds makes it call `_webViewWebProcessDidBecomeUnresponsive`,
// and `...DidBecomeResponsive` when it takes them again. So a page is only
// ever found deaf after you reached for it, and a
// page busy while you read something else is left to be busy.
//
// Twelve seconds on, fifteen after the click, if it still hasn't answered
// and is on screen, the one question: "This page stopped answering", Wait or
// Reload. Image previews and other finite main-thread work can take several
// seconds without being stuck (feedback #1139, register 1570).
// Reload ends its process and loads the address again on a new one. Wait
// leaves it; reaching for it again after thirty seconds asks again. If it
// answers by itself the card goes, saying nothing.
//
// The card is never the only way out. Anything you do to a deaf tab ends its
// process first (`Tab.letGoDeaf`): reload and stop (`unstick`), ⌘W on any
// tab, a pin put down, back, forward, an address typed, its home, Put Tab to
// Sleep. An agent's tab out of sight is reloaded after twenty seconds and the
// agent told. docs/hung-pages.md has the whole of it.

extension Browser {
    func page(_ page: any PageHandle, responsive: Bool) {
        guard let tab = tab(owning: page) else { return }
        if responsive { heardAnswering(tab) }
        else { heardDeaf(tab, by: page.engine == .webKit ? "WebKit" : "page engine") }
    }

    /// How long a deaf page in front waits before it is asked about,
    /// counted from WebKit's word (itself three seconds after the click).
    static var deafAsk: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.deafAsk")
        return set > 0 ? set : 12
    }
    /// How long Wait keeps the question away.
    static let deafQuiet: TimeInterval = 30
    /// How long an agent's deaf page out of sight is given.
    static var deafAgent: TimeInterval {
        let set = Store.settings.double(forKey: "stuck.deafAgent")
        return set > 0 ? set : 20
    }

    /// The page stopped answering: written down, and asked about in a
    /// moment if it is still on screen and still deaf then.
    func heardDeaf(_ tab: Tab, by who: String) {
        guard let web = tab.builtPage, let pid = web.contentProcess else { return }
        // Already known from the pings in front: WebKit's word is the reach.
        let since = tab.deaf ?? Date()
        if tab.deaf == nil { Watchdog.note("page \(pid) not answering (\(who))") }
        tab.deaf = since
        if tab.worker != nil, !onScreen(tab.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.deafAgent) { [weak self, weak tab] in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab.deaf == since, !self.onScreen(tab.id),
                          tab.builtPage?.contentProcess == pid else { return }
                    // Native Chromium hang events must not bypass the
                    // activity/draft/capture veto used by memory recovery.
                    if tab.builtPage?.engine == .chromium, !self.mayReloadForMemory(tab) { return }
                    StuckWatch.notices[tab.id] = "The page stopped answering and was reloaded."
                    self.endDeaf(tab)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deafAsk) { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, tab.deaf == since else { return }
                self.askDeaf(tab)
            }
        }
    }

    /// It answers again: nothing is said, and a card asked for it goes.
    func heardAnswering(_ tab: Tab) {
        guard tab.deaf != nil else { return }
        tab.deaf = nil
        if let pid = tab.builtPage?.contentProcess { Watchdog.note("page \(pid) answering again") }
        if tab.deafAsked, tab.asks.first?.kind == .stuck { dismissAsk(tab) }
    }

    /// A click, a key or a scroll in a page known deaf: asked about, unless
    /// you said Wait a moment ago.
    func reachedDeaf(_ tab: Tab) {
        guard let since = tab.deaf, Date().timeIntervalSince(since) >= Self.deafAsk else { return }
        askDeaf(tab)
    }

    /// "This page stopped answering": Wait, or Reload. What reloading costs
    /// under it, when it costs more than the page: a draft, or other tabs
    /// held in the same process.
    func askDeaf(_ tab: Tab) {
        guard tab.deaf != nil, onScreen(tab.id), Date() >= tab.deafQuiet, !devOpen, !tab.isBlank,
              tab.asks.isEmpty, let web = tab.builtPage, let pid = web.contentProcess else { return }
        var question = PageAsk(kind: .stuck, host: tab.address?.host() ?? "")
        if tab.draft {
            question.message = PageAsk.draftLost
        } else {
            let others = (tabs + parkedTabs).filter { $0 !== tab && $0.builtPage?.contentProcess == pid }
            if let first = others.first {
                let name = first.title.isEmpty ? (first.address.map(Address.pretty) ?? "another tab") : first.title
                question.message = others.count == 1 ? "Reloading also reloads “\(name)”."
                    : "Reloading also reloads “\(name)” and \(others.count - 1) other tab\(others.count == 2 ? "" : "s")."
            }
        }
        Watchdog.note("page \(pid) not answering in front: asked")
        tab.deafAsked = true
        ask(question, on: tab) { [weak self, weak tab] reply, _ in
            guard let self, let tab else { return }
            tab.deafAsked = false
            guard case .yes = reply else {
                if tab.deaf != nil { tab.deafQuiet = Date().addingTimeInterval(Self.deafQuiet) }
                return
            }
            self.endDeaf(tab)
        }
    }

    /// Its process ended by name, and the page loaded again on a new one
    /// at once (`stuck.ending`), not counted as a crash. Tabs that shared
    /// the process come back as after any crash: in front at once, behind
    /// on return.
    func endDeaf(_ tab: Tab) {
        guard let web = tab.builtPage, let pid = web.contentProcess else { return }
        Watchdog.note("page \(pid) not answering: ended and loaded again")
        stuck.seen[pid] = nil
        stuck.unanswered[pid] = nil
        tab.deaf = nil
        stuck.ending.insert(tab.id)
        web.killContent()
    }
}

extension PageAsk {
    /// Under "This page stopped answering" when it holds a draft.
    static let draftLost = "It holds something you typed and didn’t send. Reloading loses it."
}
