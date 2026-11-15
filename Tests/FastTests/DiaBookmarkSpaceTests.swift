import Foundation
import Testing
import SyncKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct DiaBookmarkSpaceTests {
    @Test func diaProfilesKeepTheirCollectionsAndRepeatIntoRenamedSpaces() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let tag = UUID().uuidString
        let common = "https://common.test/\(tag)"
        func site(_ name: String, _ url: String) -> [String: Any] {
            ["type": "url", "name": name, "url": url]
        }
        for profile in ["Default", "Profile 1"] {
            try fixture.json("\(profile)/Bookmarks", ["roots": ["bookmark_bar": ["children": [
                site("Common", common),
                ["type": "folder", "name": "Reading", "children": [site(profile, "https://unique.test/\(profile == "Default" ? "home" : "work")/\(tag)")]]
            ]]]])
        }
        try fixture.json("Profile 1/AccountBookmarks", ["roots": ["bookmark_bar": ["children": [site("Common", common)]]]])
        let source = fixture.source(try #require(Chromium.known.first { $0.bundle == TabImport.dia }))
        let previous = Spaces.read()
        let sharing = Spaces.sharing
        let browser = Browser()
        let original = browser.bookmarks.roots
        defer {
            browser.bookmarks.replaceAll(with: original)
            for space in browser.spaces where !previous.contains(where: { $0.id == space.id }) { Session.erase(space: space.id) }
            Spaces.write(previous)
            Spaces.sharing = sharing
        }
        browser.bookmarks.replaceAll(with: [.site("Global", URL(string: "https://global.test/")!)])
        // The same identities Dia's tab importer gives its profile Places.
        let first = browser.spaceID
        let work = UUID()
        browser.spaces = [Space(id: first, name: "Home", icon: "", ownSignIns: false),
                          Space(id: work, name: "Renamed", icon: "", ownSignIns: true)]
        browser.spaces[0].origin = "Dia:Default"
        browser.spaces[1].origin = "Dia:Profile 1"
        browser.spaces[1].signedInAs = "Dia:Profile 1"
        for folder in source.profiles {
            let nodes = Chromium.bookmarks(inProfile: folder)
            #expect(Bookmarks.count(nodes) == 2)
            #expect(browser.takeProfileBookmarks(nodes, profile: folder.lastPathComponent, name: "Same name", from: source) == 2)
            #expect(browser.takeProfileBookmarks(nodes, profile: folder.lastPathComponent, name: "Changed name", from: source) == 0)
        }
        #expect(browser.spaces.count == 2)
        for (id, own, other) in [(first, "home", "work"), (work, "work", "home")] {
            let urls = Bookmarks.urls(browser.bookmarks.barRoots(in: id)).map(\.absoluteString)
            #expect(urls.contains(common))
            #expect(urls.contains("https://unique.test/\(own)/\(tag)"))
            #expect(!urls.contains("https://unique.test/\(other)/\(tag)"))
            #expect(urls.contains("https://global.test/"))
        }
        // Modern Dia can have several Spaces within the same profile.
        let secondWork = browser.bookmarks.barRoots(in: UUID(), profile: "Dia:Profile 1:another-space")
        #expect(Bookmarks.urls(secondWork).map(\.absoluteString).contains("https://unique.test/work/\(tag)"))
        #expect(!Bookmarks.urls(secondWork).map(\.absoluteString).contains("https://unique.test/home/\(tag)"))
        // Use a deterministic, exactly representable timestamp for the sync
        // fixture. Date's reference-date/Unix conversion can round Date()
        // by a fraction of a microsecond, unrelated to collection identity.
        func dated(_ node: Bookmark) -> Bookmark {
            var node = node
            if node.added != nil { node.added = Date(timeIntervalSince1970: 1_700_000_000) }
            node.children = node.children?.map(dated)
            return node
        }
        browser.bookmarks.replaceAll(with: browser.bookmarks.roots.map(dated))
        let saved = try JSONEncoder().encode(browser.bookmarks.roots)
        let reopened = try JSONDecoder().decode([Bookmark].self, from: saved)
        #expect(reopened == browser.bookmarks.roots)
        SyncShapes.register()
        let journal = try Journal(path: nil, device: "dia-fixture")
        try journal.reconcile(SyncShapes.bookmark, SyncShapes.bookmarks(reopened, orders: [:]))
        #expect(SyncShapes.bookmarks(from: journal.all(SyncShapes.bookmark)) == reopened)
    }

    @Test func bookmarksAloneCreateAProfileSpaceAndReuseIt() throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read()
        let browser = Browser()
        let original = browser.bookmarks.roots
        defer {
            browser.bookmarks.replaceAll(with: original)
            for space in browser.spaces where !previous.contains(where: { $0.id == space.id }) { Session.erase(space: space.id) }
            Spaces.write(previous)
        }
        browser.bookmarks.replaceAll(with: [])
        let source = try #require(Chromium.known.first { $0.bundle == TabImport.dia })
        let profile = "Profile \(UUID().uuidString)"
        let nodes = [Bookmark.site("Work", URL(string: "https://work.test/")!)]
        #expect(browser.takeProfileBookmarks(nodes, profile: profile, name: "Work", from: source) == 1)
        let space = try #require(browser.spaces.first { $0.signedInAs == "Dia:\(profile)" })
        #expect(space.ownSignIns)
        #expect(browser.bookmarks.barRoots(in: space.id).map(\.title) == ["Work"])
        #expect(browser.bookmarks.barRoots(in: browser.spaceID).isEmpty)
        #expect(browser.takeProfileBookmarks(nodes, profile: profile, name: "Renamed", from: source) == 0)
    }
}
