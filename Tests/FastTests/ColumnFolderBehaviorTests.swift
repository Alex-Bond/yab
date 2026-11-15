import AppKit
import Testing
import SyncKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct ColumnFolderBehaviorTests {
    @Test func movingAcrossClearPreservesTheWholeTreeAndSingleTabFolders() throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        let an = w.an, seo = w.seo, comp = w.comp
        b.move(an, before: w.tabs["hn"]!.id)
        b.folderBook.refresh()
        #expect(an.today && seo.today && comp.today)
        #expect(seo.parent === an && comp.parent === seo)
        #expect(b.tabs(in: an).count == 6)
        #expect(b.tabs(in: an).allSatisfy { !$0.kept })
        #expect(b.tabs.first === w.tabs["brex"])
        #expect(b.tabs.last === w.tabs["hn"])
        // Keep must not flatten descendant folders, including one-tab children.
        b.keep(an, at: 0, in: nil)
        b.folderBook.refresh()
        #expect(!an.today && !seo.today && !comp.today)
        #expect(b.tabs(in: an).count == 6 && b.tabs(in: an).allSatisfy { $0.kept })
        #expect(w.tabs["sem"]?.nest === comp && w.tabs["gsc"]?.nest === seo)
        let single = Nest(name: "One")
        b.keepTabs([w.tabs["brex"]!], in: single)
        b.move(single, before: nil)
        b.folderBook.refresh()
        #expect(w.tabs["brex"]?.nest === single && single.today)
    }

    @Test func todayTreeSurvivesSessionAndSync() throws {
        SyncShapes.register()
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        w.seo.open = false
        b.move(w.an, before: nil)
        b.writeRow(b.tabs, active: b.activeID, space: Space.firstID, pairs: [], now: true)
        let saved = Session.read(space: Space.firstID, window: w.window)
        let entry = try #require(saved.tabs.first { $0.folderName == "Competitors" })
        #expect(entry.folderToday == true && entry.folderOrdinaryToday == true)
        #expect(entry.folderPath?.map(\.name) == ["Analitycs", "SEO"])
        let back = b.loadRow(Space.firstID)
        defer { back.tabs.forEach { $0.close() } }
        let restored = try #require(back.tabs.first { $0.nest?.name == "Competitors" }?.nest)
        #expect(restored.chain.map(\.name) == ["Analitycs", "SEO", "Competitors"])
        #expect(restored.chain.allSatisfy { $0.ordinaryToday })
        #expect(restored.parent?.open == false)
        let space = UUID()
        let rows = SyncShapes.rows([space: saved], orders: [:])
        let journal = try Journal(path: nil, device: "folder-test")
        try journal.reconcile(SyncShapes.tab, rows.tabs)
        try journal.reconcile(SyncShapes.folder, rows.folders)
        let synced = SyncShapes.row(space, tabs: journal.all(SyncShapes.tab), folders: journal.all(SyncShapes.folder), pairs: [], here: saved)
        let syncedEntry = try #require(synced.tabs.first { $0.folderName == "Competitors" })
        #expect(syncedEntry.folderOrdinaryToday == true)
        #expect(syncedEntry.folderPath == entry.folderPath)
    }

    @Test func undoClearRestoresASingleTabFolderAndItsAncestors() throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        b.move(w.an, before: nil)
        // Clear's underlying operation, without animation or loading web pages.
        let batch = try #require(b.putAway(b.tabs(in: w.an)))
        #expect(b.tabs(in: w.an).isEmpty)
        let back = b.bringBack(batch)
        #expect(back.count == 6)
        #expect(b.tabs(in: w.comp).count == 2)
        #expect(w.comp.parent === w.seo && w.seo.parent === w.an)
        let single = Nest(name: "Single")
        b.keepTabs([w.tabs["hn"]!], in: single)
        b.move(single, before: nil)
        let one = try #require(b.putAway(b.tabs(in: single)))
        #expect(b.bringBack(one).first?.nest === single)
    }

    @Test func todayFolderEditsSelectionFilingAndClosingKeepTheTreeConsistent() throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        b.move(w.an, before: nil)
        w.an.name = "Renamed"
        w.an.open = false
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: w.tabs["sem"]!)?.shown == false)
        b.activeID = w.tabs["sem"]!.id
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: w.tabs["sem"]!)?.shown == true)
        b.activeID = w.tabs["brex"]!.id
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: w.tabs["sem"]!)?.shown == false)
        w.an.open = true
        b.folderBook.refresh()
        #expect(b.folderBook.place(of: w.tabs["sem"]!)?.depth == 3)
        b.file([w.tabs["hn"]!], in: w.comp)
        #expect(w.tabs["hn"]?.nest === w.comp && w.tabs["hn"]?.kept == false)
        b.unfile(w.tabs["hn"]!)
        #expect(w.tabs["hn"]?.nest == nil)
        b.close(w.tabs["sim"]!)
        b.folderBook.refresh()
        #expect(w.tabs["sem"]?.nest === w.comp && w.comp.parent === w.seo)
        #expect(w.an.name == "Renamed")
        b.folderBook.fold(now: Date().addingTimeInterval(Folders.idle + 60))
        #expect(w.an.open && w.seo.open && w.comp.open)
    }

    @Test func landingACarriedTodayTreeAmongKeptClearsEveryDescendantsTodayState() {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        b.move(w.an, before: nil)
        let carried = b.tabs(in: w.an)
        b.placeCarried(carried, at: .row(index: 0, kept: true, nest: nil), folder: w.an)
        #expect(carried.allSatisfy { $0.kept })
        #expect(!w.an.today && !w.seo.today && !w.comp.today)
        #expect(w.comp.parent === w.seo && w.seo.parent === w.an)
    }

    @Test(arguments: [false, true])
    func aRemotePromotionAlsoResetsAncestorsWithoutDirectTabs(_ sync: Bool) throws {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        b.unfile(w.tabs["ga"]!)
        b.unfile(w.tabs["amp"]!)
        b.move(w.an, before: nil)
        let entries = b.tabs.map { tab in
            Session.Entry(url: tab.address!.absoluteString, title: tab.title, pin: nil,
                          kept: tab.kept || tab.nest?.within(w.an) == true ? true : nil,
                          folder: tab.nest?.id.uuidString, folderName: tab.nest?.name, folderOpen: tab.nest?.open,
                          folderPath: tab.nest?.path, id: tab.id.uuidString)
        }
        if sync {
            b.adopt(Session.Shape(tabs: entries, active: 0), in: b.spaceID)
        } else {
            var known = b.nestsByID(b.tabs)
            for (tab, entry) in zip(b.tabs, entries) { b.takeKept(entry, into: tab, nests: &known) }
        }
        b.folderBook.refresh()
        #expect(!w.an.today && !w.seo.today && !w.comp.today)
        #expect(w.seo.parent === w.an && w.comp.parent === w.seo)
        #expect(b.tabs(in: w.an).count == 4)
    }

    @Test func arrangementUndoRestoresFolderSectionFlags() {
        let w = NestedFoldersBrowserTests.world()
        defer { w.done() }
        let b = w.browser
        b.takeOwnFolders()
        let before = RowShape(b)
        b.move(w.an, before: nil)
        b.put(before)
        b.folderBook.refresh()
        #expect(!w.an.today && !w.seo.today && !w.comp.today)
        #expect(b.tabs(in: w.an).allSatisfy { $0.kept })
    }

    @Test func scrollingARecycledFolderCellDiscardsThePreviousRowsState() {
        let browser = Browser()
        browser.takeOwnFolders()
        let a = Nest(name: "A"), b = Nest(name: "B")
        let cell = ColumnCell(kind: .nest)
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        let context = ColumnCell.Context(browser: browser, look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0), liveID: nil)
        func bind(_ nest: Nest, scrolled: Bool) {
            cell.bind(ColumnItem(id: nest.key, kind: .nest(nest, count: 1, over: nil), indent: 0, y: 0, height: 34), context, force: false, scrolled: scrolled)
        }
        bind(a, scrolled: false)
        let first = cell.generation
        // The same state container NestRow uses, retained with its graph.
        var hover = RowLocalState(false)
        hover[a.id] = true
        #expect(hover[a.id])
        bind(a, scrolled: true)
        #expect(cell.generation == first)
        bind(b, scrolled: true)
        #expect(cell.generation == first) // preserve the scroll optimization
        #expect(!hover[b.id])
        hover[b.id] = true
        #expect(!hover[a.id])
        var tabHover = RowLocalState(SideRow.Hover())
        tabHover[a.id] = SideRow.Hover(row: true, close: true)
        #expect(!tabHover[b.id].inside)
        var shake = RowLocalState<CGFloat>(0)
        shake[a.id] = 1
        #expect(shake[b.id] == 0)
        #expect(cell.current?.hold.aimed == false && cell.current?.live == false)
    }
}
