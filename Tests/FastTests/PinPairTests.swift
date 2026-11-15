import Foundation
import Testing
@testable import Fast

/// A pair pinned as one, Dia's pinned split as the concept's variant A draws
/// it (feedback #267, register row 380, PinPairs.swift).
@MainActor
@Suite(.serialized)
struct PinPairTests {
    private func window() -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        return (browser, id)
    }

    private func forget(_ browser: Browser, _ id: UUID) {
        for tab in browser.tabs + browser.parkedTabs { tab.close() }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
    }

    private let docs = URL(string: "https://example.test/docs")!
    private let page = URL(string: "https://example.test/page")!
    private let other = URL(string: "https://example.test/other")!

    /// Two loose tabs side by side, `left` in front.
    private func pair(_ browser: Browser) throws -> (Tab, Tab, Pair) {
        let left = browser.open(page, foreground: true)
        let right = browser.open(docs, foreground: false)
        browser.split(right, with: left)
        let pair = try #require(browser.pair(of: left.id))
        return (left, right, pair)
    }

    /// Pin Pair: both halves pins, still one pair, one cell of the grid at
    /// its end, nothing of it left in Today; the pair stays on screen.
    @Test func pinningAPairMakesOneSquare() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let lone = browser.open(other, foreground: false)
        browser.pin(lone)
        let (left, right, pair) = try pair(browser)
        #expect(browser.canPinPair(pair))
        browser.pinPair(pair)
        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.pinPair(of: left.id) == pair)
        #expect(browser.pinMate(of: left) === right)
        #expect(browser.pinMate(of: right) == nil)
        #expect(browser.gridPins.map(\.id) == [lone.id, left.id])
        #expect(browser.pinCellCount == 2 && browser.pinnedCount == 3)
        #expect(browser.tabs.prefix(3).map(\.id) == [lone.id, left.id, right.id])
        #expect(browser.stagePair == pair)
        #expect(!browser.canPinPair(pair))
    }

    /// Two pins put side by side (their copies, as Arc carries a pin) pin
    /// as one square of those two pins: the copies go, no page is pinned
    /// twice, and the pair stays on screen (feedback #349).
    @Test func twoPinsSideBySidePinAsOneSquareOfThemselves() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let a = browser.open(page, foreground: true)
        let b = browser.open(docs, foreground: false)
        browser.pin(a)
        browser.pin(b)
        browser.split(b, with: a)
        let copies = try #require(browser.pair(of: browser.activeID))
        #expect(!copies.contains(a.id) && !copies.contains(b.id))
        #expect(browser.canPinPair(copies))
        browser.pinPair(copies)
        browser.settleNow()
        let pinned = try #require(browser.pinPair(of: a.id))
        #expect(pinned.first == a.id && pinned.second == b.id)
        #expect(browser.pinnedCount == 2 && browser.gridPins.map(\.id) == [a.id])
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        #expect(browser.stagePair == pinned && browser.activeID == a.id)
    }

    /// A kept tab's copy beside a loose tab: the copy is pinned itself, the
    /// kept tab stays kept, and Separate later leaves two pins, the copy
    /// never closed as a copy is when its pair goes.
    @Test func aKeptTabsCopyIsPinnedItself() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let kept = browser.open(page, foreground: true)
        browser.keepTabs([kept])
        let loose = browser.open(docs, foreground: false)
        browser.split(loose, with: kept)
        let pair = try #require(browser.pair(of: browser.activeID))
        let copy = try #require(browser.tab(id: pair.first))
        #expect(copy.id != kept.id && copy.carriedFrom == kept.id)
        #expect(browser.canPinPair(pair))
        browser.pinPair(pair)
        #expect(copy.pin != nil && loose.pin != nil && copy.carriedFrom == nil)
        #expect(kept.kept && kept.pin == nil)
        browser.separatePinPair(pair)
        browser.settleNow()
        #expect(browser.tabs.contains { $0 === copy } && copy.pin != nil)
    }

    private func ids(_ list: [Tab.ID]) -> [Tab.ID] { list }

    /// A pair row dragged up into the pins (ColumnDrag's let-go in the
    /// grid): pinned as one, its square in the cell it was let go on, both
    /// halves still a pair on screen, a pinned pair before it one cell.
    @Test func aPairDroppedInThePinsIsPinnedWhereItLands() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let one = browser.open(other, foreground: false)
        let two = browser.open(URL(string: "https://example.test/two")!, foreground: false)
        browser.pin(one)
        browser.pin(two)
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair, cell: 1)
        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.pinPair(of: left.id) == pair)
        #expect(browser.tabs.prefix(4).map(\.id) == ids([one.id, left.id, right.id, two.id]))
        #expect(browser.gridPins.map(\.id) == ids([one.id, left.id, two.id]))
        #expect(browser.stagePair == pair)
        #expect(browser.pinGrowing == nil)
        // Another pair let go on the last cell, past the pinned pair: after
        // all of the pins but the last, the pinned pair's two places one cell.
        let a = browser.open(URL(string: "https://example.test/a")!, foreground: true)
        let b = browser.open(URL(string: "https://example.test/b")!, foreground: false)
        browser.split(b, with: a)
        let second = try #require(browser.pair(of: a.id))
        browser.pinPair(second, cell: 2)
        #expect(browser.tabs.prefix(6).map(\.id) == ids([one.id, left.id, right.id, a.id, b.id, two.id]))
        #expect(browser.gridPins.map(\.id) == ids([one.id, left.id, a.id, two.id]))
        // Past the end: at the grid's end.
        browser.unpinPair(second)
        browser.pinPair(second, cell: 9)
        #expect(browser.gridPins.map(\.id) == ids([one.id, left.id, two.id, a.id]))
    }

    /// A click on the square from another tab: both halves on screen, the
    /// first in front.
    @Test func theSquareOpensBothHalves() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair)
        let away = browser.open(other, foreground: true)
        #expect(browser.active === away && browser.stagePair == nil)
        browser.tapTab(left)
        #expect(browser.activeID == left.id)
        #expect(browser.stagePair == pair)
        #expect(right.pin != nil)
    }

    /// A half's cross puts that half down: the other has the width, the
    /// square keeps both, and the next click brings the two back.
    @Test func closingAHalfOnlyRestsIt() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair)
        #expect(browser.putDownPinHalf(right))
        browser.settleNow()
        #expect(right.pairRest && right.pin != nil)
        #expect(browser.pairs == [pair])
        #expect(browser.stagePair == nil)
        #expect(browser.activeID == left.id)
        browser.tapTab(left)
        #expect(!right.pairRest)
        #expect(browser.stagePair == pair)
    }

    /// ⌘W on the half in front does the same.
    @Test func commandWOnAHalfRestsIt() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair)
        browser.close(left)
        browser.settleNow()
        #expect(left.pairRest && browser.activeID == right.id)
        #expect(browser.tabs.contains { $0 === left })
        #expect(browser.pinPair(of: left.id) == pair)
    }

    /// Separate: two plain pins side by side, no pair.
    @Test func separatingMakesTwoPins() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair)
        browser.separatePinPair(pair)
        browser.settleNow()
        #expect(browser.pairs.isEmpty)
        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.gridPins.map(\.id) == [left.id, right.id])
    }

    /// Unpin Pair, or Unpin on either half: back in Today as a pair row,
    /// at the head of today's.
    @Test func unpinningPutsThePairBackInToday() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pinPair(pair)
        browser.unpin(right)
        #expect(left.pin == nil && right.pin == nil)
        #expect(browser.pairs == [pair])
        #expect(browser.gridPins.isEmpty)
        let today = browser.tabs.filter { $0.pin == nil }
        #expect(today.prefix(2).map(\.id) == [left.id, right.id])
    }

    /// Written and read back, as a relaunch reads it: both pins, the pair
    /// and its share, by where each stands in the file.
    @Test func aPinnedPairComesBackAfterARelaunch() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let (left, right, pair) = try pair(browser)
        browser.pairs = [Pair(first: pair.first, second: pair.second, share: 0.6)]
        browser.pinPair(browser.pairs[0])
        browser.writeSession(now: true)
        let shape = Session.read(space: Space.firstID, window: id)
        let written = try #require(shape.pairs?.first)
        #expect(shape.tabs[written.first].pin != nil && shape.tabs[written.second].pin != nil)
        #expect(abs(written.share - 0.6) < 0.001)
        let ids = [left.id, right.id]
        // As at a launch: the tabs gone, the row read back from the file.
        browser.pairs = []
        for tab in browser.tabs { tab.close() }
        browser.lay([])
        let row = browser.loadRow(Space.firstID)
        defer { for tab in row.tabs { tab.close() } }
        let back = try #require(row.pairs.first)
        #expect([back.first, back.second] == ids)
        #expect(abs(back.share - 0.6) < 0.001)
        #expect(row.tabs.filter { $0.pin != nil }.map(\.id) == ids)
        #expect(row.tabs.allSatisfy { !$0.pairRest })
    }

    /// A session from before pinned pairs, and one whose pair names a pin
    /// and a loose tab, read the way they always were.
    @Test func olderSessionsReadAsBefore() throws {
        let json = """
        {"tabs":[{"url":"https://example.test/a","title":"A","pin":"A"},{"url":"https://example.test/b","title":"B"},
        {"url":"https://example.test/c","title":"C"}],"active":1,"pairs":[{"first":1,"second":2,"share":0.5}]}
        """
        let shape = try JSONDecoder().decode(Session.Shape.self, from: Data(json.utf8))
        #expect(shape.pairs?.count == 1)
        let made: [Int: Tab.ID] = [0: UUID(), 1: UUID(), 2: UUID()]
        let pairs = Pair.restore(shape.pairs ?? [], made: made)
        #expect(pairs.count == 1 && pairs[0].first == made[1])
    }

    /// Sync: the shared pins' pairs go folded into the first space's row
    /// and come back out of it, by where each stands among the pins.
    @Test func sharedPinPairsFoldForSync() {
        let pins = ["a", "b", "c"].map { Session.Entry(url: "https://example.test/\($0)", title: $0, pin: $0.uppercased(), name: nil, seen: nil) }
        let first = Session.Shape(tabs: [Session.Entry(url: "https://example.test/d", title: "d", pin: nil, name: nil, seen: nil)], front: 0)
        let folded = SharedPins.folded(pins, into: first, pinPairs: [Session.Pair(first: 1, second: 2, share: 0.4)])
        #expect(folded.pairs?.count == 1 && folded.pairs?.first?.first == 1 && folded.pairs?.first?.second == 2)
        let back = SharedPins.pinPairs(folded)
        #expect(back.count == 1 && back[0].first == 1 && back[0].second == 2 && abs(back[0].share - 0.4) < 0.001)
        #expect(SharedPins.unfolded(folded).rest.pairs == nil)
    }
}
