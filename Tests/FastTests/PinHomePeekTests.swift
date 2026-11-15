import AppKit
import Testing
import WebKit
@testable import Fast

/// #1321 is the remaining Peek lifetime case after the pinned URL reset.
/// Exercise the production goHome/tapTab/dropPeek paths, not a mirrored helper.
@MainActor @Suite(.serialized)
struct PinHomePeekTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private let home = URL(string: "about:blank#inbox")!
    private let away = URL(string: "about:blank#message")!

    private func withBrowser(_ body: (Browser, (URL) -> Tab) throws -> Void) rethrows {
        let keys = ["mail", "search.suggest"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        let previousFoldersBrowser = Folders.shared.browser
        defer {
            Folders.shared.browser = previousFoldersBrowser
            for (key, value) in zip(keys, saved) {
                if let value { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
        }
        Store.settings.set(false, forKey: "mail")
        Store.settings.set(false, forKey: "search.suggest")
        let id = UUID(), browser = Browser(windowID: id)
        browser.lookForMailSignInLink = {}
        browser.dropSpare()
        var made: [Tab] = []
        func page(_ url: URL) -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(configuration: configuration)
            tab.restore(url: url, title: "Synthetic page")
            browser.prepare(tab)
            made.append(tab)
            return tab
        }
        defer {
            browser.peeking = nil
            browser.peekFrom = nil
            for tab in made { tab.peek = nil; if !tab.gone { tab.close() } }
            browser.letGo()
            browser.dropSpare()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            for prefix in ["session", "spaces"] {
                try? FileManager.default.removeItem(at: Store.file("\(prefix)-window-\(id.uuidString).json"))
            }
        }
        try body(browser, page)
        // No page, user window, account, provider or network is required.
        #expect(made.allSatisfy { $0.builtPage == nil && !$0.store.isPersistent })
    }

    /// LinkPeek's normal state after an owned link was opened over a source.
    /// A view is intentionally not mounted: visible frame/dimming acceptance
    /// belongs to the prepared app, while this proves actual native ownership.
    private func attach(_ preview: Tab, to source: Tab, in browser: Browser, visible: Bool = true) {
        preview.from = source.id
        source.peek = preview
        browser.outside.append(preview)
        if visible {
            browser.peeking = preview
            browser.peekFrom = source.id
        }
    }

    private func expectClosed(_ preview: Tab, from source: Tab, in browser: Browser) {
        #expect(source.peek == nil)
        #expect(preview.gone)
        #expect(!browser.outside.contains { $0 === preview })
    }

    @Test(arguments: [true, false])
    func activePinOrKeptTabReturnsHomeAndClosesItsOwnedPeek(pinned: Bool) throws {
        try withBrowser { browser, page in
            let source = page(away), preview = page(URL(string: "about:blank#link")!)
            if pinned { source.pin = "G" } else { source.kept = true }
            source.home = home
            source.homeTitle = "Inbox"
            browser.lay([source])
            browser.activeID = source.id
            attach(preview, to: source, in: browser)
            try #require(source.awayFromHome && browser.peeking === preview)
            browser.goHome(source)
            expectClosed(preview, from: source, in: browser)
            #expect(browser.peeking == nil && browser.peekFrom == nil)
            #expect((source.pending ?? source.address) == home && !source.awayFromHome)
            #expect(browser.activeID == source.id && browser.tabs.contains { $0 === source })
            #expect(source.pin == (pinned ? "G" : nil) && source.kept == !pinned)
        }
    }

    @Test func anAlreadyHomePinDismissesItsPeekWithoutNavigatingOrChangingThePin() throws {
        try withBrowser { browser, page in
            let source = page(home), preview = page(URL(string: "about:blank#link")!)
            source.pin = "G"; source.home = home; source.homeTitle = "Inbox"
            source.customMark = "icon:star"
            browser.lay([source]); browser.activeID = source.id
            attach(preview, to: source, in: browser)
            try #require(!source.awayFromHome)
            let pending = source.pending, address = source.address
            browser.goHome(source)
            expectClosed(preview, from: source, in: browser)
            #expect(browser.peeking == nil && browser.peekFrom == nil)
            #expect(source.pending == pending && source.address == address)
            #expect(source.pin == "G" && source.customMark == "icon:star" && source.home == home)
        }
    }

    @Test func aHiddenPeekIsDroppedWithoutClosingAnotherSourcesVisiblePeek() throws {
        try withBrowser { browser, page in
            let target = page(home), front = page(away)
            target.pin = "G"; target.home = home
            browser.lay([target, front]); browser.activeID = front.id
            let hidden = page(URL(string: "about:blank#hidden")!), shown = page(URL(string: "about:blank#shown")!)
            attach(hidden, to: target, in: browser, visible: false)
            attach(shown, to: front, in: browser)
            browser.goHome(target)
            expectClosed(hidden, from: target, in: browser)
            #expect(browser.peeking === shown && browser.peekFrom == front.id && front.peek === shown)
            #expect(!shown.gone && browser.outside.contains { $0 === shown })
            #expect(browser.activeID == front.id)
        }
    }

    @Test func anOrdinaryTabHasNoHomeActionAndKeepsItsPeek() throws {
        try withBrowser { browser, page in
            let source = page(home), preview = page(URL(string: "about:blank#link")!)
            browser.lay([source]); browser.activeID = source.id
            attach(preview, to: source, in: browser)
            try #require(source.pin == nil && !source.kept)
            browser.goHome(source)
            #expect(source.peek === preview && browser.peeking === preview && browser.peekFrom == source.id)
            #expect(!preview.gone && browser.outside.contains { $0 === preview })
        }
    }

    @Test func actualDoubleClickReturnsThePinHomeAndDismissesPeekWithoutEditingItsIcon() throws {
        try withBrowser { browser, page in
            let source = page(away), preview = page(URL(string: "about:blank#link")!)
            source.pin = "G"; source.home = home; source.homeTitle = "Inbox"
            source.customMark = "icon:star"
            browser.lay([source]); browser.activeID = source.id
            attach(preview, to: source, in: browser)
            // Only the keys a row click reads (Browser.rowClick); a farm Mac
            // can report Control held, which the click never looks at.
            try #require(NSEvent.modifierFlags.intersection([.command, .option, .shift]).isEmpty)
            browser.tapTab(source)
            try #require(source.awayFromHome && source.peek === preview, "One click selects; it does not reset home")
            browser.tapTab(source)
            expectClosed(preview, from: source, in: browser)
            #expect(browser.peeking == nil && browser.peekFrom == nil)
            #expect((source.pending ?? source.address) == home && browser.activeID == source.id)
            #expect(browser.editingPin == nil && browser.editingTab == nil)
            #expect(source.pin == "G" && source.customMark == "icon:star")
        }
    }
}
