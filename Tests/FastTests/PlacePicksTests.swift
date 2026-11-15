import AppKit
import Testing
@testable import Fast

// Rows of a place picked together and gone together (PlacePicks.swift):
// ⌘-click, ⇧-click, ⇧↑/⇧↓, Escape, the foot's words, and the stores
// that let History and Downloads come back with ⌘Z. Fixture data only:
// a diary, a history and a downloads list in files of their own.
struct PlacePicksTests {
    static let ids = ["a", "b", "c", "d", "e"]

    @Test func commandClickStartsFromTheChosenRow() {
        let picks = PlacePicks.toggle([], ids: Self.ids, spot: 1, at: 3)
        #expect(picks == ["b", "d"])
        #expect(PlacePicks.toggle(picks, ids: Self.ids, spot: 3, at: 4) == ["b", "d", "e"])
        #expect(PlacePicks.toggle(picks, ids: Self.ids, spot: 3, at: 1) == ["d"])
    }

    @Test func commandClickOnTheChosenRowAloneIsOnlyIt() {
        #expect(PlacePicks.toggle([], ids: Self.ids, spot: 2, at: 2) == ["c"])
    }

    @Test func spanRunsEitherWayAndStaysInTheList() {
        #expect(PlacePicks.span(ids: Self.ids, from: 1, to: 3) == ["b", "c", "d"])
        #expect(PlacePicks.span(ids: Self.ids, from: 3, to: 1) == ["b", "c", "d"])
        #expect(PlacePicks.span(ids: Self.ids, from: 4, to: 9) == ["e"])
        #expect(PlacePicks.span(ids: [], from: 0, to: 2).isEmpty)
    }

    @Test func eachListSaysItsOwnNoun() {
        #expect(PlacePicks.selected(.history, 3) == "3 pages selected")
        #expect(PlacePicks.title(.history, 3) == "Delete 3 Pages")
        #expect(PlacePicks.title(.passwords, 2) == "Forget 2 Passwords")
        #expect(PlacePicks.title(.downloads, 4) == "Remove 4 Downloads")
        #expect(PlacePicks.title(.bookmarks, 2) == "Remove 2 Bookmarks")
        #expect(PlacePicks.title(.autofill, 3) == "Forget 3 Entries")
        #expect(PlacePicks.selected(.autofill, 3) == "3 entries selected")
    }

    // MARK: in the field

    @MainActor static func visits(_ count: Int) -> [PlaceItem] {
        (0..<count).map { index in
            let url = URL(string: "https://fixture.invalid/page-\(index)")!
            return PlaceItem(id: "visit.\(index)", section: "Today", title: "Page \(index)", tile: .site("fixture.invalid"),
                             what: .visit(url: url, title: "Page \(index)", key: "fixture.invalid/page-\(index)", at: Date(), count: 1))
        }
    }

    @MainActor static func history(_ count: Int) -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        // The place set by hand, its rows the fixture's: the diary unread.
        browser.query.place = .history
        browser.query.stock.visits = visits(count)
        browser.query.spot = 0
        return (browser, id)
    }

    @MainActor @Test func modifiersPickAndThePlainClickIsUnchanged() {
        let (browser, id) = Self.history(6)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        #expect(browser.pickClick(2, flags: []) == false)
        #expect(browser.query.picks.isEmpty)
        #expect(browser.pickClick(2, flags: .command))
        #expect(browser.query.picks == ["visit.0", "visit.2"])
        #expect(browser.pickClick(4, flags: .shift))
        #expect(browser.query.picks == ["visit.2", "visit.3", "visit.4"])
        #expect(browser.query.spot == 4)
        #expect(browser.pickedWords == "3 pages selected")
        #expect(browser.rowActions.map(\.title) == ["Delete 3 Pages"])
        #expect(browser.rowActions.first?.danger == true)
        #expect(browser.rowActions.first?.keys == "⌫")
        // Escape puts them down, the chosen row kept.
        #expect(browser.unpickRows())
        #expect(browser.query.picks.isEmpty)
        #expect(browser.query.spot == 4)
        #expect(browser.pickedWords == nil)
        #expect(browser.rowActions.first?.title != "Delete 3 Pages")
        #expect(browser.unpickRows() == false)
    }

    @MainActor @Test func shiftArrowsStretchAndPlainArrowsPutDown() {
        let (browser, id) = Self.history(6)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.spot = 1
        #expect(browser.pickStep(1))
        #expect(browser.pickStep(1))
        #expect(browser.query.picks == ["visit.1", "visit.2", "visit.3"])
        #expect(browser.pickStep(-1))
        #expect(browser.query.picks == ["visit.1", "visit.2"])
        #expect(browser.picking)
        _ = browser.walkPlace(1)
        #expect(browser.query.picks.isEmpty)
        #expect(browser.picking == false)
    }

    @MainActor @Test func typingOrAnotherFilterPutsThePicksDown() {
        let (browser, id) = Self.history(4)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        _ = browser.pickClick(3, flags: .shift)
        #expect(browser.query.picks.count == 4)
        browser.query.placeFilter = 1
        #expect(browser.query.picks.isEmpty)
        browser.query.placeFilter = 0
        browser.query.spot = 0
        _ = browser.pickClick(3, flags: .shift)
        #expect(browser.query.picks.count == 4)
        browser.query.typed = "page"
        #expect(browser.query.picks.isEmpty)
    }

    @MainActor @Test func placesThatDoNotPickKeepTheirOneRow() {
        let (browser, id) = Self.history(4)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.place = .snippets
        #expect(browser.pickClick(1, flags: .command) == false)
        #expect(browser.pickStep(1) == false)
        #expect(browser.query.picks.isEmpty)
    }

    // MARK: gone, and back

    @Test func diaryGivesBackWhatItTook() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let diary = Diary.scratch(folder.appendingPathComponent("diary.sqlite"))
        let now = Date()
        let traces = (0..<5).map { index in
            History.Trace(key: "fixture.invalid/p\(index)", title: "Fixture \(index)",
                          url: URL(string: "https://fixture.invalid/p\(index)")!, last: now.addingTimeInterval(-Double(index)), count: 2)
        }
        diary.absorb(traces)
        func listed() async -> [String] {
            await withCheckedContinuation { done in
                diary.list(before: nil, limit: 50) { rows in done.resume(returning: rows.compactMap { $0["url"] as? String }) }
            }
        }
        #expect(await listed().count == 5)
        let keys = ["fixture.invalid/p1", "fixture.invalid/p3", "fixture.invalid/p4"].map { Diary.key(URL(string: "https://" + $0)!) }
        let taken: Diary.Taken = await withCheckedContinuation { done in
            diary.take(keys: keys) { done.resume(returning: $0) }
        }
        #expect(taken.count == 3)
        #expect(Set(await listed()) == ["https://fixture.invalid/p0", "https://fixture.invalid/p2"])
        await withCheckedContinuation { done in diary.giveBack(taken) { done.resume() } }
        let back = await listed()
        #expect(back.count == 5)
        #expect(back.first == "https://fixture.invalid/p0")
    }

    @MainActor @Test func historyPutsBackOnlyWhatIsStillGone() {
        let visits = (0..<4).map { index in
            Visit(url: "https://fixture.invalid/h\(index)", key: "fixture.invalid/h\(index)", title: "H\(index)", count: 1,
                  last: Date(), typed: nil)
        }
        let history = History(visits)
        let keys = ["fixture.invalid/h1", "fixture.invalid/h2"]
        let gone = history.take(keys)
        #expect(gone.count == 2)
        #expect(keys.allSatisfy { !history.remembers($0) })
        #expect(history.remembers("fixture.invalid/h0"))
        history.putBack(gone)
        #expect(keys.allSatisfy { history.remembers($0) })
    }

    @MainActor @Test func downloadsListComesBackInDateOrder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loot = Loot(file: folder.appendingPathComponent("downloads.json"))
        let now = Date()
        for index in 0..<4 {
            loot.add(Keep(name: "f\(index).zip", from: "fixture.invalid", path: folder.appendingPathComponent("f\(index).zip").path,
                          date: now.addingTimeInterval(Double(index))))
        }
        let picked = loot.kept.filter { $0.name == "f1.zip" || $0.name == "f2.zip" }
        let gone = loot.forget(picked)
        #expect(gone.count == 2)
        #expect(loot.kept.map(\.name) == ["f3.zip", "f0.zip"])
        loot.putBack(gone)
        #expect(loot.kept.map(\.name) == ["f3.zip", "f2.zip", "f1.zip", "f0.zip"])
    }
}
