import Foundation
import Testing
import SyncKit
@testable import Fast

/// ⌘-clicking links makes folders, as Dia's auto groups do
/// (docs/link-folders.md): the page and the tab it opened become one
/// folder of today's where the page stood, the page's later links and its
/// links' links go in after them, it goes when one tab is left, and the
/// switch in Settings › Tabs turns it off.
@MainActor
@Suite(.serialized)
struct LinkFoldersTests {
    /// `settles`: Folders works on this window, as the app's does, for the
    /// folder going at one tab (it also lays the row as it goes).
    private func window(folders: Bool = true, settles: Bool = false) -> (Browser, () -> Void) {
        let id = UUID()
        let browser = Browser(windowID: id)
        let stored = Store.settings.object(forKey: "tabs.linkFolders")
        browser.prefs.linkFolders = folders
        let previous = Folders.shared.browser
        if settles { Folders.shared.browser = browser }
        return (browser, {
            Folders.shared.browser = previous
            Store.settings.set(stored, forKey: "tabs.linkFolders")
            for tab in browser.tabs { browser.close(tab) }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        })
    }

    private func url(_ path: String) -> URL { URL(string: "https://example.test/\(path)")! }

    @Test func aCmdClickMakesAFolderOfThePageAndItsLink() throws {
        let (browser, done) = window()
        defer { done() }
        let other = browser.open(url("other"), foreground: true)
        let page = browser.open(url("page"), foreground: true)
        // The row laid as it stands once both are seen (a tab opened in
        // front lands when it draws), as ClearTests lays its own.
        browser.lay([page, other])
        browser.select(page)
        #expect(browser.tabs.map(\.id) == [page.id, other.id])
        let first = browser.openBeside(url("first"), from: page, foreground: false)
        let nest = try #require(page.nest)
        #expect(first.nest === nest)
        #expect(nest.fleeting && nest.today && !nest.research)
        #expect(nest.open && nest.linked)
        // Where the page stood, the page first, the link after it.
        #expect(browser.tabs.map(\.id) == [page.id, first.id, other.id])
        #expect(other.nest == nil)
        #expect(browser.active === page)
    }

    @Test func morePagesLinksAndTheirLinksJoinInOrder() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        let a = browser.openBeside(url("a"), from: page, foreground: false)
        let b = browser.openBeside(url("b"), from: page, foreground: false)
        // A link's own link: the same folder, not one of its own.
        let c = browser.openBeside(url("c"), from: a, foreground: false)
        let nest = try #require(page.nest)
        #expect([a, b, c].allSatisfy { $0.nest === nest })
        #expect(browser.tabs.filter { $0.nest === nest }.count == 4)
        #expect(Set(browser.tabs.compactMap { $0.nest.map(ObjectIdentifier.init) }).count == 1)
    }

    @Test func aPageOutsideMakesAFolderOfItsOwn() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        _ = browser.openBeside(url("a"), from: page, foreground: false)
        let other = browser.open(url("other"), foreground: true)
        let b = browser.openBeside(url("b"), from: other, foreground: false)
        let one = try #require(page.nest), two = try #require(other.nest)
        #expect(one !== two)
        #expect(b.nest === two)
    }

    @Test(arguments: [false, true], [false, true])
    func searchAndOrdinaryPagesFollowTheFolderSwitch(folders: Bool, search: Bool) throws {
        let (browser, done) = window(folders: folders)
        defer { done() }
        let other = browser.open(url("other"), foreground: true)
        let address = search ? URL(string: "https://www.google.com/search?q=folder+switch")! : url("page")
        let page = browser.open(address, foreground: true)
        browser.lay([page, other])
        browser.select(page)
        let a = browser.openBeside(url("a"), from: page, foreground: false)
        let b = browser.openBeside(url("b"), from: page, foreground: false)
        let c = browser.openBeside(url("c"), from: a, foreground: false)
        if folders {
            let nest = try #require(page.nest)
            #expect([a, b, c].allSatisfy { $0.nest === nest })
            #expect(nest.today && nest.open)
            #expect(nest.research == search)
            #expect(nest.linked == !search)
            #expect(nest.search == (search ? "folder switch" : nil))
            if search { #expect(nest.name == "Folder switch") }
        } else {
            #expect([page, a, b, c].allSatisfy { $0.nest == nil })
        }
        let order = folders && search ? [page.id, a.id, b.id, c.id, other.id] : [page.id, a.id, c.id, b.id, other.id]
        #expect(browser.tabs.map(\.id) == order)
        #expect(other.nest == nil)
        #expect(browser.active === page)
    }

    @Test(arguments: [false, true], [false, true])
    func existingFoldersTakeLinksOnlyWithTheSwitchOn(folders: Bool, search: Bool) throws {
        let (browser, done) = window()
        defer { done() }
        let address = search ? URL(string: "https://www.google.com/search?q=folder+switch")! : url("page")
        let page = browser.open(address, foreground: true)
        let a = browser.openBeside(url("a"), from: page, foreground: false)
        let nest = try #require(page.nest)
        browser.prefs.linkFolders = folders
        let b = browser.openBeside(url("b"), from: page, foreground: false)
        let c = browser.openBeside(url("c"), from: a, foreground: false)
        #expect(page.nest === nest && a.nest === nest)
        if folders {
            #expect(b.nest === nest && c.nest === nest)
        } else {
            #expect(b.nest == nil && c.nest == nil)
        }
    }

    @Test func fromAKeptTabTheSecondLinkMakesAFolderOfTheTwo() throws {
        let (browser, done) = window()
        defer { done() }
        let kept = browser.open(url("kept"), foreground: true)
        browser.keepTabs([kept], in: nil)
        // The first: a tab of today's, as Arc's, no folder (Dia's favorite).
        let a = browser.openBeside(url("a"), from: kept, foreground: false)
        #expect(a.nest == nil)
        // The second: the two links together, the kept tab left out.
        let b = browser.openBeside(url("b"), from: kept, foreground: false)
        let nest = try #require(a.nest)
        #expect(b.nest === nest && nest.today && nest.linked)
        #expect(kept.nest == nil && kept.kept)
        let c = browser.openBeside(url("c"), from: kept, foreground: false)
        #expect(c.nest === nest)
        let today = browser.tabs.filter { !$0.kept && $0.pin == nil }.map(\.id)
        #expect(today == [a.id, b.id, c.id])
    }

    @Test func fromAKeptTabOffNoFolder() {
        let (browser, done) = window(folders: false)
        defer { done() }
        let kept = browser.open(url("kept"), foreground: true)
        browser.keepTabs([kept], in: nil)
        let a = browser.openBeside(url("a"), from: kept, foreground: false)
        let b = browser.openBeside(url("b"), from: kept, foreground: false)
        #expect(a.nest == nil && b.nest == nil)
    }

    @Test func downToOneTabTheFolderGoes() throws {
        let (browser, done) = window(settles: true)
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        let a = browser.openBeside(url("a"), from: page, foreground: false)
        let b = browser.openBeside(url("b"), from: page, foreground: false)
        _ = try #require(page.nest)
        // The page closed: its links stay together.
        browser.close(page)
        Folders.shared.refresh()
        #expect(a.nest != nil && a.nest === b.nest)
        browser.close(b)
        Folders.shared.refresh()
        #expect(a.nest == nil)
        #expect(browser.tabs.contains { $0 === a })
    }

    @Test func namedFolderNUntilTheModelSaysAndInTurn() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        _ = browser.openBeside(url("a"), from: page, foreground: false)
        let other = browser.open(url("other"), foreground: true)
        _ = browser.openBeside(url("b"), from: other, foreground: false)
        // Without a model, or until it answers: Dia's "Group 1", "Group 2".
        #expect(try #require(page.nest).name == "Folder 1")
        #expect(try #require(other.nest).name == "Folder 2")
        #expect(page.nest?.linked == true)
    }

    @Test func aJoiningTabKeepsTheName() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        _ = browser.openBeside(url("a"), from: page, foreground: false)
        let nest = try #require(page.nest)
        nest.unnamed = false
        nest.name = "Kyoto Trip"
        _ = browser.openBeside(url("b"), from: page, foreground: false)
        #expect(nest.name == "Kyoto Trip")
        #expect(!nest.unnamed)
    }

    @Test func aTypedNameWinsOverTheBar() {
        let nest = Nest(name: "Folder 1")
        nest.unnamed = true
        nest.name = "Mine"
        #expect(!nest.unnamed)
        #expect(nest.name == "Mine")
    }

    @Test func onByDefaultAsInDia() {
        let stored = Store.settings.object(forKey: "tabs.linkFolders")
        defer { Store.settings.set(stored, forKey: "tabs.linkFolders") }
        Store.settings.removeObject(forKey: "tabs.linkFolders")
        #expect(Preferences().linkFolders)
    }

    @Test func yourConnectedAIFirstThenTheOther() {
        #expect(LinkFolders.order(preferred: "codex", connected: ["claude", "codex"]) == ["codex", "claude"])
        #expect(LinkFolders.order(preferred: "claude", connected: ["claude", "codex"]) == ["claude", "codex"])
        #expect(LinkFolders.order(preferred: "claude", connected: ["codex"]) == ["codex"])
        // None connected: only Apple Intelligence is left to ask.
        #expect(LinkFolders.order(preferred: "claude", connected: []).isEmpty)
    }

    @Test func aModelsNameFitsOrIsLeft() {
        #expect(LinkFolders.fits("Kyoto trip planning"))
        #expect(!LinkFolders.fits("This folder is about a trip to Kyoto in Japan."))
        #expect(!LinkFolders.fits(""))
        #expect(!LinkFolders.fits("Tab Group"))
        #expect(!LinkFolders.fits("Folder 3"))
    }

    @Test func theSiteMarkComesBackAfterARelaunch() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        _ = browser.openBeside(url("a"), from: page, foreground: false)
        let nest = try #require(page.nest)
        nest.unnamed = false
        nest.name = "Kyoto Trip"
        browser.writeRow(browser.tabs, active: browser.activeID, space: browser.spaceID, pairs: [], now: true)
        let saved = Session.read(space: browser.spaceID, window: browser.windowID)
        #expect(saved.tabs.allSatisfy { $0.folderLinked == true && $0.folderToday == true })
        let back = browser.loadRow(browser.spaceID)
        defer { for tab in back.tabs { tab.close() } }
        let again = try #require(back.tabs.first?.nest)
        #expect(again.linked && again.fleeting && again.name == "Kyoto Trip")
        #expect(back.tabs.allSatisfy { $0.nest === again })
    }

    @Test func aFolderOfTodaysWrittenBeforeHasNoSiteMark() throws {
        let (browser, done) = window()
        defer { done() }
        let folder = UUID().uuidString
        Session.write(now: true, space: browser.spaceID, window: browser.windowID, .init(tabs: [
            .init(url: "https://example.test/page", title: "Page", folder: folder, folderName: "Mine", folderToday: true),
            .init(url: "https://example.test/a", title: "A", folder: folder, folderName: "Mine", folderToday: true),
        ], active: 0))
        let back = browser.loadRow(browser.spaceID)
        defer { for tab in back.tabs { tab.close() } }
        let nest = try #require(back.tabs.first?.nest)
        #expect(nest.fleeting && !nest.linked)
    }

    @Test func syncCarriesTheMark() throws {
        let record = SyncFolder(id: "f", space: "s", name: "Kyoto Trip", today: true, linked: true)
        let read = try #require(SyncFolder(Record(collection: "folders", id: "f", fields: record.fields)))
        #expect(read.linked == true && read.today == true)
        #expect(SyncFolder(id: "g", space: "s", today: true).fields["linked"] == .null)
    }

    @Test func anEmojiComesBeforeTheNameInOneAnswer() {
        #expect(LinkFolders.split("📰 Tech Reading") == ("📰", "Tech Reading"))
        #expect(LinkFolders.split("☕️ Coffee Brewing") == ("☕️", "Coffee Brewing"))
        #expect(LinkFolders.split("📰 - Tech News") == ("📰", "Tech News"))
        #expect(LinkFolders.split("Tech Reading") == (nil, "Tech Reading"))
        #expect(LinkFolders.split("3D Printing") == (nil, "3D Printing"))
    }

    @Test func oneSiteWearsItsIconMoreWearTheEmojiOrTheFolder() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        _ = browser.openBeside(url("a"), from: page, foreground: false)
        let nest = try #require(page.nest)
        #expect(LinkFolders.mark(nest, in: browser)?.emoji == nil && LinkFolders.mark(nest, in: browser) != nil)
        _ = browser.openBeside(URL(string: "https://www.other.test/b")!, from: page, foreground: false)
        #expect(LinkFolders.mark(nest, in: browser) == nil)
        nest.customMark = "📰"
        #expect(LinkFolders.mark(nest, in: browser)?.emoji != nil)
        // A mark picked that isn't an emoji is the folder's own.
        nest.customMark = "icon:star"
        #expect(LinkFolders.mark(nest, in: browser) == nil)
    }

    @Test func optionShiftReadsAsAFolderOnlyWithTheSwitch() {
        #expect(Browser.rowClick([.option, .shift], groups: true) == .group)
        #expect(Browser.rowClick([.option, .shift], groups: false) == .extend)
        #expect(Browser.rowClick(.shift, groups: true) == .extend)
        #expect(Browser.rowClick(.option, groups: true) == .split)
        #expect(Browser.rowClick([.option, .shift, .command], groups: true) == .extend)
    }

    @Test func optionShiftMakesAKeptFolderOfThePageInFrontAndTheTab() throws {
        let (browser, done) = window()
        defer { done() }
        let other = browser.open(url("other"), foreground: true)
        let page = browser.open(url("page"), foreground: true)
        browser.lay([other, page])
        browser.select(page)
        #expect(browser.groupClick(other))
        let nest = try #require(page.nest)
        #expect(other.nest === nest && nest.linked && !nest.today)
        #expect(page.kept && other.kept)
        // The page in front first, and still in front.
        #expect(browser.tabs.map(\.id) == [page.id, other.id])
        #expect(browser.active === page)
        // On itself, nothing.
        #expect(!browser.groupClick(page))
    }

    @Test func optionShiftIntoTheFolderThePageInFrontIsIn() throws {
        let (browser, done) = window()
        defer { done() }
        let page = browser.open(url("page"), foreground: true)
        let a = browser.openBeside(url("a"), from: page, foreground: false)
        let loose = browser.open(url("loose"), foreground: false)
        browser.select(page)
        let nest = try #require(page.nest)
        #expect(browser.groupClick(loose))
        #expect(loose.nest === nest && !loose.kept)
        let inside = browser.tabs.filter { $0.nest === nest }.map(\.id)
        #expect(inside == [page.id, a.id, loose.id])
    }

    @Test func aKeptFolderOfOptionShiftKeepsItsMarkAfterARelaunch() throws {
        let (browser, done) = window()
        defer { done() }
        let other = browser.open(url("other"), foreground: true)
        let page = browser.open(url("page"), foreground: true)
        browser.select(page)
        #expect(browser.groupClick(other))
        browser.writeRow(browser.tabs, active: browser.activeID, space: browser.spaceID, pairs: [], now: true)
        let back = browser.loadRow(browser.spaceID)
        defer { for tab in back.tabs { tab.close() } }
        let nest = try #require(back.tabs.first?.nest)
        #expect(nest.linked && back.tabs.allSatisfy { $0.kept && $0.nest === nest })
    }

    @Test func joiningAMeetingPutsTheCallInAFolderNamedForIt() throws {
        let (browser, done) = window(settles: true)
        defer { done() }
        let call = browser.open(url("call"), foreground: true)
        let meeting = Meeting(id: "event-1", title: "Design review", start: Date(), end: Date().addingTimeInterval(20 * 60), link: url("call"))
        browser.meetingFolder(call, for: meeting)
        let nest = try #require(call.nest)
        #expect(nest.name == "Design review" && nest.today && nest.meeting == "event-1")
        // The call alone in it stays a folder while the meeting is on.
        Folders.shared.refresh()
        #expect(call.nest === nest)
        // A link from the call joins it.
        let doc = browser.openBeside(url("doc"), from: call, foreground: false)
        #expect(doc.nest === nest)
        // Over: down to one tab, it goes as any folder of today's.
        nest.meetingEnd = Date().addingTimeInterval(-60)
        browser.close(doc)
        Folders.shared.refresh()
        #expect(call.nest == nil)
    }

    @Test func aMeetingsTimeLeftInWords() {
        let now = Date()
        #expect(MeetingLeftWords.words(until: now.addingTimeInterval(12 * 60), now: now) == "12m left")
        #expect(MeetingLeftWords.words(until: now.addingTimeInterval(11 * 60 + 10), now: now) == "12m left")
        #expect(MeetingLeftWords.words(until: now.addingTimeInterval(90 * 60), now: now) == "1h 30m left")
        #expect(MeetingLeftWords.words(until: now.addingTimeInterval(-5), now: now) == nil)
    }
}
