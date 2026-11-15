import Foundation
import Testing
@testable import Fast

// Request #1106: Bring tabs in listed an Arc space as "12 pins, 59 tabs,
// 0 open · into UNIVERSE", and after the import that space held only New
// tab. A large StorableSidebar.json with the shapes that could lose a
// space's items on the way: nested folders, a split view, favorites of a
// profile of its own, a space whose name a Yab space has already, and a
// space brought in before whose row has since lost what came then.
@MainActor
@Suite(.serialized)
struct ArcImportSpaceTests {
    static let source = Chromium.Source(name: "Arc", folder: "Yab missing import fixture", service: "", account: "", bundle: TabImport.arc)

    /// UNIVERSE: 12 favorites of its profile and 59 tabs in its pinned
    /// half, in folders three deep and a split; "Home" a small space of
    /// Default before it, "Notes" another after it.
    static func sidebar(universeProfile: String, tag: String) -> Data {
        var items: [[String: Any]] = []
        func add(_ id: String, parent: String?, children: [String] = [], tab: String? = nil, title: String? = nil, kind: String = "itemContainer") {
            items.append(ArcSidebarTests.item(id, parent: parent, children: children, tab: tab, title: title, saved: tab.map { "Saved \($0)" }, kind: kind))
        }
        func page(_ n: Int) -> String { "https://\(tag)-universe.test/page/\(n)" }
        // Favorites of UNIVERSE's profile: 12.
        add("u-fav", parent: nil, children: (1...12).map { "u-fav-\($0)" })
        for n in 1...12 { add("u-fav-\(n)", parent: "u-fav", tab: "https://\(tag)-fav.test/\(n)") }
        // UNIVERSE's pinned half: 59 tabs, 20 loose, a folder of 10 with a
        // folder of 10 in it with a folder of 9 in that, a split of two,
        // a folder of 8.
        var loose = (1...20).map { "u-t\($0)" }
        for (index, id) in loose.enumerated() { add(id, parent: "u-pinned", tab: page(index + 1)) }
        add("u-f1", parent: "u-pinned", children: (21...30).map { "u-t\($0)" } + ["u-f2"], title: "Research", kind: "list")
        for n in 21...30 { add("u-t\(n)", parent: "u-f1", tab: page(n)) }
        add("u-f2", parent: "u-f1", children: (31...40).map { "u-t\($0)" } + ["u-f3"], title: "Papers", kind: "list")
        for n in 31...40 { add("u-t\(n)", parent: "u-f2", tab: page(n)) }
        add("u-f3", parent: "u-f2", children: (41...49).map { "u-t\($0)" }, title: "Old", kind: "list")
        for n in 41...49 { add("u-t\(n)", parent: "u-f3", tab: page(n)) }
        add("u-split", parent: "u-pinned", children: ["u-t50", "u-t51"], kind: "splitView")
        add("u-t50", parent: "u-split", tab: page(50))
        add("u-t51", parent: "u-split", tab: page(51))
        add("u-f4", parent: "u-pinned", children: (52...59).map { "u-t\($0)" }, title: "Tools", kind: "list")
        for n in 52...59 { add("u-t\(n)", parent: "u-f4", tab: page(n)) }
        loose += ["u-f1", "u-split", "u-f4"]
        add("u-pinned", parent: nil, children: loose)
        add("u-unpinned", parent: nil)
        // Home, Default's first space, and its favorites.
        add("h-fav", parent: nil, children: ["h-fav-1"])
        add("h-fav-1", parent: "h-fav", tab: "https://\(tag)-home.test/fav")
        add("h-pinned", parent: nil, children: ["h-t1"])
        add("h-t1", parent: "h-pinned", tab: "https://\(tag)-home.test/kept")
        add("h-unpinned", parent: nil)
        add("n-pinned", parent: nil, children: ["n-t1"])
        add("n-t1", parent: "n-pinned", tab: "https://\(tag)-notes.test/kept")
        add("n-unpinned", parent: nil)

        func profile(_ folder: String) -> [String: Any] {
            folder == "Default" ? ["default": [String: Any]()] : ["custom": ["_0": ["directoryBasename": folder]]]
        }
        var list: [Any] = []
        for item in items { list += [item["id"]!, item] }
        var apps: [Any] = [profile("Default"), "h-fav"]
        if universeProfile != "Default" { apps += [profile(universeProfile), "u-fav"] }
        func space(_ id: String, _ title: String, _ owner: String, _ half: String) -> [String: Any] {
            ["id": "\(tag)-\(id)", "title": title, "profile": profile(owner),
             "containerIDs": ["pinned", "\(half)-pinned", "unpinned", "\(half)-unpinned"]]
        }
        var spaces: [[String: Any]] = []
        if universeProfile == "Default" {
            // UNIVERSE is Default's first space: Default's favorites are its.
            apps = [profile("Default"), "u-fav"]
            spaces = [space("universe", "UNIVERSE", "Default", "u"), space("home", "Home", "Default", "h"), space("notes", "Notes", "Default", "n")]
        } else {
            spaces = [space("home", "Home", "Default", "h"), space("universe", "UNIVERSE", universeProfile, "u"), space("notes", "Notes", "Default", "n")]
        }
        var spaceList: [Any] = []
        for one in spaces { spaceList += [one["id"]!, one] }
        let json: [String: Any] = ["version": 1, "sidebar": ["containers": [
            ["global": [String: Any]()],
            ["items": list, "spaces": spaceList, "topAppsContainerIDs": apps],
        ]]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    /// Every address a space shows: its row, and the shared pins when it
    /// wears them.
    static func shown(_ browser: Browser, _ id: UUID) -> Set<String> {
        var urls = Set(browser.loadRow(id).tabs.compactMap { ($0.pending ?? $0.address).map(TabImport.key) })
        if browser.showsShared(id) {
            urls.formUnion(Session.read(space: Space.pinsID).tabs.compactMap { URL(string: $0.url).map(TabImport.key) })
        }
        return urls
    }

    static func everything(_ place: TabImport.Place) -> Set<String> {
        Set((place.pinned + place.kept + place.open).map { TabImport.key($0.url) })
    }

    private func world(_ run: (Browser) throws -> Void) throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read()
        let pins = Session.read(space: Space.pinsID)
        defer { Spaces.write(previous); Session.write(now: true, space: Space.pinsID, pins) }
        let browser = Browser()
        defer { for space in browser.spaces where space.origin?.hasPrefix("Arc:") == true { Session.erase(space: space.id) } }
        try run(browser)
    }

    @Test(arguments: ["Default", "Profile 1"])
    func theListedCountsAreWhatTheSpaceHoldsAfterwards(profile: String) throws {
        let tag = "c\(UUID().uuidString.prefix(6).lowercased())"
        let places = ArcSidebar.places(in: Self.sidebar(universeProfile: profile, tag: tag))
        let universe = try #require(places.first { $0.name == "UNIVERSE" })
        #expect(universe.pinned.count == 12)
        #expect(universe.kept.count == 59)
        #expect(universe.open.isEmpty)
        #expect(TabBringer.detail(universe, withOpen: true) == "12 pins, 59 tabs, 0 open")
        try world { browser in
            browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            let space = try #require(browser.spaces.first { $0.origin == universe.id })
            #expect(Self.everything(universe).subtracting(Self.shown(browser, space.id)).isEmpty)
        }
    }

    /// A Yab space of the same name, made by hand: "into UNIVERSE".
    @Test func aSpaceOfTheSameNameTakesItAll() throws {
        let tag = "n\(UUID().uuidString.prefix(6).lowercased())"
        let places = ArcSidebar.places(in: Self.sidebar(universeProfile: "Default", tag: tag))
        let universe = try #require(places.first { $0.name == "UNIVERSE" })
        try world { browser in
            let id = UUID()
            browser.spaces.append(Space(id: id, name: "UNIVERSE", icon: "", ownSignIns: false))
            defer { Session.erase(space: id) }
            #expect(browser.landingWords(of: universe, among: places, asSpaces: true) == "into UNIVERSE")
            browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            #expect(Self.everything(universe).subtracting(Self.shown(browser, id)).isEmpty)
        }
    }

    /// Brought in before, and its row lost what came then (#584): bringing
    /// it in again, "into UNIVERSE", fills it again, rather than taking
    /// every page for one taken out on purpose and bringing none.
    @Test(arguments: ["Default", "Profile 1"])
    func aSpaceThatLostWhatCameGetsItBackOnTheNextBringIn(profile: String) throws {
        let tag = "r\(UUID().uuidString.prefix(6).lowercased())"
        let places = ArcSidebar.places(in: Self.sidebar(universeProfile: profile, tag: tag))
        let universe = try #require(places.first { $0.name == "UNIVERSE" })
        try world { browser in
            browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            let space = try #require(browser.spaces.first { $0.origin == universe.id })
            // The row emptied since; the shared pins too.
            browser.parked[space.id] = nil
            Session.write(now: true, space: space.id, window: browser.windowID, Session.Shape(tabs: [], front: nil))
            if browser.showsShared(space.id) {
                Session.write(now: true, space: Space.pinsID, .init(tabs: [], active: 0))
                browser.parked[Space.pinsID] = nil
            }
            #expect(Self.shown(browser, space.id).isDisjoint(with: Self.everything(universe)))
            #expect(browser.landingWords(of: universe, among: places, asSpaces: true) == "into UNIVERSE")
            let again = browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            #expect(again.pinned + again.open > 0)
            #expect(Self.everything(universe).subtracting(Self.shown(browser, space.id)).isEmpty)
            // And a third time, nothing twice.
            let third = browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            #expect(third.pinned == 0 && third.open == 0)
        }
    }

    /// A page taken out of a space that kept the rest stays out.
    @Test func aPageTakenOutOfAFilledSpaceStaysOut() throws {
        let tag = "o\(UUID().uuidString.prefix(6).lowercased())"
        let places = ArcSidebar.places(in: Self.sidebar(universeProfile: "Profile 1", tag: tag))
        let universe = try #require(places.first { $0.name == "UNIVERSE" })
        try world { browser in
            browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            let space = try #require(browser.spaces.first { $0.origin == universe.id })
            browser.parked[space.id] = nil
            var shape = Session.read(space: space.id, window: browser.windowID)
            let gone = try #require(shape.tabs.last { $0.pin == nil })
            shape.tabs.removeAll { $0.url == gone.url }
            Session.write(now: true, space: space.id, window: browser.windowID, shape)
            let again = browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: Self.source)
            #expect(again.pinned == 0 && again.open == 0)
            #expect(!Self.shown(browser, space.id).contains(TabImport.key(URL(string: gone.url)!)))
        }
    }
}
