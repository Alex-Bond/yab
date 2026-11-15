import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct WelcomeImportTests {
    private func dia(_ pinned: [String], _ open: [String]) throws -> [TabImport.Place] {
        func tab(_ url: String) -> [String: Any] {
            ["contents": [["variant": ["webContent": ["_0": ["url": url, "title": url]]]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["containers": [
            ["id": ["profileID": "Default", "container": ["favorites": [:]]], "tabs": pinned.map(tab)],
            ["id": ["profileID": "Default", "container": ["window": [:]]], "tabs": open.map(tab)],
        ]])
        return DiaContainers.places(in: data)
    }

    @Test func diaWithoutFavoritesStillHasTabsToBring() throws {
        let places = try dia([], ["https://example.test/one", "https://example.test/two"])
        let counts = Bringing.Counts(tabPlaces: places, withOpen: true)
        #expect(counts.holding.count == 1)
        #expect(counts.pinned == 0)
        #expect(counts.open == 2)
        #expect(Bringing.merge(counts.holding)?.open.count == 2)
    }

    @Test func favoriteRepeatedInAWindowComesOnlyOnce() throws {
        let places = try dia(["https://example.test/pinned"], ["https://example.test/pinned", "https://example.test/open"])
        let counts = Bringing.Counts(tabPlaces: places, withOpen: true)
        #expect(counts.pinned == 1)
        #expect(counts.open == 1)
        #expect(counts.holding.first?.open.first?.url.path == "/open")
    }

    @Test func pinnedOnlyImportKeepsItsExistingChoice() throws {
        let places = try dia([], ["https://example.test/open"])
        let counts = Bringing.Counts(tabPlaces: places)
        #expect(counts.holding.isEmpty)
        #expect(counts.open == 0)
    }

    @Test func diaTabsReachTheSessionAndRepeatedImportDoesNotDuplicateThem() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        defer { Spaces.write(previousSpaces) }
        // The pins every space shares are one row every window reads: the
        // favorite brought here stayed in the test world and headed every
        // test window after it (m4: an extra tab in MailNavigationTests,
        // DocumentPiPTests and KeptBoundaryTests, and this test's second
        // import finding its pin already there). Kept as they were, less
        // any this test left in an earlier run.
        let pins = Session.Shape(tabs: Session.read(space: Space.pinsID).tabs.filter { !$0.url.hasPrefix("https://example.test/") }, active: 0)
        Session.write(now: true, space: Space.pinsID, pins)
        defer { Session.write(now: true, space: Space.pinsID, pins) }
        let source = Chromium.Source(name: "Dia", folder: "Yab missing import fixture", service: "", account: "", bundle: TabImport.dia)
        for favorites in [[], ["https://example.test/pinned"]] {
            let id = UUID(), space = UUID()
            let browser = Browser(windowID: id)
            browser.spaces = [Space(id: space, name: "Import test", icon: "", ownSignIns: false)]
            browser.spaceID = space
            defer { Session.erase(space: space) }
            let places = try dia(favorites, ["https://example.test/open"])
            let counts = Bringing.Counts(tabPlaces: places, withOpen: true)
            let took = browser.bring(counts.holding, withOpen: counts.withOpen, asSpaces: false, signIns: false, from: source)
            #expect(took.pinned == favorites.count)
            #expect(took.open == 1)
            let expected = favorites + ["https://example.test/open"]
            #expect(browser.tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString } == expected)
            #expect(Session.read(space: space, window: id).tabs.map(\.url) == expected)
            let again = browser.bring(counts.holding, withOpen: counts.withOpen, asSpaces: false, signIns: false, from: source)
            #expect(again.pinned == 0 && again.open == 0)
            #expect(browser.tabs.count == expected.count)
        }
    }

    @Test func arcSpacesKeepFoldersSplitsAndPagesRepeatedInAnotherSpace() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        defer { Spaces.write(previousSpaces) }
        // From a space of its own, so neither place lands in a space some
        // other test left pages in (the first space's row held four of
        // ArcTodayEveryWindowTests' kept pages ahead of these).
        let home = UUID()
        let browser = Browser()
        browser.spaces = [Space(id: home, name: "Import test", icon: "", ownSignIns: false)]
        browser.spaceID = home
        defer { Session.erase(space: home) }
        let source = Chromium.Source(name: "Arc", folder: "Yab missing import fixture", service: "", account: "", bundle: TabImport.arc)
        let a = URL(string: "https://left.test/#one")!, b = URL(string: "https://right.test/#two")!
        let one = TabImport.Place(id: "Arc:fixture-one-\(UUID().uuidString)", name: "Work", profile: "Default", shared: true, pinned: [],
                                  kept: [TabImport.Entry(url: a, title: "Left", folder: "Work › Research"), TabImport.Entry(url: b, title: "Right")],
                                  open: [], splits: [TabImport.Split(first: a, second: b, share: 0.6)])
        let two = TabImport.Place(id: "Arc:fixture-two-\(UUID().uuidString)", name: "Another", profile: "Profile 1", shared: false,
                                  pinned: [], open: [TabImport.Entry(url: a, title: "Left again", folder: "Group")])
        let took = browser.bring([one, two], withOpen: true, asSpaces: true, signIns: false, from: source)
        #expect(took.open == 3)
        let firstSpace = try #require(browser.spaces.first { $0.origin == one.id })
        let secondSpace = try #require(browser.spaces.first { $0.origin == two.id })
        defer { Session.erase(space: firstSpace.id); Session.erase(space: secondSpace.id) }
        let first = Session.read(space: firstSpace.id), second = Session.read(space: secondSpace.id)
        #expect(first.tabs.map(\.url) == [a.absoluteString, b.absoluteString])
        #expect(first.tabs[0].folderName == "Work › Research")
        #expect(first.pairs?.first?.first == 0 && first.pairs?.first?.second == 1)
        #expect(first.pairs?.first?.share == 0.6)
        #expect(second.tabs.first?.url == a.absoluteString)
        #expect(second.tabs.first?.folderToday == true)
        #expect(secondSpace.ownSignIns == true)
        #expect(secondSpace.signedInAs == "Arc:Profile 1")
        let repeated = browser.bring([one, two], withOpen: true, asSpaces: true, signIns: false, from: source)
        #expect(repeated.spaces == 0 && repeated.open == 0)
        #expect(Session.read(space: firstSpace.id).pairs?.count == 1)
    }

    @Test func arcTabNamesComeAsNamesOnScreenAndInUnopenedSpaces() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        defer { Spaces.write(previousSpaces) }
        let browser = Browser()
        let source = Chromium.Source(name: "Arc", folder: "Yab missing import fixture", service: "", account: "", bundle: TabImport.arc)
        let pin = URL(string: "https://named-pin.test/")!, kept = URL(string: "https://named-kept.test/")!
        func place(_ id: String) -> TabImport.Place {
            TabImport.Place(id: "Arc:\(id)-\(UUID().uuidString)", name: id, profile: "Default", shared: true,
                            pinned: [TabImport.Entry(url: pin, title: "Pin page", name: "My pin")],
                            kept: [TabImport.Entry(url: kept, title: "Kept page", name: "My kept")], open: [])
        }
        // Two places: each a space of its own, written as lines.
        let one = place("names-one"), other = place("names-two")
        browser.bring([one, other], withOpen: true, asSpaces: true, signIns: false, from: source)
        let space = try #require(browser.spaces.first { $0.origin == one.id })
        let otherSpace = browser.spaces.first { $0.origin == other.id }
        defer { Session.erase(space: space.id); otherSpace.map { Session.erase(space: $0.id) } }
        let lines = Session.read(space: space.id, window: browser.windowID).tabs
        #expect(lines.first { $0.url == kept.absoluteString }?.name == "My kept")
        // One place: into the row on screen, as tabs.
        let here = place("names-here")
        browser.bring([here], withOpen: true, asSpaces: false, signIns: false, from: source)
        let tab = browser.tabs.first { $0.address == kept || $0.pending == kept }
        #expect(tab?.name == "My kept")
        #expect(tab?.title == "Kept page")
    }

    @Test func importingIntoAnUnopenedSpaceKeepsExistingPairIndicesCorrect() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        defer { Spaces.write(previousSpaces) }
        let browser = Browser()
        let id = UUID(), origin = "Chrome:fixture-\(id.uuidString)"
        var space = Space(id: id, name: "Unopened", icon: "", ownSignIns: true,
                          paint: SpacePaint(swatch: .custom, color: browser.prefs.backdropColor, grain: 0))
        space.origin = origin
        browser.spaces.append(space)
        let a = "https://existing.test/left", b = "https://existing.test/right"
        Session.write(now: true, space: id, Session.Shape(tabs: [
            Session.Entry(url: a, title: "Left", pin: nil, name: nil, seen: nil),
            Session.Entry(url: b, title: "Right", pin: nil, name: nil, seen: nil),
        ], active: 0, pairs: [Session.Pair(first: 0, second: 1, share: 0.5)]))
        defer { Session.erase(space: id) }
        let source = Chromium.Source(name: "Chrome", folder: "Yab missing import fixture", service: "", account: "", bundle: "com.google.Chrome")
        let place = TabImport.Place(id: origin, name: "Unopened", profile: "Profile 1", shared: false,
            pinned: [TabImport.Entry(url: URL(string: "https://new.test/pin")!, title: "Pin")],
            kept: [TabImport.Entry(url: URL(string: "https://new.test/kept")!, title: "Kept")], open: [])
        browser.bring([place], withOpen: true, asSpaces: true, signIns: false, from: source)
        let shape = Session.read(space: id)
        let pair = try #require(shape.pairs?.first)
        #expect(shape.tabs[pair.first].url == a && shape.tabs[pair.second].url == b)
        #expect(shape.active == pair.first)
    }

    @Test func aSingleNondefaultProfileGetsItsOwnSigninStore() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previousSpaces = Spaces.read()
        defer { Spaces.write(previousSpaces) }
        let browser = Browser()
        let source = Chromium.Source(name: "Aside", folder: "Yab missing import fixture", service: "", account: "", bundle: AsideImport.bundle)
        let place = TabImport.Place(id: "Aside:fixture-\(UUID().uuidString)", name: "Work", profile: "Profile 1", shared: false,
                                   pinned: [], open: [TabImport.Entry(url: URL(string: "https://work.test/")!, title: "Work")])
        let oldSpace = browser.spaceID
        browser.bring([place], withOpen: true, asSpaces: false, signIns: false, from: source)
        let imported = try #require(browser.spaces.first { $0.origin == place.id })
        defer { Session.erase(space: imported.id) }
        #expect(imported.id != oldSpace)
        #expect(imported.ownSignIns == true && imported.signedInAs == "Aside:Profile 1")
        #expect(browser.prefs.usesSpaces)
    }

    @Test func cookiesForProfilesWithoutTabsKeepSeparateAccounts() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read()
        defer { Spaces.write(previous) }
        let browser = Browser()
        let source = Chromium.Source(name: "Cookie fixture \(UUID().uuidString)", folder: "Missing", service: "", account: "", bundle: "")
        #expect(browser.cookieSpaces(for: "Default", name: "Personal", from: source) == [nil])
        let first = try #require(browser.cookieSpaces(for: "Profile 1", name: "Work", from: source).first!)
        let second = try #require(browser.cookieSpaces(for: "Profile 2", name: "Other", from: source).first!)
        #expect(first != second)
        #expect(browser.spaces.first { $0.id == first }?.signedInAs == "\(source.name):Profile 1")
        #expect(browser.spaces.first { $0.id == second }?.ownSignIns == true)
        let count = browser.spaces.count
        #expect(browser.cookieSpaces(for: "Profile 1", name: "Renamed", from: source) == [first])
        #expect(browser.spaces.count == count)
    }
}
