import Foundation
import SQLite3
import Testing
@testable import Fast

@MainActor
struct ImportedHistoryPageTests {
    static let when = Date(timeIntervalSince1970: 1_793_100_000)

    static func listed(_ diary: Diary, from: Double? = nil) async -> [[String: Any]] {
        await withCheckedContinuation { done in
            diary.list(before: nil, from: from, limit: 80) { done.resume(returning: $0) }
        }
    }

    @Test func arcProfilesWithLiveWalReachTheHistoryPageQuery() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let source = fixture.source(try #require(Chromium.known.first { $0.name == "Arc" }))
        let stamp = Int64((Self.when.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let db = try fixture.database("Default/History", """
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,typed_count INTEGER,hidden INTEGER);
        INSERT INTO urls VALUES('https://arc-history.invalid/default','Arc default',4,\(stamp),2,0);
        INSERT INTO urls VALUES('https://arc-history.invalid/hidden','Hidden',1,\(stamp),0,1);
        INSERT INTO urls VALUES('arc://settings','Settings',1,\(stamp),0,0);
        """)
        defer { sqlite3_close(db) }
        let other = try fixture.database("9D3D3AB4-12BD-41DC-ABCD-21001A1B3C44/History", """
        CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,typed_count INTEGER,hidden INTEGER);
        INSERT INTO urls VALUES('https://arc-history.invalid/other','Arc other profile',2,\(stamp - 1_000_000),0,0);
        """)
        defer { sqlite3_close(other) }
        let file = fixture.root.appendingPathComponent("Default/History")
        let original = try Data(contentsOf: file)
        let walFile = URL(fileURLWithPath: file.path + "-wal")
        let wal = try Data(contentsOf: walFile)
        let places = Chromium.places(in: source)
        #expect(places.count == 2)
        #expect(places.first?.last == Self.when)
        #expect(places.first?.typed == 2)
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: walFile) == wal)

        let history = History(file: fixture.root.appendingPathComponent("yab/history.json"))
        history.take(History.gather(places))
        let diary = Diary.scratch(fixture.root.appendingPathComponent("yab/diary.sqlite"))
        diary.absorb(history.everything())
        let rows = await Self.listed(diary)
        #expect(rows.compactMap { $0["title"] as? String } == ["Arc default", "Arc other profile"])
        #expect(rows.first?["at"] as? Double == Self.when.timeIntervalSince1970 * 1000)
        #expect(await Self.listed(diary, from: Self.when.timeIntervalSince1970 - 0.5).count == 1)
        await history.flush()
        let reopened = Diary.scratch(fixture.root.appendingPathComponent("yab/diary.sqlite"))
        #expect(await Self.listed(reopened).count == 2)
        #expect(History(file: fixture.root.appendingPathComponent("yab/history.json")).everything().count == 2)
    }

    @Test func csvReachesTheHistoryPageWithoutTabsOrSpaces() async throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let csv = """
        URL,Title,Visit Time,Visit Count
        https://csv-history.invalid/unix,"CSV, Unix",1793100000000,7
        https://csv-history.invalid/chromium,CSV Chromium,13437573600000000,3
        https://csv-history.invalid/iso,CSV ISO,2026-10-27T10:00:00Z,2
        """
        try fixture.write("History.csv", Data(csv.utf8))
        let text = try #require(HistoryFile.text(of: fixture.root.appendingPathComponent("History.csv")))
        let places = try #require(HistoryFile.places(in: text, fallback: Self.when))
        #expect(places.count == 3)
        #expect(places[0].last == Self.when)
        #expect(places[1].last == Self.when)
        let gathered = History.gather(places)
        let history = History(file: fixture.root.appendingPathComponent("yab/history.json"))
        #expect(history.add(gathered) == 3)
        let diary = Diary.scratch(fixture.root.appendingPathComponent("yab/diary.sqlite"))
        diary.absorb(gathered.traces)
        let rows = await Self.listed(diary)
        #expect(Set(rows.compactMap { $0["title"] as? String }) == ["CSV, Unix", "CSV Chromium", "CSV ISO"])
        let id = UUID()
        let browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        browser.query.placeFilter = 0
        #expect(browser.visitItems(rows, words: "").count == 3)
        diary.absorb(gathered.traces)
        #expect(await Self.listed(diary).count == 3)
        await history.flush()
        let reopened = Diary.scratch(fixture.root.appendingPathComponent("yab/diary.sqlite"))
        #expect(await Self.listed(reopened).count == 3)
    }
}
