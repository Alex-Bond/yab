import Foundation
import Testing
import WebKit
@testable import Fast

// What an empty ⌘T lists (FieldSections): the parts kept in the settings,
// how the eight rows are shared, and Frequent kept to a space.
@MainActor
struct FieldSectionsTests {
    private func sections() -> (FieldSections, UserDefaults, () -> Void) {
        let suite = "dev.serafim.fast.test.sections-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (FieldSections(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: the list

    @Test func standsAsTheFieldAlwaysHas() {
        let (sections, _, done) = sections()
        defer { done() }
        #expect(sections.order == [.reading, .now, .favorites, .recent, .frequent, .actions])
        #expect(sections.off.isEmpty)
    }

    @Test func orderAndSwitchesAreKept() {
        let (sections, defaults, done) = sections()
        defer { done() }
        sections.move(.recent, before: .reading)
        sections.set(.frequent, on: false)
        let again = FieldSections(defaults: defaults)
        #expect(again.order == [.recent, .reading, .now, .favorites, .frequent, .actions])
        #expect(!again.isOn(.frequent))
        again.set(.frequent, on: true)
        #expect(FieldSections(defaults: defaults).isOn(.frequent))
    }

    @Test func movedToTheEnd() {
        let (sections, _, done) = sections()
        defer { done() }
        sections.move(.reading, before: nil)
        #expect(sections.order.last == .reading)
    }

    @Test func aPartNotInAKeptListGoesLast() {
        let (_, defaults, done) = sections()
        defer { done() }
        defaults.set(["actions", "recent", "gone"], forKey: "field.sections")
        #expect(FieldSections(defaults: defaults).order == [.actions, .recent, .reading, .now, .favorites, .frequent])
    }

    // MARK: the eight

    private let plenty: [FieldSection: Int] = [.recent: 8, .actions: 8, .frequent: 8]

    @Test func nothingOffSharesAsBefore() {
        let shares = FieldSections.shares(left: 8, have: plenty, order: FieldSection.allCases, off: [])
        #expect(shares == [.recent: 3, .actions: 2, .frequent: 3])
        let tight = FieldSections.shares(left: 4, have: plenty, order: FieldSection.allCases, off: [])
        #expect(tight == [.recent: 3, .actions: 1, .frequent: 0])
        let none = FieldSections.shares(left: -2, have: plenty, order: FieldSection.allCases, off: [])
        #expect(none == [.recent: 0, .actions: 0, .frequent: 0])
    }

    @Test func nothingOffLeavesARowEmptyAsBefore() {
        let few: [FieldSection: Int] = [.recent: 1, .actions: 8, .frequent: 8]
        let shares = FieldSections.shares(left: 8, have: few, order: FieldSection.allCases, off: [])
        #expect(shares == [.recent: 1, .actions: 2, .frequent: 3])
    }

    @Test func aPartTurnedOffLeavesItsRowsToTheOthers() {
        let shares = FieldSections.shares(left: 8, have: [.recent: 5, .actions: 8], order: FieldSection.allCases, off: [.frequent])
        #expect(shares == [.recent: 5, .actions: 3])
    }

    @Test func onlyQuickActionsFillTheEight() {
        let shares = FieldSections.shares(left: 8, have: plenty, order: FieldSection.allCases, off: [.recent, .frequent])
        #expect(shares == [.actions: 8])
    }

    @Test func theRestGoesDownTheListAsItStands() {
        let order: [FieldSection] = [.actions, .recent, .reading, .now, .favorites, .frequent]
        let shares = FieldSections.shares(left: 8, have: plenty, order: order, off: [.frequent])
        #expect(shares == [.actions: 5, .recent: 3])
    }

    // MARK: the rows

    private func window() -> (Browser, () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let store = WKWebsiteDataStore.nonPersistent()
        let tabs = ["one", "two", "three", "four"].enumerated().map { index, name in
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let tab = Tab(configuration: configuration)
            tab.restore(url: URL(string: "https://\(name).test/")!, title: name)
            tab.touch(at: Date(timeIntervalSince1970: TimeInterval(index)))
            return tab
        }
        browser.history = History(["news", "code", "mail"].enumerated().map { index, name in
            Visit(url: "https://\(name).test/", key: "\(name).test", title: name, count: 40 - index, last: Date())
        })
        browser.lay(tabs)
        let noticing = Hints.shared.suggesting
        Hints.shared.suggesting = false
        return (browser, {
            Hints.shared.suggesting = noticing
            for tab in tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        })
    }

    /// The shared list set for one test, put back after.
    private func with(off: [FieldSection], first: FieldSection? = nil, _ body: () -> Void) {
        let shared = FieldSections.shared
        let order = shared.order, kept = shared.off
        defer {
            for section in FieldSection.allCases { shared.set(section, on: !kept.contains(section)) }
            for section in order.reversed() { shared.move(section, before: shared.order.first) }
        }
        for section in FieldSection.allCases { shared.set(section, on: !off.contains(section)) }
        if let first { shared.move(first, before: shared.order.first) }
        body()
    }

    @Test func aPartTurnedOffIsNotListed() {
        let (browser, done) = window()
        defer { done() }
        with(off: [.frequent]) {
            let rows = browser.quietRows()
            #expect(!rows.contains { browser.quietSection($0) == "Frequent" })
            #expect(rows.filter { $0.kind == .open }.count == 4)
        }
    }

    @Test func thePartsStandInTheirOrder() {
        let (browser, done) = window()
        defer { done() }
        with(off: [], first: .actions) {
            let rows = browser.quietRows()
            let actions = rows.firstIndex { browser.quietSection($0) == "Quick Actions" }
            let recent = rows.firstIndex { browser.quietSection($0) == "Recent Tabs" }
            #expect(actions != nil && recent != nil && actions! < recent!)
        }
    }

    // MARK: Frequent by space

    private let work = UUID(), home = UUID()

    @Test func aSpaceListsWhatWasVisitedInIt() {
        let history = History([])
        let linear = URL(string: "https://linear.app/")!, video = URL(string: "https://video.test/")!
        for _ in 0..<3 { history.record(linear, title: "Linear", space: work) }
        for _ in 0..<3 { history.record(video, title: "Video", space: home) }
        #expect(history.frequent(8, space: work).map(\.title) == ["Linear"])
        #expect(history.frequent(8, space: home).map(\.title) == ["Video"])
        #expect(Set(history.frequent(8).map(\.title)) == ["Linear", "Video"])
    }

    @Test func aVisitInASpaceShowsTheSameDay() {
        let history = History([])
        #expect(history.frequent(8, space: work).isEmpty)
        // Twice to a place the history already knows: no new place, and
        // the list still follows.
        let page = URL(string: "https://linear.app/")!
        history.record(page, title: "Linear")
        #expect(history.frequent(8, space: work).isEmpty)
        history.record(page, title: "Linear", space: work)
        history.record(page, title: "Linear", space: work)
        #expect(history.frequent(8, space: work).count == 1)
    }

    @Test func visitsFromBeforeBelongToNoSpace() {
        let history = History([Visit(url: "https://old.test/", key: "old.test", title: "Old", count: 90, last: Date())])
        #expect(history.frequent(8, space: work).isEmpty)
        #expect(history.frequent(8).map(\.title) == ["Old"])
    }

    @Test func aPlaceForgottenGoesFromItsSpace() {
        let history = History([])
        let page = URL(string: "https://linear.app/")!
        for _ in 0..<3 { history.record(page, title: "Linear", space: work) }
        #expect(history.frequent(8, space: work).count == 1)
        history.forget("linear.app")
        #expect(history.frequent(8, space: work).isEmpty)
    }

    @Test func aDeepPageCountsForItsSite() {
        let history = History([])
        history.record(URL(string: "https://www.linear.app/team/issue")!, title: "Issue", space: work)
        #expect(history.been(at: URL(string: "https://linear.app/")!, in: work))
        #expect(!history.been(at: URL(string: "https://linear.app/")!, in: home))
    }

    @Test func aFileFromBeforeStillReads() throws {
        let old = #"[{"url":"https://old.test/","key":"old.test","title":"Old","count":9,"last":0,"typed":2}]"#
        let list = try JSONDecoder().decode([Visit].self, from: Data(old.utf8))
        #expect(list.first?.spaces == nil)
        #expect(list.first?.typed == 2)
    }

    @Test func spacesAreKeptInTheFile() throws {
        var visit = Visit(url: "https://new.test/", key: "new.test", title: "New", count: 1, last: Date())
        visit.spaces = [work.uuidString: SpaceVisits(count: 1, last: Date())]
        let read = try JSONDecoder().decode(Visit.self, from: JSONEncoder().encode(visit))
        #expect(read.spaces?[work.uuidString]?.count == 1)
    }
}
