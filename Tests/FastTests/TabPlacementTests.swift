import Foundation
import Testing
@testable import Fast

/// Where a new tab lands, case by case as Arc puts it
/// (docs/tab-placement.md, feedback 43).
struct TabPlacementTests {
    // MARK: - the rule alone

    /// One row: names in order, `pinned` of them above the line, and which
    /// earlier tab each was opened from by its page.
    private struct Row {
        let names: [String]
        let ids: [UUID]
        let linkedFrom: [UUID?]
        let keptEnd: Int

        init(_ names: [String], above: Int = 0, links: [String: String] = [:]) {
            self.names = names
            let ids = names.map { _ in UUID() }
            self.ids = ids
            self.linkedFrom = names.map { name in links[name].flatMap { names.firstIndex(of: $0) }.map { ids[$0] } }
            self.keptEnd = above
        }

        /// Where a tab opened by `source`'s page goes, as the name it would
        /// follow ("|" for the top of today's under the line).
        func landing(_ source: String?, paired: Bool = false) -> Int {
            Browser.linkLanding(source: source.flatMap { names.firstIndex(of: $0) }, linkedFrom: linkedFrom, ids: ids,
                                keptEnd: keptEnd, paired: paired)
        }
    }

    /// Split View: Arc shows the pair as one row and puts what either half
    /// opens after it; the right half's links come before the left's.
    @Test func splitViewPairs() {
        #expect(Row(["L", "R", "x"]).landing("L", paired: true) == 2)
        #expect(Row(["L", "R", "c1", "x"], links: ["c1": "L"]).landing("L", paired: true) == 3)
        #expect(Row(["L", "R", "c1", "x"], links: ["c1": "L"]).landing("R") == 2)
        #expect(Row(["a", "L", "R"]).landing("L", paired: true) == 3)
    }

    @Test func caseTable() {
        // (row, tabs above the line, opened-from links, source, expected index)
        let cases: [(String, [String], Int, [String: String], String?, Int)] = [
            ("nothing opened it: the top of today's", ["P", "K", "a", "b"], 2, [:], nil, 2),
            ("a page's first link: right after it", ["a", "S", "b"], 0, [:], "S", 2),
            ("the page last in the row", ["a", "S"], 0, [:], "S", 2),
            ("its second: after the first", ["a", "S", "c1", "b"], 0, ["c1": "S"], "S", 3),
            ("its third: after the first two, in order", ["S", "c1", "c2", "b"], 0, ["c1": "S", "c2": "S"], "S", 3),
            ("from a link it opened: right after that one", ["S", "c1", "c2"], 0, ["c1": "S", "c2": "S"], "c1", 2),
            ("past what its links opened in turn", ["S", "c1", "g1", "b"], 0, ["c1": "S", "g1": "c1"], "S", 3),
            ("a tab moved between ends the run", ["S", "c1", "x", "c2"], 0, ["c1": "S", "c2": "S"], "S", 2),
            ("another page's links are not its own", ["S", "T", "t1"], 0, ["t1": "T"], "S", 1),
            ("from a pin: the top of today's", ["P", "K", "a"], 2, [:], "P", 2),
            ("from a kept tab: the top of today's", ["P", "K", "a"], 2, [:], "K", 2),
            ("from a kept tab again: after its first", ["P", "K", "c1", "a"], 2, ["c1": "K"], "K", 3),
            ("a pin's links and a kept tab's apart", ["P", "K", "k1", "a"], 2, ["k1": "K"], "P", 2),
            ("a page not in the row: the top of today's", ["K", "a"], 1, [:], "gone", 1),
        ]
        for (name, names, above, links, source, expected) in cases {
            let row = Row(names, above: above, links: links)
            #expect(row.landing(source) == expected, "\(name)")
        }
    }

    /// A tab you ask for: the top of today's in the column, the end of the
    /// strip across the top (feedback 55, 61).
    @Test func askedForCaseTable() {
        // (row length, tabs above the line, across the top, expected index)
        let cases: [(String, Int, Int, Bool, Int)] = [
            ("column: under the pins and kept", 5, 2, false, 2),
            ("column: nothing above the line", 3, 0, false, 0),
            ("column: an empty row", 0, 0, false, 0),
            ("strip: the end, by the plus", 5, 2, true, 5),
            ("strip: past the pins too", 2, 2, true, 2),
            ("strip: an empty row", 0, 0, true, 0),
        ]
        for (name, count, above, strip, expected) in cases {
            #expect(Browser.askedLanding(count: count, keptEnd: above, strip: strip) == expected, "\(name)")
        }
    }

    // MARK: - in a window

    @MainActor @Test func alternateDestinationPreservesOrderForSuggestionsAndSearch() {
        let (browser, id) = window()
        defer {
            browser.tabs.forEach { $0.close() }
            forget(id)
        }
        let first = browser.open(url("first"), foreground: true)
        let last = browser.open(url("last"), foreground: false, atEnd: true)
        browser.take(Suggestion(key: "first", title: "First", url: first.address, kind: .open, tab: first.id), .last, copyingTab: true)
        let copy = browser.active!
        #expect(browser.tabs.map(\.id) == [first.id, last.id, copy.id])
        browser.send(Engine.url(for: "nordpass login")!, .last)
        #expect(browser.tabs.map(\.id).prefix(3) == [first.id, last.id, copy.id])
        #expect(browser.tabs.last === browser.active)
        // Command-Shift-Return keeps its existing placement.
        browser.send(url("ahead"), .ahead)
        #expect(browser.tabs.first === browser.active)
    }

    /// A window with its tabs in the column, or across the top (`strip`),
    /// the layout set for this window alone: the shared setting is put
    /// back as it was at once.
    @MainActor private func window(strip: Bool = false) -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        let stored = Store.settings.object(forKey: "sidebar")
        browser.prefs.sidebar = !strip
        Store.settings.set(stored, forKey: "sidebar")
        return (browser, id)
    }

    @MainActor private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private func url(_ path: String) -> URL { URL(string: "https://example.test/\(path)")! }

    @MainActor @Test func aTabYouAskForGoesToTheTopOfToday() {
        let (browser, id) = window()
        defer { forget(id) }
        let b = browser.open(url("b"), foreground: true)
        let a = browser.open(url("a"), foreground: true)
        a.kept = true
        browser.select(b)
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        // ⌘T over b, then a place: under the line, not beside b.
        let typed = browser.open(url("typed"), foreground: true, from: b)
        #expect(browser.tabs.map(\.id) == [a.id, typed.id, b.id])
        #expect(browser.active === typed)
    }

    @MainActor @Test func aPagesLinksStackAfterItInOrder() {
        let (browser, id) = window()
        defer { forget(id) }
        let other = browser.open(url("other"), foreground: true)
        let page = browser.open(url("page"), foreground: true)
        let below = browser.open(url("below"), foreground: false, atEnd: true)
        #expect(browser.tabs.map(\.id) == [page.id, other.id, below.id])
        browser.select(other)
        browser.select(page)
        let c1 = browser.openBeside(url("c1"), from: page, foreground: false)
        let c2 = browser.openBeside(url("c2"), from: page, foreground: false)
        // Going to another tab and back does not start the stack over.
        browser.select(other)
        browser.select(page)
        let c3 = browser.openBeside(url("c3"), from: page, foreground: true)
        #expect(browser.tabs.map(\.id) == [page.id, c1.id, c2.id, c3.id, other.id, below.id])
        #expect(browser.active === c3)
        // A link from one of them goes right after that one.
        let g = browser.openBeside(url("g"), from: c1, foreground: false)
        let afterOne: [Tab.ID] = [page.id, c1.id, g.id, c2.id, c3.id, other.id, below.id]
        #expect(browser.tabs.map(\.id) == afterOne)
        // ⌘T still goes to the top.
        let typed = browser.open(url("typed"), foreground: true, from: c3)
        #expect(browser.tabs.first === typed)
    }

    @MainActor @Test func aDuplicateGoesRightAfterItsPageBehindIt() {
        let (browser, id) = window()
        defer { forget(id) }
        let page = browser.open(url("page"), foreground: true)
        let other = browser.open(url("other"), foreground: true)
        let last = browser.open(url("last"), foreground: false, atEnd: true)
        browser.select(page)
        browser.duplicate()
        #expect(browser.tabs.count == 4)
        #expect(browser.tabs[0] === other && browser.tabs[1] === page && browser.tabs[3] === last)
        #expect(browser.tabs[2].address == page.address)
        #expect(browser.active === page)
    }

    @MainActor @Test func aPairsLinksGoAfterThePair() {
        let (browser, id) = window()
        defer { forget(id) }
        let x = browser.open(url("x"), foreground: true)
        let right = browser.open(url("right"), foreground: true)
        let left = browser.open(url("left"), foreground: true)
        browser.pairs = [Pair(first: left.id, second: right.id)]
        let c1 = browser.openBeside(url("c1"), from: left, foreground: false)
        let c2 = browser.openBeside(url("c2"), from: left, foreground: false)
        let d1 = browser.openBeside(url("d1"), from: right, foreground: false)
        #expect(browser.tabs.map(\.id) == [left.id, right.id, d1.id, c1.id, c2.id, x.id])
    }

    @MainActor @Test func linksFromAboveTheLineStackAtTheTopOfToday() {
        let (browser, id) = window()
        defer { forget(id) }
        let today = browser.open(url("today"), foreground: true)
        let kept = browser.open(url("kept"), foreground: true)
        let pin = browser.open(url("pin"), foreground: true)
        #expect(browser.tabs.map(\.id) == [pin.id, kept.id, today.id])
        pin.pin = "P"
        kept.kept = true
        #expect(browser.keptEnd == 2)
        let k1 = browser.openBeside(url("k1"), from: kept, foreground: false)
        let k2 = browser.openBeside(url("k2"), from: kept, foreground: false)
        #expect(browser.tabs.map(\.id) == [pin.id, kept.id, k1.id, k2.id, today.id])
        #expect(!k1.kept && k1.pin == nil)
        // A pin's link goes to the top of today's, above the kept tab's.
        let p1 = browser.openBeside(url("p1"), from: pin, foreground: false)
        #expect(browser.tabs.map(\.id) == [pin.id, kept.id, p1.id, k1.id, k2.id, today.id])
    }

    @MainActor @Test func acrossTheTopATabYouAskForGoesToTheEnd() {
        let (browser, id) = window(strip: true)
        defer {
            browser.tabs.forEach { $0.close() }
            forget(id)
        }
        let a = browser.open(url("a"), foreground: true)
        let b = browser.open(url("b"), foreground: true)
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        // ⌘T over a, then a place: at the end, by the plus, in front.
        browser.select(a)
        let typed = browser.open(url("typed"), foreground: true, from: a)
        #expect(browser.tabs.map(\.id) == [a.id, b.id, typed.id])
        #expect(browser.active === typed)
        // A pin stays first; a tab asked for still goes last.
        a.pin = "A"
        let next = browser.open(url("next"), foreground: false)
        #expect(browser.tabs.map(\.id) == [a.id, b.id, typed.id, next.id])
        // A page's links still go right after it, in order.
        let c1 = browser.openBeside(url("c1"), from: b, foreground: false)
        let c2 = browser.openBeside(url("c2"), from: b, foreground: false)
        #expect(browser.tabs.map(\.id) == [a.id, b.id, c1.id, c2.id, typed.id, next.id])
    }

    @MainActor @Test func acrossTheTopADuplicateStaysByItsPage() {
        let (browser, id) = window(strip: true)
        defer {
            browser.tabs.forEach { $0.close() }
            forget(id)
        }
        let pin = browser.open(url("pin"), foreground: true)
        let a = browser.open(url("a"), foreground: true)
        let b = browser.open(url("b"), foreground: true)
        pin.pin = "P"
        #expect(browser.tabs.map(\.id) == [pin.id, a.id, b.id])
        // A loose tab's copy: right after it, the page staying in front.
        browser.select(a)
        browser.duplicate()
        #expect(browser.tabs.count == 4 && browser.tabs[2].address == a.address && browser.tabs[3] === b)
        #expect(browser.active === a)
        // A pin's: the top of today's, as in the column, not the far end.
        browser.select(pin)
        browser.duplicate()
        #expect(browser.tabs.count == 5 && browser.tabs[0] === pin && browser.tabs[1].address == pin.address)
        #expect(browser.tabs[1].pin == nil && browser.tabs[2] === a)
        #expect(browser.active === pin)
    }
}
