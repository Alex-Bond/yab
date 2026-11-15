import Foundation
import Testing
import SyncKit
@testable import Fast

/// A pin and a kept tab remember where they were pinned or kept, as Arc's
/// pinned tabs do (PinnedHome.swift, feedback #86): gone on from there they
/// say so, Back to takes them home, Replace … with Current moves the home,
/// putting one down sends it home, and the home goes through the session
/// and sync, a file or record from before it standing for the address.
@MainActor
@Suite(.serialized)
struct PinnedHomeTests {
    private func url(_ path: String) -> URL { URL(string: "https://home.test/\(path)")! }

    private func world(_ body: (Browser) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try body(browser)
    }

    private func page(_ browser: Browser, _ path: String, title: String? = nil) -> Tab {
        let tab = Tab()
        browser.prepare(tab)
        tab.restore(url: url(path), title: title ?? path)
        return tab
    }

    // MARK: the address as a home

    @Test func theSameHomeWhateverTheSchemeWwwOrLastSlash() {
        #expect(Tab.sameHome(URL(string: "https://www.github.com/")!, URL(string: "http://github.com")!))
        #expect(Tab.sameHome(URL(string: "https://GitHub.com/Org/")!, URL(string: "https://github.com/Org")!))
        #expect(Tab.sameHome(URL(string: "https://mail.google.com/mail/u/0/#")!, URL(string: "https://mail.google.com/mail/u/0/")!))
        // A page further in, another query or a mail opened (#inbox/…) is away.
        #expect(!Tab.sameHome(URL(string: "https://github.com/")!, URL(string: "https://github.com/pulls")!))
        #expect(!Tab.sameHome(URL(string: "https://x.test/?a=1")!, URL(string: "https://x.test/?a=2")!))
        #expect(!Tab.sameHome(URL(string: "https://mail.google.com/mail/u/0/#inbox")!,
                              URL(string: "https://mail.google.com/mail/u/0/#inbox/FMfcg")!))
        // Path case counts: servers tell /Org from /org.
        #expect(!Tab.sameHome(URL(string: "https://x.test/Org")!, URL(string: "https://x.test/org")!))
        #expect(!Tab.sameHome(URL(string: "https://x.test:8443/")!, URL(string: "https://x.test/")!))
    }

    @Test func aLongHomeTitleIsCutShort() {
        #expect(Tab.short("Inbox") == "Inbox")
        let long = Tab.short(String(repeating: "a", count: 50))
        #expect(long.count == 32 && long.hasSuffix("…"))
    }

    // MARK: pinned and kept

    @Test func pinningRemembersTheAddressAndUnpinningForgetsIt() {
        world { browser in
            let a = page(browser, "inbox", title: "Inbox"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            #expect(a.home == nil)
            browser.pin(a)
            #expect(a.home == url("inbox") && a.homeTitle == "Inbox")
            #expect(!a.awayFromHome)
            a.restore(url: url("inbox/42"), title: "A mail")
            #expect(a.awayFromHome)
            #expect(a.home == url("inbox"))
            #expect(a.homeName == "Inbox")
            browser.unpin(a)
            #expect(a.home == nil && !a.awayFromHome)
        }
    }

    @Test func keepingRemembersTheAddressAndATodaysTabHasNone() {
        world { browser in
            let a = page(browser, "docs"), b = page(browser, "today")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.keepTabs([a])
            #expect(a.home == url("docs"))
            b.restore(url: url("elsewhere"), title: "Elsewhere")
            #expect(b.home == nil && !b.awayFromHome)
            browser.releaseTabs([a])
            #expect(a.home == nil)
        }
    }

    @Test func aKeptTabMadeAPinKeepsItsHome() {
        world { browser in
            let a = page(browser, "docs"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.keepTabs([a])
            a.restore(url: url("docs/page"), title: "Page")
            browser.pin(a)
            #expect(a.pin != nil && !a.kept)
            #expect(a.home == url("docs") && a.awayFromHome)
        }
    }

    @Test func backToGoesHomeAndBringsTheTabToTheFront() {
        world { browser in
            let a = page(browser, "home", title: "Home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = a.id
            browser.keepTabs([a])
            a.restore(url: url("home/deep"), title: "Deep")
            #expect(a.awayFromHome)
            browser.goHome(a)
            #expect(!a.awayFromHome)
            #expect(a.address == url("home"))
            #expect(a.title == "Home")
            #expect(browser.activeID == a.id)
        }
    }

    /// Feedback #645: the second press used to replace the favicon with
    /// Change Letter's field instead of returning to the pinned address.
    @Test(arguments: [true, false])
    func doubleClickReturnsAPinHomeWithoutEditingItsIcon(active: Bool) {
        world { browser in
            let a = page(browser, "home", title: "Home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.pin(a)
            a.customMark = "icon:star"
            let letter = a.pin
            a.restore(url: url("home/deep"), title: "Deep")
            browser.activeID = active ? a.id : b.id
            browser.tapTab(a)
            #expect(a.awayFromHome, "A single click selects without resetting")
            browser.tapTab(a)
            #expect(!a.awayFromHome)
            #expect((a.pending ?? a.address) == url("home"))
            #expect(browser.activeID == a.id)
            #expect(browser.editingPin == nil)
            #expect(browser.editingTab == nil)
            #expect(a.pin == letter && a.customMark == "icon:star" && a.displayIcon != nil)
        }
    }

    @Test func doubleClickAtHomeLeavesTheIconAloneAndChangeLetterStillWorks() {
        world { browser in
            let a = page(browser, "home")
            browser.lay([a])
            browser.pin(a)
            browser.tapTab(a)
            browser.tapTab(a)
            #expect(browser.editingPin == nil && !a.awayFromHome)
            browser.editLetter(a)
            #expect(browser.editingPin == a.id)
            browser.letter("Z", for: a)
            browser.endPinEdit()
            #expect(a.pin == "Z" && browser.editingPin == nil)
        }
    }

    @Test func replaceWithCurrentMakesThisPageTheHome() {
        world { browser in
            let a = page(browser, "home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.pin(a)
            a.restore(url: url("better"), title: "Better")
            browser.makeHome(a)
            #expect(a.home == url("better") && a.homeTitle == "Better")
            #expect(!a.awayFromHome)
        }
    }

    @Test func puttingAKeptTabDownSendsItHome() {
        world { browser in
            let a = page(browser, "home", title: "Home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.keepTabs([a])
            a.restore(url: url("home/deep"), title: "Deep")
            browser.close(a)
            #expect(browser.tabs.contains { $0 === a })
            #expect(a.kept && a.asleep)
            #expect(a.address == url("home") && a.title == "Home")
            #expect(!a.awayFromHome)
        }
    }

    /// Feedback #171: kept A, then kept B, then ⌘W and ⌘W. Put down, B
    /// woke A (asleep, but not a pin), and A put down woke B, round and
    /// round. A tab put down is never where ⌘W lands: an ordinary tab, asleep
    /// or not, comes first, and with none the field.
    @Test func puttingKeptTabsDownNeverWakesAnotherPutDown() {
        world { browser in
            let a = page(browser, "a"), b = page(browser, "b")
            browser.lay([a, b])
            browser.keepTabs([a, b])
            #expect(a.kept && b.kept)
            browser.activeID = b.id
            browser.close(b)
            #expect(b.asleep)
            #expect(browser.activeID != a.id)
            #expect(browser.activeID == nil)
            // A pin put down after a kept one the same.
            browser.pin(a)
            browser.activeID = a.id
            browser.close(a)
            #expect(browser.activeID != b.id)
        }
    }

    @Test func puttingAKeptTabDownLandsOnAnOrdinaryTabAsleep() {
        world { browser in
            let a = page(browser, "a"), b = page(browser, "b"), c = page(browser, "c")
            browser.lay([a, b, c])
            browser.keepTabs([a, b])
            a.touch(at: Date())
            c.touch(at: Date(timeIntervalSinceNow: -60))
            browser.activeID = b.id
            browser.close(b)
            #expect(browser.activeID == c.id)
        }
    }

    /// Feedback #105: a kept tab renamed, then browsed on from its home,
    /// read the page's title instead of its name. The name stays, at home,
    /// away and back, through a reload of the page's title and the session.
    @Test func aNameGivenToAKeptTabStaysWhereverItGoes() throws {
        try world { browser in
            let a = page(browser, "inbox", title: "Inbox"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = a.id
            browser.keepTabs([a])
            browser.beginTabEdit(a)
            browser.tabDraft = "Work mail"
            browser.commitTabEdit()
            #expect(a.name == "Work mail" && a.label == "Work mail")
            a.restore(url: url("inbox/42"), title: "A mail")
            #expect(a.awayFromHome)
            #expect(a.awayLabel == "Work mail")
            #expect(a.rowLabel == "Work mail")
            // Renamed again while away: the field holds the name, not the page.
            browser.beginTabEdit(a)
            #expect(browser.tabDraft == "Work mail")
            browser.cancelTabEdit()
            browser.goHome(a)
            #expect(!a.awayFromHome && a.label == "Work mail")
            let entry = try #require(browser.sessionEntry(a, id: a.id))
            #expect(entry.name == "Work mail")
            // A pin away from home keeps its name as well.
            let c = page(browser, "docs", title: "Docs")
            browser.lay([a, b, c])
            browser.pin(c)
            c.name = "Specs"
            c.restore(url: url("docs/page"), title: "Page")
            #expect(c.awayFromHome && c.awayLabel == "Specs")
            // Unnamed, away reads the page it is on.
            c.name = nil
            #expect(c.awayLabel == "Page")
        }
    }

    @Test func theMailPinIsNeverAway() {
        world { browser in
            let a = page(browser, "b")
            browser.lay([a])
            a.pin = "M"
            a.home = MailPage.url
            #expect(!a.awayFromHome)
        }
    }

    // MARK: Edit…

    @Test func editTakesAnAddressAsTheFieldDoesAndNeverWords() {
        #expect(Tab.homeAddress(from: "github.com/org") == URL(string: "https://github.com/org"))
        #expect(Tab.homeAddress(from: "  https://x.test/a?b=1  ") == URL(string: "https://x.test/a?b=1"))
        #expect(Tab.homeAddress(from: "localhost:3000") == URL(string: "http://localhost:3000"))
        #expect(Tab.homeAddress(from: "http://plain.test/") == URL(string: "http://plain.test/"))
        #expect(Tab.homeAddress(from: "hello world") == nil)
        #expect(Tab.homeAddress(from: "todo") == nil)
        #expect(Tab.homeAddress(from: "") == nil)
        #expect(Tab.homeAddress(from: "me@mail.test") == nil)
        #expect(Tab.homeAddress(from: "ftp://files.test/") == nil)
        #expect(Tab.homeAddress(from: "/Users/someone/page.html") == nil)
        #expect(Tab.homeAddress(from: "about:blank") == nil)
    }

    @Test func aNewHomeForATabAtHomeTakesItThereWithTheSiteForATitle() {
        world { browser in
            let a = page(browser, "home", title: "Home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.keepTabs([a])
            #expect(browser.setHome(a, typed: "other.test/start"))
            #expect(a.home == URL(string: "https://other.test/start"))
            #expect(a.homeTitle == nil && a.homeName == "other.test")
            // At home before, so there now, asleep until looked at.
            #expect(a.address == URL(string: "https://other.test/start") && a.asleep)
            #expect(!a.awayFromHome)
            // Its page's title, once it has one there, is the home's.
            a.restore(url: URL(string: "https://other.test/start")!, title: "Start here")
            a.learnHomeTitle()
            #expect(a.homeTitle == "Start here" && a.homeName == "Start here")
            #expect(browser.sessionEntry(a, id: a.id)?.home == "https://other.test/start")
        }
    }

    @Test func aNewHomeForATabAwayLeavesItWhereItIs() {
        world { browser in
            let a = page(browser, "home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.pin(a)
            a.restore(url: url("away"), title: "Away")
            #expect(browser.setHome(a, typed: "https://home.test/new"))
            #expect(a.home == url("new"))
            #expect(a.address == url("away") && a.awayFromHome)
            // Its home typed as the page it is on: the title comes along.
            #expect(browser.setHome(a, typed: "home.test/away"))
            #expect(a.homeTitle == "Away" && !a.awayFromHome)
        }
    }

    @Test func wordsAreRefusedAndNothingTypedKeepsTheHome() {
        world { browser in
            let a = page(browser, "home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = a.id
            browser.keepTabs([a])
            #expect(!browser.setHome(a, typed: "my home page"))
            #expect(a.home == url("home"))
            // The field: prefilled with the home, refused words keep it up.
            browser.beginHomeEdit(a)
            #expect(browser.editingTab == a.id && browser.editingHome)
            #expect(browser.tabDraft == url("home").absoluteString)
            let before = browser.refusals
            browser.tabDraft = "my home page"
            browser.commitTabEdit()
            #expect(browser.editingHome && browser.editingTab == a.id && browser.refusals == before + 1)
            #expect(a.home == url("home"))
            // Emptied and Return: put down, the home as it was, no name given.
            browser.tabDraft = ""
            browser.commitTabEdit()
            #expect(!browser.editingHome && browser.editingTab == nil)
            #expect(a.home == url("home") && a.name == nil)
            // Escape after typing: the same.
            browser.beginHomeEdit(a)
            browser.tabDraft = "elsewhere.test"
            browser.cancelTabEdit()
            #expect(!browser.editingHome && a.home == url("home"))
        }
    }

    @Test func onlyAPinOrAKeptTabTakesAHome() {
        world { browser in
            let a = page(browser, "today")
            browser.lay([a])
            #expect(!browser.setHome(a, typed: "other.test"))
            browser.beginHomeEdit(a)
            #expect(browser.editingTab == nil && !browser.editingHome)
            #expect(a.home == nil)
        }
    }

    // MARK: written down and synced

    @Test func theSessionWritesTheHomeAndOneFromBeforeTakesTheAddress() throws {
        try world { browser in
            let a = page(browser, "home", title: "Home"), b = page(browser, "b")
            browser.lay([a, b])
            browser.activeID = b.id
            browser.keepTabs([a])
            a.restore(url: url("home/deep"), title: "Deep")
            let entry = try #require(browser.sessionEntry(a, id: a.id))
            #expect(entry.url == url("home/deep").absoluteString)
            #expect(entry.home == url("home").absoluteString && entry.homeTitle == "Home")
            #expect(browser.sessionEntry(b, id: b.id)?.home == nil)

            // A file written before there was a home: decoded, it has none.
            let old = #"{"url":"https://home.test/x","title":"X","kept":true}"#
            let decoded = try JSONDecoder().decode(Session.Entry.self, from: Data(old.utf8))
            #expect(decoded.home == nil && decoded.homeTitle == nil)

            // Read in: the written home, or none written, the address.
            let fresh = page(browser, "home/deep")
            fresh.kept = true
            fresh.takeHome(entry)
            #expect(fresh.home == url("home") && fresh.awayFromHome)
            let migrated = page(browser, "x")
            migrated.kept = true
            migrated.takeHome(decoded)
            #expect(migrated.home == url("x") && !migrated.awayFromHome)
        }
    }

    @Test func aRecordWithoutAHomeLeavesTheOneTheTabHas() {
        world { browser in
            let a = page(browser, "home")
            browser.lay([a])
            a.kept = true
            a.restore(url: url("away"), title: "Away")
            // An older copy wrote the record: no home in it.
            a.takeHome(Session.Entry(url: url("away").absoluteString, title: "Away", kept: true))
            #expect(a.home == url("home") && a.awayFromHome)
        }
    }

    @Test func theHomeGoesOutToSyncAndComesBack() throws {
        SyncShapes.register()
        let space = UUID()
        let shape = Session.Shape(tabs: [
            Session.Entry(url: "https://home.test/deep", title: "Deep", pin: "H", id: "tab-0", home: "https://home.test/", homeTitle: "Home"),
            Session.Entry(url: "https://home.test/today", title: "Today", id: "tab-1"),
        ], active: 1)
        let out = SyncShapes.rows([space: shape], orders: [:])
        #expect(out.tabs["tab-0"]?["home"] == .string("https://home.test/"))
        #expect(out.tabs["tab-1"]?["home"] == .null)
        let journal = try Journal(path: nil, device: "a")
        try journal.reconcile(SyncShapes.tab, out.tabs)
        let back = SyncShapes.row(space, tabs: journal.all(SyncShapes.tab), folders: [], pairs: [], here: shape)
        #expect(back.tabs.first?.home == "https://home.test/" && back.tabs.first?.homeTitle == "Home")
        #expect(back.tabs.last?.home == nil)
    }
}
