import Foundation
import Testing
@testable import Fast

// When each bookmark was kept: written with it, brought from the browser
// it came from, and what Recently Added lists by it.
struct BookmarkDatesTests {
    static func site(_ title: String, _ at: Double?) -> Bookmark {
        .site(title, URL(string: "https://\(title.lowercased()).example/")!, added: at.map(Date.init(timeIntervalSince1970:)))
    }

    @Test func aFileWrittenBeforeDatesStillReads() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"A","url":"https://a.example/"}]"#
        let list = try JSONDecoder().decode([Bookmark].self, from: Data(old.utf8))
        #expect(list.first?.title == "A")
        #expect(list.first?.added == nil)
        // And a date written is read back.
        let kept = Self.site("B", 1_700_000_000)
        let back = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(kept))
        #expect(back.added == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func oneKeptHereIsDatedNow() {
        let before = Date()
        let made = Bookmark.site("", URL(string: "https://a.example/")!)
        #expect(made.added.map { $0 >= before && $0 <= Date() } == true)
    }

    @Test func recentlyAddedIsNewestFirstAcrossFolders() {
        let work = Bookmark.folder("Work", [Self.site("A", 100), Self.site("Undated", nil), .folder("Deep", [Self.site("B", 300)])], added: Date(timeIntervalSince1970: 50))
        let roots = [Self.site("C", 200), work, Self.site("D", 300)]
        let recent = Bookmarks.recent(roots)
        // B and D kept at the same moment: the one further down first.
        #expect(recent.map(\.node.title) == ["D", "B", "C", "A"])
        #expect(recent.map { $0.folder?.title } == [nil, "Deep", nil, "Work"])
    }

    @Test func chromeSaysWhenInMicrosecondsSince1601() {
        let raw: [[String: Any]] = [
            ["type": "folder", "name": "Work", "date_added": "13340000000000000", "children": [
                ["type": "url", "name": "A", "url": "https://a.example/", "date_added": "13345000000000000"],
                ["type": "url", "name": "B", "url": "https://b.example/", "date_added": "0"],
            ]],
        ]
        let tree = Chromium.nodes(in: raw)
        #expect(tree.first?.added == Date(timeIntervalSince1970: 13_340_000_000 - 11_644_473_600))
        #expect(tree.first?.children?.map(\.added) == [Date(timeIntervalSince1970: 13_345_000_000 - 11_644_473_600), nil])
    }

    @Test func aBookmarksFileSaysWhenInItsOwnUnits() throws {
        let text = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3 ADD_DATE="1695859200">Reading</H3>
            <DL><p>
                <DT><A HREF="https://a.example/" ADD_DATE="1695945600">A</A>
                <DT><A HREF="https://b.example/" ADD_DATE="1695945600000000">B</A>
                <DT><A HREF="https://c.example/" ADD_DATE="0">C</A>
                <DT><A HREF="https://d.example/">D</A>
                <DT><A HREF="https://e.example/" ADD_DATE="99999999999">E</A>
            </DL><p>
        </DL><p>
        """
        let folder = try #require(BookmarkFile.parse(text)?.first)
        #expect(folder.added == Date(timeIntervalSince1970: 1_695_859_200))
        let day = Date(timeIntervalSince1970: 1_695_945_600)
        // None, nothing, or a day still to come: no date.
        #expect(folder.children?.map(\.added) == [day, day, nil, nil, nil])
    }

    @Test func broughtInTheyKeepTheirDays() {
        let incoming = [Bookmark.folder("Work", [Self.site("A", 100)], added: Date(timeIntervalSince1970: 50))]
        let plan = Bookmarks.plan(incoming, into: [Self.site("B", 10)], from: "Chrome", brought: nil)
        let folder = plan.roots.last?.children?.first
        #expect(folder?.title == "Work")
        #expect(folder?.added == Date(timeIntervalSince1970: 50))
        #expect(folder?.children?.first?.added == Date(timeIntervalSince1970: 100))
    }
}
