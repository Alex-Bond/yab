import Foundation
import SQLite3
import Testing
@testable import Fast

// Dia's tabs.db once decrypted: its sidebar's folders, folders in folders,
// what is deleted or closed left out (Horizon S on X, 2026-10-16). The
// decryption itself is held to Dia's own SQLCipher by evals/dia-import.
struct DiaTabsDBTests {
    /// A tabs.db as Dia lays it out, its tables as Dia 1.52 and 1.53 have
    /// them, and its bytes.
    private func database(_ rows: String) throws -> Data {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("tabs.db", """
            CREATE TABLE nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
              parent_id INTEGER, "order" INTEGER NOT NULL, deleted_at DATETIME, space_id TEXT NOT NULL DEFAULT '');
            CREATE TABLE spaces (id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, creation_date DATE NOT NULL,
              last_updated_at DATE NOT NULL, theme TEXT NOT NULL DEFAULT 'neutral');
            CREATE TABLE tab_groups (id TEXT NOT NULL PRIMARY KEY, node_id INTEGER NOT NULL, creation_date DATE NOT NULL,
              title TEXT, theme TEXT NOT NULL DEFAULT 'neutral', icon TEXT, last_closed_at DATETIME, title_source TEXT,
              icon_source TEXT, behavior TEXT);
            CREATE TABLE content_panes (id TEXT NOT NULL PRIMARY KEY, node_id INTEGER NOT NULL, creation_date DATE NOT NULL,
              last_active_date DATE, tab_session_id INTEGER, custom_title TEXT, custom_icon TEXT, variant TEXT);
            CREATE TABLE web_contents (id INTEGER PRIMARY KEY AUTOINCREMENT, content_pane_id TEXT NOT NULL, url TEXT NOT NULL, title TEXT);
            \(rows)
            """)
        sqlite3_close(db)
        return try Data(contentsOf: fixture.root.appendingPathComponent("tabs.db"))
    }

    /// A tab node and its page: node `id`, under `parent` at `order`.
    private func tab(_ id: Int, _ parent: Int, _ order: Int, _ url: String, _ title: String, name: String? = nil, deleted: Bool = false) -> String {
        let named = name.map { "'\($0)'" } ?? "NULL"
        return """
            INSERT INTO nodes VALUES (\(id), 'tab', 't\(id)', \(parent), \(order), \(deleted ? "'2026-10-01'" : "NULL"), '');
            INSERT INTO nodes VALUES (\(id + 1000), 'content_pane', 'p\(id)', \(id), 0, NULL, '');
            INSERT INTO content_panes (id, node_id, creation_date, custom_title, variant) VALUES ('p\(id)', \(id + 1000), 0, \(named), 'web_content');
            INSERT INTO web_contents (content_pane_id, url, title) VALUES ('p\(id)', '\(url)', '\(title)');
            """
    }

    private func folder(_ id: Int, _ parent: Int?, _ order: Int, _ title: String, closed: Bool = false) -> String {
        """
        INSERT INTO nodes VALUES (\(id), 'group', 'g\(id)', \(parent.map(String.init) ?? "NULL"), \(order), NULL, '');
        INSERT INTO tab_groups (id, node_id, creation_date, title, last_closed_at) VALUES ('g\(id)', \(id), 0, '\(title)', \(closed ? "'2026-10-01'" : "NULL"));
        """
    }

    private var horizon: String {
        """
        INSERT INTO spaces VALUES ('S', 'Personal', 0, 0, 'blue');
        INSERT INTO nodes VALUES (1, 'favorites', 'f', NULL, 0, NULL, 'S');
        INSERT INTO nodes VALUES (2, 'pinned_container', 'p', NULL, 0, NULL, 'S');
        INSERT INTO nodes VALUES (3, 'window', 'w', NULL, 0, NULL, 'S');
        INSERT INTO nodes VALUES (4, 'window', 'w2', NULL, 0, '2026-10-01', 'S');
        \(tab(10, 1, 0, "https://mail.example.com/", "Mail"))
        \(folder(20, 2, 0, "Basics"))
        \(tab(21, 20, 0, "https://basics.example.com/", "Basics"))
        \(folder(22, 20, 2, "Docs"))
        \(tab(23, 22, 0, "https://docs.example.com/", "Docs"))
        \(tab(24, 22, 1, "https://gone.example.com/", "Gone", deleted: true))
        \(tab(25, 2, 1, "https://loose.example.com/", "Loose"))
        \(folder(30, 2, 3, "VUE"))
        \(tab(31, 30, 0, "https://vue.example.com/", "Vue", name: "Router"))
        \(tab(40, 3, 0, "https://news.example.com/", "News"))
        \(folder(41, 3, 1, "Research"))
        \(tab(42, 41, 0, "https://research.example.com/", "Research"))
        \(tab(43, 3, 2, "dia://settings", "Settings"))
        \(tab(50, 4, 0, "https://closed-window.example.com/", "Closed"))
        \(folder(60, nil, 0, "Closed folder", closed: true))
        \(tab(61, 60, 0, "https://closed-folder.example.com/", "Closed"))
        """
    }

    @Test func pinnedFoldersComeWithTheirNestingAndOrder() throws {
        let spaces = try #require(DiaTabsDB.sidebar(try database(horizon)))
        #expect(spaces.count == 1)
        let space = spaces[0]
        #expect(space.title == "Personal")
        #expect(space.favorites.map(\.url.host) == ["mail.example.com"])
        #expect(space.pinned.map(\.url.host) == ["basics.example.com", "docs.example.com", "loose.example.com", "vue.example.com"])
        #expect(space.pinned.map(\.folder) == ["Basics", "Basics › Docs", nil, "VUE"])
        #expect(space.pinned.map(\.path) == [nil, ["Basics", "Docs"], nil, nil])
        #expect(space.pinned[3].name == "Router")
        // Today's: the group's name on its tab; Dia's own pages left out.
        #expect(space.open.map(\.url.host) == ["news.example.com", "research.example.com"])
        #expect(space.open.map(\.folder) == [nil, "Research"])
    }

    @Test func aProfilesSpaceIsThePlaceItsScriptingGave() throws {
        let spaces = try #require(DiaTabsDB.sidebar(try database(horizon)))
        let places = DiaTabsDB.places(spaces, folder: "Profile 1", names: ["Profile 1": "Work"])
        #expect(places.map(\.id) == ["Dia:Profile 1"])
        #expect(places.map(\.name) == ["Work"])
        #expect(places[0].profile == "Profile 1" && !places[0].shared && places[0].isProfile)
        #expect(places[0].pinned.count == 1 && places[0].kept.count == 4 && places[0].open.count == 2)
    }

    @Test func tablesOfAnotherShapeGiveNothing() throws {
        let data = try database("DROP TABLE tab_groups;")
        #expect(DiaTabsDB.sidebar(data) == nil)
        #expect(DiaTabsDB.sidebar(Data(repeating: 7, count: 8192)) == nil)
    }

    @Test func dataThatIsNotDiasDoesNotDecrypt() {
        let page = Data((0..<8192).map { UInt8($0 % 251) })
        #expect(DiaTabsDB.decrypt(db: page, wal: nil, key: [UInt8](repeating: 1, count: 32)) == nil)
        #expect(DiaTabsDB.decrypt(db: Data(), wal: nil, key: [UInt8](repeating: 1, count: 32)) == nil)
    }

    @Test func theLiteralIsFoundWhereverItIs() {
        let literal = Data((0..<32).map { UInt8($0 * 7 % 256) })
        var bytes = Data("noise\0".utf8)
        bytes.append(Data(literal.base64EncodedString().utf8))
        bytes.append(0)
        // Longer base64 runs and ones of another length aren't it.
        bytes.append(Data(("x" + literal.base64EncodedString()).utf8))
        bytes.append(0)
        bytes.append(Data("QUJD=\0tail".utf8))
        #expect(DiaTabsDB.constants(inBytes: bytes) == [literal])
    }

    @Test func theKeyFollowsTheContext() {
        let root = [UInt8](repeating: 3, count: 16)
        let constant = Data(repeating: 9, count: 32)
        let a = DiaTabsDB.key(root: root, context: "profile/Default/tabs", constant: constant)
        let b = DiaTabsDB.key(root: root, context: "profile/Profile 1/tabs", constant: constant)
        #expect(a.count == 32 && b.count == 32 && a != b)
    }
}
