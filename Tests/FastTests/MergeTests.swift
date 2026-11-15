import Foundation
import Testing
@testable import Fast

// What happens when something comes in a second time: bookmarks merge, a
// password only goes over an older one, history only adds.
struct MergeTests {
    static func site(_ title: String, _ url: String) -> Bookmark { .site(title, URL(string: url)!) }

    // MARK: bookmarks

    @Test func takenAgainOnlyTheNewComeIn() {
        // Brought once, then tidied: one renamed, one moved out to the top.
        var mine: [Bookmark] = [
            Self.site("Moved out", "https://b.example/"),
            .folder("Chrome", [
                Self.site("Renamed by me", "https://a.example/"),
                .folder("Work", [Self.site("C", "https://c.example/")]),
            ]),
        ]
        var chrome = mine[1].children!
        let incoming: [Bookmark] = [
            Self.site("A", "https://a.example/"),
            Self.site("B", "https://b.example/"),
            .folder("Work", [Self.site("C", "https://c.example/"), Self.site("D", "https://d.example/")]),
            .folder("New", [Self.site("E", "https://e.example/")]),
            .folder("Nothing new", [Self.site("C again", "https://c.example/")]),
        ]
        let added = Bookmarks.merge(incoming, into: &chrome, skipping: Bookmarks.addresses(mine), fresh: false)
        mine[1].children = chrome
        #expect(added == 2)
        #expect(chrome.map(\.title) == ["Renamed by me", "Work", "New"])
        #expect(chrome[1].children?.map(\.title) == ["C", "D"])
        #expect(Bookmarks.merge(incoming, into: &chrome, skipping: Bookmarks.addresses(mine + chrome), fresh: false) == 0)
    }

    @Test func anEmptyFolderComesOnlyTheFirstTime() {
        let incoming: [Bookmark] = [.folder("Empty there", []), Self.site("A", "https://a.example/")]
        var first: [Bookmark] = []
        Bookmarks.merge(incoming, into: &first, skipping: [], fresh: true)
        #expect(first.map(\.title) == ["Empty there", "A"])
        // Deleted here, then taken again: it stays deleted.
        var later: [Bookmark] = [Self.site("A", "https://a.example/")]
        Bookmarks.merge(incoming, into: &later, skipping: Bookmarks.addresses(later), fresh: false)
        #expect(later.map(\.title) == ["A"])
    }

    @Test func twoFoldersOfOneNameInOneImportStayTwo() {
        var mine: [Bookmark] = []
        let incoming: [Bookmark] = [
            .folder("Same", [Self.site("A", "https://a.example/")]),
            .folder("Same", [Self.site("B", "https://b.example/")]),
        ]
        Bookmarks.merge(incoming, into: &mine, skipping: [], fresh: true)
        #expect(mine.count == 2)
    }

    /// The whole life of one browser's bookmarks here, through `plan` and
    /// what it hands back to remember, as `take` would store and read it.
    @Test func bringDeleteBringAgain() throws {
        let chrome: [Bookmark] = [
            Self.site("A", "https://a.example/"),
            .folder("Work", [Self.site("B", "https://b.example/")]),
        ]
        func roundtrip(_ brought: Bookmarks.Brought) throws -> Bookmarks.Brought {
            try JSONDecoder().decode(Bookmarks.Brought.self, from: JSONEncoder().encode(brought))
        }

        // Into no bookmarks: at the top level.
        var plan = Bookmarks.plan(chrome, into: [], from: "Chrome", brought: nil)
        #expect(plan.added == 2)
        #expect(plan.roots.map(\.title) == ["A", "Work"])
        #expect(plan.brought.top)
        var roots = plan.roots
        var brought = try roundtrip(plan.brought)

        // Taken again, with something new: into the top level, not a new
        // folder.
        let more = chrome + [Self.site("C", "https://c.example/")]
        plan = Bookmarks.plan(more, into: roots, from: "Chrome", brought: brought)
        #expect(plan.added == 1)
        #expect(plan.roots.map(\.title) == ["A", "Work", "C"])
        roots = plan.roots
        brought = try roundtrip(plan.brought)

        // A deleted here; taken again, it stays out and is said so.
        roots.removeAll { $0.title == "A" }
        roots.append(Self.site("Mine", "https://mine.example/"))
        plan = Bookmarks.plan(more, into: roots, from: "Chrome", brought: brought)
        #expect(plan.added == 0)
        #expect(plan.held == 1)
        brought = try roundtrip(plan.brought)

        // Everything deleted: the next import is a first one.
        plan = Bookmarks.plan(more, into: [], from: "Chrome", brought: brought)
        #expect(plan.added == 3)
        #expect(plan.held == 0)
    }

    @Test func aSpaceIsAFolderEvenInNoBookmarks() {
        let plan = Bookmarks.plan([Self.site("A", "https://a.example/")], into: [], from: "Arc › Work", brought: nil, apart: true)
        #expect(plan.roots.map(\.title) == ["Arc › Work"])
        #expect(!plan.brought.top)
    }

    @Test func aDeletedFolderIsBroughtAfresh() throws {
        let chrome: [Bookmark] = [Self.site("A", "https://a.example/"), Self.site("B", "https://b.example/")]
        let mine: [Bookmark] = [Self.site("Mine", "https://mine.example/")]
        var plan = Bookmarks.plan(chrome, into: mine, from: "Chrome", brought: nil)
        #expect(plan.roots.last?.title == "Chrome")
        #expect(!plan.brought.top)
        let brought = plan.brought
        // B deleted inside the folder: held back.
        var roots = plan.roots
        roots[1].children?.removeAll { $0.title == "B" }
        plan = Bookmarks.plan(chrome, into: roots, from: "Chrome", brought: brought)
        #expect(plan.added == 0)
        #expect(plan.held == 1)
        // The folder deleted whole: everything comes again, in a new one.
        plan = Bookmarks.plan(chrome, into: mine, from: "Chrome", brought: brought)
        #expect(plan.added == 2)
        #expect(plan.held == 0)
        #expect(plan.roots.map(\.title) == ["Mine", "Chrome"])
    }

    // MARK: passwords

    @Test func aPasswordGoesOverOnlyAnOlderOne() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        #expect(Vault.replaces(theirs: later, ours: earlier))
        #expect(!Vault.replaces(theirs: earlier, ours: later))
        #expect(!Vault.replaces(theirs: later, ours: later))
        // Never used there says nothing about being newer.
        #expect(!Vault.replaces(theirs: nil, ours: earlier))
        #expect(!Vault.replaces(theirs: nil, ours: nil))
        // Never used here: any use there is newer.
        #expect(Vault.replaces(theirs: earlier, ours: nil))
    }

    @Test func ofTwoRowsForOneLoginTheLastUsedIsKept() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        // www.example.com and example.com are one host by the time they get here.
        let rows = [
            Login(host: "example.com", user: "ann", password: "old", used: old),
            Login(host: "other.example", user: "bob", password: "x", used: nil),
            Login(host: "example.com", user: "ann", password: "new", used: new),
            Login(host: "example.com", user: "ann", password: "never", used: nil),
            Login(host: "other.example", user: "bob", password: "y", used: old),
        ]
        let kept = Chromium.newest(rows)
        #expect(kept.map(\.password) == ["new", "y"])
    }

    // MARK: history

    static func place(_ url: String, count: Int = 1, days: Double = 0) -> Chromium.Place {
        Chromium.Place(url: URL(string: url)!, title: "", count: count, typed: 0, last: Date(timeIntervalSinceNow: -days * 86_400))
    }

    @Test func aHistoryFileOnlyAdds() {
        var ours = History.gather([Self.place("https://mine.example/", count: 9, days: 3)]).visits
        let file = History.gather([
            Self.place("https://mine.example/", count: 50, days: 1),
            Self.place("https://new.example/", count: 200),
        ])
        #expect(History.add(file, to: &ours) == 1)
        // Its own count kept, only told of the later visit.
        #expect(ours["mine.example"]?.count == 9)
        #expect(abs((ours["mine.example"]?.last.timeIntervalSinceNow ?? 0) + 86_400) < 5)
        // A file's place can't outrank yours by its count.
        #expect(ours["new.example"]?.count == History.fileCount)
        // Taken again, nothing more.
        #expect(History.add(file, to: &ours) == 0)
    }

    @Test func aHistoryFileAddsPastTheCap() {
        // More in memory than the file keeps, as after a busy session.
        var ours = History.gather((0..<(History.cap + 500)).map { Self.place("https://mine\($0).example/") }).visits
        let file = History.gather((0..<300).map { Self.place("https://file\($0).example/", count: 3) })
        #expect(History.add(file, to: &ours) == 300)
        #expect(ours.count == History.cap + 800)
    }

    @Test func aBrowserTakenAgainIsNotCountedTwice() {
        var ours = History.gather([Self.place("https://mine.example/", count: 4)]).visits
        let chrome = History.gather([Self.place("https://mine.example/", count: 30), Self.place("https://new.example/", count: 7)])
        History.take(chrome, into: &ours)
        History.take(chrome, into: &ours)
        #expect(ours["mine.example"]?.count == 30)
        #expect(ours["new.example"]?.count == 7)
    }
}
