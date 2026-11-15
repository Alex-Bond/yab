import Foundation
import SQLite3
import Testing
@testable import Fast

/// Settings' Bring In counts (row 1039): history counted by SQLite as the
/// list would have it, and a part read again only when its files change.
struct BringCountsTests {
    @Test func placeCountMatchesThePlacesListed() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("Default/History", """
        CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,typed_count INTEGER,hidden INTEGER);
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<500)
        INSERT INTO urls SELECT 'https://history.test/'||i,'Page '||i,1,13300000000000000+i,0,0 FROM n;
        INSERT INTO urls VALUES('https://hidden.test/','Hidden',4,13300000000000000,0,1);
        INSERT INTO urls VALUES('https://never.test/','Never visited',0,13300000000000000,0,0);
        INSERT INTO urls VALUES('chrome://settings/','Settings',9,13300000000000000,0,0);
        INSERT INTO urls VALUES('http://plain.test/','Plain',2,13300000000000000,0,0);
        """)
        sqlite3_close(db)
        let source = fixture.source(Chromium.known[1])
        #expect(Chromium.places(in: source).count == 501)
        #expect(Chromium.placeCount(in: source) == 501)
    }

    @Test func stampsChangeOnlyWithTheirFiles() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.json("Default/Bookmarks", ["roots": [:]])
        try fixture.json("Default/Preferences", [:])
        let source = fixture.source(Chromium.known[1])
        let before = BringStamp.stamps(source)
        #expect(BringStamp.stamps(source) == before)
        try fixture.json("Default/Bookmarks", ["roots": ["other": ["children": []]]])
        let after = BringStamp.stamps(source)
        #expect(after[.bookmarks] != before[.bookmarks])
        for part in BringPart.allCases where part != .bookmarks {
            #expect(after[part] == before[part])
        }
    }
}
