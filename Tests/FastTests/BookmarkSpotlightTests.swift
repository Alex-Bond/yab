import Foundation
import Testing
@testable import Fast

struct BookmarkSpotlightTests {
    @Test func onlySavedWebPagesAreSearchable() {
        let first = Bookmark.site("First", URL(string: "https://example.com/one")!)
        let second = Bookmark.site("Second", URL(string: "http://example.org/two")!)
        let internalPage = Bookmark(title: "Internal", url: "yab://bookmarks", children: nil)
        let localFile = Bookmark(title: "Local", url: "file:///tmp/page.html", children: nil)
        let roots = [first, .folder("Work", [second, internalPage, localFile])]

        let entries = BookmarkSpotlight.entries(in: roots)
        #expect(Set(entries.keys) == [first.id.uuidString, second.id.uuidString])
        #expect(entries[first.id.uuidString]?.title == "First")
        #expect(entries[second.id.uuidString]?.url == "http://example.org/two")

        // Changing a title or folder keeps the item's stable Spotlight ID.
        let moved = BookmarkSpotlight.entries(in: [.folder("Elsewhere", [
            Bookmark(id: first.id, title: "Renamed", url: first.url, children: nil),
        ])])
        #expect(moved[first.id.uuidString]?.spotlightID == entries[first.id.uuidString]?.spotlightID)
        #expect(moved[first.id.uuidString]?.title == "Renamed")
    }

    @Test func fingerprintIgnoresFolderAndTraversalOrderButTracksContent() throws {
        let first = Bookmark.site("First", URL(string: "https://example.com/one")!)
        let second = Bookmark.site("Second", URL(string: "https://example.org/two")!)
        let original = BookmarkSpotlight.entries(in: [first, .folder("Work", [second])])
        let rearranged = BookmarkSpotlight.entries(in: [.folder("Elsewhere", [second, first])])
        let renamed = BookmarkSpotlight.entries(in: [
            Bookmark(id: first.id, title: "New title", url: first.url, children: nil), second,
        ])

        #expect(try BookmarkSpotlight.fingerprint(original) == BookmarkSpotlight.fingerprint(rearranged))
        #expect(try BookmarkSpotlight.fingerprint(original) != BookmarkSpotlight.fingerprint(renamed))
        #expect(try BookmarkSpotlight.fingerprint(original).count < 250)
    }
}
