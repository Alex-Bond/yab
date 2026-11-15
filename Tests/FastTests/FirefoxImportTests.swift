import Foundation
import SQLite3
import Testing
@testable import Fast

// Zen's and Firefox's places.sqlite, made here with the tables and root
// folders Firefox makes, and read back. Never a real profile.
struct FirefoxImportTests {
    static let schema = """
    CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, rev_host LONGVARCHAR,
        visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL,
        frecency INTEGER DEFAULT -1 NOT NULL, last_visit_date INTEGER, guid TEXT);
    CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER,
        visit_date INTEGER, visit_type INTEGER, session INTEGER);
    CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
        position INTEGER, title LONGVARCHAR, keyword_id INTEGER, folder_type TEXT, dateAdded INTEGER,
        lastModified INTEGER, guid TEXT);
    INSERT INTO moz_bookmarks(id, type, parent, position, title, guid) VALUES
        (1, 2, 0, 0, '', 'root________'), (2, 2, 1, 0, 'menu', 'menu________'), (3, 2, 1, 1, 'toolbar', 'toolbar_____'),
        (4, 2, 1, 2, 'tags', 'tags________'), (5, 2, 1, 3, 'unfiled', 'unfiled_____'), (6, 2, 1, 4, 'mobile', 'mobile______');
    """

    static let ini = """
    [Profile1]
    Name=old
    IsRelative=1
    Path=Profiles/old.default

    [Profile0]
    Name=default-release
    IsRelative=1
    Path=Profiles/main.default-release
    Default=1

    [Profile2]
    Name=empty
    IsRelative=1
    Path=Profiles/empty.default

    [Install4F96D1932A9F858E]
    Default=Profiles/main.default-release
    Locked=1

    [General]
    StartWithLastProfile=1
    Version=2
    """

    static func zen(_ fixture: ImportFixture) -> Firefox.Source {
        var source = Firefox.known[0]
        source.dataRoot = fixture.root
        return source
    }

    @Test func theInstallDefaultComesFirstAndProfilesWithoutPlacesAreLeftOut() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("profiles.ini", Data(Self.ini.utf8))
        for name in ["old.default", "main.default-release"] {
            sqlite3_close(try fixture.database("Profiles/\(name)/places.sqlite", Self.schema))
        }
        try fixture.write("Profiles/empty.default/prefs.js", Data())
        #expect(Self.zen(fixture).profiles.map(\.lastPathComponent) == ["main.default-release", "old.default"])
    }

    @Test func withoutProfilesIniEveryProfileFolderIsRead() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        sqlite3_close(try fixture.database("Profiles/b.second/places.sqlite", Self.schema))
        sqlite3_close(try fixture.database("Profiles/a.first/places.sqlite", Self.schema))
        #expect(Self.zen(fixture).profiles.map(\.lastPathComponent) == ["a.first", "b.second"])
    }

    @Test func bookmarksKeepTheToolbarOnTopAndTheRestAsFolders() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("Profiles/main.default-release/places.sqlite", Self.schema + """
        INSERT INTO moz_places(id, url, title) VALUES
            (10, 'https://docs.test/', 'Docs'), (11, 'https://news.test/', 'News'), (12, 'https://menu.test/', 'Menu page'),
            (13, 'place:tag=work', 'Query'), (14, 'https://later.test/', 'Later'), (15, 'https://phone.test/', 'Phone'),
            (16, 'https://tagged.test/', 'Tagged');
        INSERT INTO moz_bookmarks(id, type, fk, parent, position, title, dateAdded, guid) VALUES
            (20, 1, 11, 3, 2, 'News', 1700000000000000, 'b-news'),
            (21, 2, NULL, 3, 0, 'Work', 1700000000000000, 'f-work'),
            (22, 1, 10, 21, 0, 'Docs', 1700000000000000, 'b-docs'),
            (23, 3, NULL, 3, 1, '', 0, 's-separator'),
            (24, 1, 12, 2, 0, 'Menu page', 0, 'b-menu'),
            (25, 1, 13, 2, 1, 'Query', 0, 'b-query'),
            (26, 1, 14, 5, 0, 'Later', 0, 'b-later'),
            (27, 1, 15, 6, 0, 'Phone', 0, 'b-phone'),
            (28, 2, NULL, 4, 0, 'work', 0, 't-work'),
            (29, 1, 16, 28, 0, '', 0, 'b-tagged');
        """)
        defer { sqlite3_close(db) }
        let marks = Firefox.bookmarks(in: Self.zen(fixture))
        #expect(marks.map(\.title) == ["Work", "News", "Bookmarks Menu", "Other", "Mobile"])
        #expect(marks[0].children?.map(\.url) == ["https://docs.test/"])
        #expect(marks[0].added == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(marks[2].children?.map(\.title) == ["Menu page"])
        #expect(marks[3].children?.map(\.url) == ["https://later.test/"])
        #expect(marks[4].children?.map(\.url) == ["https://phone.test/"])
        #expect(!Bookmarks.urls(marks).contains { $0.host == "tagged.test" })
    }

    @Test func historyCountsTypedVisitsAndLeavesOutHiddenAndNonWebPlaces() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("Profiles/main.default-release/places.sqlite", Self.schema + """
        INSERT INTO moz_places(id, url, title, visit_count, hidden, last_visit_date) VALUES
            (1, 'https://old.test/', 'Old', 2, 0, 1600000000000000),
            (2, 'https://new.test/', 'New', 3, 0, 1700000000000000),
            (3, 'https://hidden.test/frame', 'Frame', 1, 1, 1700000000000001),
            (4, 'about:config', 'Config', 4, 0, 1700000000000002),
            (5, 'https://bookmarked-only.test/', 'Never visited', 0, 0, NULL);
        INSERT INTO moz_historyvisits(place_id, visit_date, visit_type) VALUES
            (2, 1690000000000000, 2), (2, 1700000000000000, 2), (2, 1650000000000000, 1), (1, 1600000000000000, 1);
        """)
        defer { sqlite3_close(db) }
        let places = Firefox.places(in: Self.zen(fixture))
        #expect(places.map(\.url.absoluteString) == ["https://new.test/", "https://old.test/"])
        #expect(places.map(\.typed) == [2, 0])
        #expect(places.map(\.count) == [3, 2])
        #expect(places.first?.last == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Firefox.places(in: Self.zen(fixture), limit: 1).count == 1)
    }

    /// Firefox holds places.sqlite with an exclusive lock and keeps its
    /// newest rows in the log: the copy has to bring both, and the
    /// browser's own files stay as they were.
    @Test func readsWhileTheBrowserHoldsItLockedWithRowsStillInTheLog() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("Profiles/main.default-release/places.sqlite", """
        PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        """ + Self.schema + """
        INSERT INTO moz_places(id, url, title, visit_count, last_visit_date) VALUES (1, 'https://live.test/', 'Live', 1, 1700000000000000);
        INSERT INTO moz_bookmarks(id, type, fk, parent, position, title, guid) VALUES (20, 1, 1, 3, 0, 'Live', 'b-live');
        """)
        defer { sqlite3_close(db) }
        let file = fixture.root.appendingPathComponent("Profiles/main.default-release/places.sqlite")
        let original = try Data(contentsOf: file)
        let wal = try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal"))
        #expect(!wal.isEmpty)
        let source = Self.zen(fixture)
        #expect(Firefox.places(in: source).map(\.url.host) == ["live.test"])
        #expect(Firefox.bookmarks(in: source).map(\.title) == ["Live"])
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal")) == wal)
    }

    @Test func aSecondProfileAddsOnlyWhatTheFirstDidNotHave() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("profiles.ini", Data(Self.ini.utf8))
        for (name, urls) in [("main.default-release", ["https://shared.test/"]), ("old.default", ["https://shared.test/", "https://only-old.test/"])] {
            let rows = urls.enumerated().map { "(\($0.offset + 10), '\($0.element)', 'Page')" }.joined(separator: ",")
            let marks = urls.enumerated().map { "(\($0.offset + 20), 1, \($0.offset + 10), 3, \($0.offset), 'Page', 'b\($0.offset)')" }.joined(separator: ",")
            sqlite3_close(try fixture.database("Profiles/\(name)/places.sqlite", Self.schema + """
            INSERT INTO moz_places(id, url, title) VALUES \(rows);
            INSERT INTO moz_bookmarks(id, type, fk, parent, position, title, guid) VALUES \(marks);
            """))
        }
        let urls = Bookmarks.urls(Firefox.bookmarks(in: Self.zen(fixture))).map(\.absoluteString)
        #expect(urls.sorted() == ["https://only-old.test/", "https://shared.test/"])
    }

    @Test func iniSectionsIgnoreCommentsAndSpaces() {
        let sections = Firefox.sections(of: "; a comment\n[Profile0]\n Path = Profiles/x.default \n# another\nDefault=1\n")
        #expect(sections.count == 1)
        #expect(sections[0].values == ["Path": "Profiles/x.default", "Default": "1"])
    }
}
