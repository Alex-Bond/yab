import AppKit
import WebKit

// "Leave this page?": a site's beforeunload, the question a page with
// something typed in it asks before it goes (register #1033).
//
// WebKit asks it only of a UI delegate that answers the private
// `_webView:runBeforeUnloadConfirmPanelWithMessage:...`; without one it
// answers Leave for the page, so a document's unsaved changes went with a
// reload, a typed address or a link without a word. And a page is asked at
// all only on the way to another document: a tab, a window or Yab closed
// ended its page outright (Tab.close), beforeunload never ran. Closing goes
// through WKWebView's `_tryClose` first now: WebKit runs
// the page's beforeunload, asks here when the page wants it asked, and
// says the page may go with `webViewDidClose`. A Stay says nothing, so the
// answer is heard here, from the card.
//
// WebKit only lets the page ask when someone has used it (pressed, typed),
// and only when the handler asks (preventDefault or a returnValue), so a
// page that merely listens closes at once, after one trip to its process.
// A process with no beforeunload or unload listener at all answers at once,
// with no trip: those close exactly as before.
//
// The question is Yab's card on the tab (Asks.swift), Stay or Leave, in
// the window the tab is in, the tab brought to the front first. Several
// pages asking (a window or Yab closing) are asked one after another; one
// Stay keeps everything.

extension Browser {
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func _webView(
        _ webView: WKWebView,
        runBeforeUnloadConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Leaving.asked(webView, by: self, host: Dialogs.host(of: frame), answer: completionHandler)
    }

    /// The pages in `group`, asked whether they may go, then closed: the
    /// hand's way (⌘W, a tab's cross, Close Tab).
    func closeAsking(_ group: [Tab]) {
        Leaving.each(group) { [weak self] leave in
            guard leave, let self else { return }
            let still = group.filter { !$0.gone }
            guard !still.isEmpty else { return }
            self.close(still)
        }
    }

    /// Every page this window holds, a parked space's and a small
    /// window's too, as `letGo` ends them.
    var pagesHeld: [Tab] { tabs + parkedTabs + outside }
}

@MainActor
enum Leaving {
    /// Questions put up so far: a quit whose pages asked was agreed to on
    /// their card, and isn't asked about again.
    private(set) static var shown = 0

    /// A browser window closing: its pages asked first, `go` once they may.
    /// The first window's pages stay as it closes (BrowserWindows.closed),
    /// so they are not asked.
    static func window(_ window: NSWindow, go: @escaping () -> Void) {
        guard let browser = BrowserWindows.shared.browser(for: window),
              browser.windowID != BrowserWindows.primaryID else { return go() }
        each(browser.pagesHeld) { leave in if leave { go() } }
    }

    /// Yab quitting: every window's pages asked, `done` with whether they
    /// all may go and whether any of them put its question up.
    static func quit(_ done: @escaping (_ leave: Bool, _ asked: Bool) -> Void) {
        let before = shown
        let held = BrowserWindows.shared.browsers.flatMap(\.pagesHeld)
        if Store.testing { FileHandle.standardError.write(Data("yab: Leaving.quit asks \(held.count) pages, \(held.filter { $0.builtPage is ChromiumPage }.count) Chromium\n".utf8)) }
        each(held) { leave in
            if Store.testing { FileHandle.standardError.write(Data("yab: Leaving.quit answered leave=\(leave) asked=\(shown != before)\n".utf8)) }
            done(leave, shown != before)
        }
    }

    /// A page asked to close (`_tryClose`), waiting on its answer.
    final class Wait {
        var heard: [(Bool) -> Void]
        /// Its question is up, or queued: no deadline any more.
        var asking = false
        /// Its batch was answered Stay elsewhere: a question it asks now is
        /// answered Stay too, unseen.
        var dropped = false
        /// Exact currently shown card, withdrawn if its native preflight ends.
        var withdraw: (() -> Void)?
        init(_ heard: @escaping (Bool) -> Void) { self.heard = [heard] }
    }

    static var waits: [ObjectIdentifier: Wait] = [:]

    /// Questions waiting their turn behind the one up.
    private static var queue: [() -> Void] = []
    private static var showing = false

    /// A page whose process neither asks nor answers in this long is let go:
    /// WebKit's own deadline (50 ms) should have closed it long before.
    static let patience: TimeInterval = 1.5

    private static let trySelector = NSSelectorFromString("_tryClose")

    /// The page asked whether it may go, `heard` with the answer: true at
    /// once for a page with nothing to say, later for one that asks.
    static func ask(_ web: WKWebView, heard: @escaping (Bool) -> Void) {
        let id = ObjectIdentifier(web)
        if let wait = waits[id] {
            wait.heard.append(heard)
            return
        }
        guard web.responds(to: trySelector) else { return heard(true) }
        typealias Try = @convention(c) (AnyObject, Selector) -> Bool
        let tryClose = unsafeBitCast(web.method(for: trySelector), to: Try.self)
        if tryClose(web, trySelector) { return heard(true) }
        let wait = Wait(heard)
        waits[id] = wait
        let timer = Timer(timeInterval: patience, repeats: false) { [weak web] _ in
            MainActor.assumeIsolated {
                guard let web, let wait = waits[ObjectIdentifier(web)], !wait.asking else { return }
                finish(web, true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// These tabs' pages asked, one question at a time; `done(true)` once
    /// every one may go, `done(false)` at the first Stay. At once, in
    /// this call, when none of them has anything to say.
    static func each(_ tabs: [Tab], done: @escaping (Bool) -> Void) {
        // Chromium gathers non-destructive native approvals after WebKit's
        // group agrees, then commits every exact native document together.
        // A view without a native document has no beforeunload or user input;
        // preserve the ordinary synchronous close for those unbuilt pages.
        let chromium = tabs.filter { !$0.gone && ($0.builtPage as? ChromiumPage)?.remoteID != nil }
        guard chromium.isEmpty else {
            return eachWebKit(tabs) { leave in leave ? eachChromium(chromium, done: done) : done(false) }
        }
        eachWebKit(tabs, done: done)
    }

    private static func eachWebKit(_ tabs: [Tab], done: @escaping (Bool) -> Void) {
        // Another remote engine's unload prompt is not asked here yet: its page
        // goes as a page with nothing to say did before.
        if let remote = tabs.first(where: { !$0.gone && $0.builtPage != nil && $0.engineKind != .webKit && !($0.builtPage is ChromiumPage) }) {
            WebKitOnly.note("Unload prompts", engine: remote.engineKind)
        }
        let pages = tabs.compactMap { $0.gone ? nil : $0.webKitOnly("WebKit unload prompts", build: false) }
        guard !pages.isEmpty else { return done(true) }
        var left = pages.count
        var over = false
        for web in pages {
            ask(web) { leave in
                guard !over else { return }
                if !leave {
                    over = true
                    // The rest stay as well, and nobody is asked about them.
                    for other in pages { waits[ObjectIdentifier(other)]?.dropped = true }
                    done(false)
                    return
                }
                left -= 1
                if left == 0 {
                    over = true
                    done(true)
                }
            }
        }
    }

    /// WebKit's `webViewDidClose` for a page asked here: it may go. False
    /// for a page nobody asked, which closed itself (window.close()). A page
    /// asked for an engine switch answers late past `patience` and must not
    /// close its tab for it.
    static func closed(_ web: WKWebView) -> Bool {
        guard waits[ObjectIdentifier(web)] != nil else { return switchAsked.contains(ObjectIdentifier(web)) }
        finish(web, true)
        return true
    }

    /// Pages asked for an engine switch, for a while after their answer.
    private static var switchAsked = Set<ObjectIdentifier>()

    /// May this page be replaced by the other engine? Asks and never closes.
    /// `each` can't be used for a Chromium page: its batch commits the close.
    static func askForSwitch(_ tab: Tab) async -> EngineSwitchApproval.Page {
        guard !tab.gone else { return .stay }
        if let chromium = tab.builtPage as? ChromiumPage { return await askChromiumForSwitch(tab, chromium) }
        guard let web = tab.webKitOnly("WebKit unload prompts", build: false) else { return .leave }
        let id = ObjectIdentifier(web)
        switchAsked.insert(id)
        let leave = await withCheckedContinuation { done in
            ask(web) { done.resume(returning: $0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            MainActor.assumeIsolated { _ = switchAsked.remove(id) }
        }
        return leave ? .leave : .stay
    }

    /// Yab's own Leave card on the tab, for typed text the page didn't ask
    /// about. Nil when the tab has no window to ask in.
    static func askPerson(_ tab: Tab) async -> Bool? {
        guard let browser = tab.delegate as? Browser, !tab.gone else { return nil }
        if !browser.onScreen(tab.id) || BrowserWindows.shared.window(for: browser)?.isVisible != true {
            BrowserWindows.shared.reveal(tab.id)
        }
        shown += 1
        return await withCheckedContinuation { done in
            browser.ask(PageAsk(kind: .leave, host: tab.address?.host() ?? ""), on: tab) { reply, _ in
                if case .yes = reply { done.resume(returning: true) } else { done.resume(returning: false) }
            }
        }
    }

    static func finish(_ web: NSView, _ leave: Bool) {
        guard let wait = waits.removeValue(forKey: ObjectIdentifier(web)) else { return }
        for heard in wait.heard { heard(leave) }
    }

    static func withdrawChromium(_ page: ChromiumPage) {
        guard let wait = waits[ObjectIdentifier(page)] else { return }
        wait.dropped = true
        let withdraw = wait.withdraw
        wait.withdraw = nil
        withdraw?()
        finish(page, false)
    }

    /// The page's question, from WebKit: on the card of its tab, brought to
    /// the front, after any other page's question still up.
    static func asked(_ web: NSView, by browser: Browser, host: String, answer: @escaping (Bool) -> Void) {
        let wait = waits[ObjectIdentifier(web)]
        wait?.asking = true
        if wait?.dropped == true {
            answer(false)
            finish(web, false)
            return
        }
        let owner = (web as? any PageHandle).flatMap { browser.tab(owning: $0) }
            ?? (web as? WKWebView).flatMap { browser.tab(for: $0) }
        guard let tab = owner else {
            // A page with no tab of its own: the system's sheet.
            let alert = NSAlert()
            alert.messageText = "Leave this page?"
            alert.informativeText = "Changes you made may not be saved."
            alert.addButton(withTitle: "Leave")
            alert.addButton(withTitle: "Stay")
            Dialogs.show(alert, over: web) { said in
                let leave = said == .alertFirstButtonReturn
                answer(leave)
                if !leave { finish(web, false) }
            }
            return
        }
        // An agent's own page with nobody at it: nothing of yours to lose.
        if AgentPage.answers(tab) {
            answer(true)
            return
        }
        let show = { [weak browser, weak tab, weak web] in
            guard let browser, let tab, let web, !tab.gone,
                  wait == nil || waits[ObjectIdentifier(web)] === wait,
                  waits[ObjectIdentifier(web)]?.dropped != true else {
                answer(false)
                if let web { finish(web, false) }
                next()
                return
            }
            showing = true
            shown += 1
            if !browser.onScreen(tab.id) || BrowserWindows.shared.window(for: browser)?.isVisible != true {
                BrowserWindows.shared.reveal(tab.id)
            }
            let question = PageAsk(kind: .leave, host: host)
            wait?.withdraw = { [weak browser, weak tab] in
                guard let browser, let tab else { return }
                browser.withdrawAsk(question.id, on: tab)
            }
            browser.ask(question, on: tab) { reply, _ in
                wait?.withdraw = nil
                let leave: Bool
                if case .yes = reply { leave = true } else { leave = false }
                answer(leave)
                // Leave: WebKit says so with webViewDidClose. Stay it
                // doesn't say at all.
                if !leave { finish(web, false) }
                showing = false
                next()
            }
        }
        if showing { queue.append(show) } else { show() }
    }

    private static func next() {
        guard !showing, !queue.isEmpty else { return }
        queue.removeFirst()()
    }
}
