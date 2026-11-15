import Foundation
import SQLite3
import Testing
@testable import Fast

struct ImportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yab-import-test-\(UUID().uuidString)")

    func write(_ name: String, _ data: Data) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func json(_ name: String, _ value: Any) throws { try write(name, JSONSerialization.data(withJSONObject: value)) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func source(_ known: Chromium.Source) -> Chromium.Source { var source = known; source.dataRoot = root; return source.authorizingImport() }

    func database(_ name: String, _ sql: String) throws -> OpaquePointer {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        #expect(sqlite3_open(file.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw Chromium.Trouble.unreadable }
        return db
    }
}

struct BrowserImportTests {
    @Test func closedWALDatabaseCanBeReadWithoutChangingTheSource() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let handle = try fixture.database("History", """
        PRAGMA journal_mode=WAL;
        CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,typed_count INTEGER,last_visit_time INTEGER,hidden INTEGER);
        INSERT INTO urls VALUES('https://closed.test/','Closed',3,1,13300000000000000,0);
        """)
        sqlite3_close(handle)
        let file = fixture.root.appendingPathComponent("History")
        let original = try Data(contentsOf: file)
        #expect(try Chromium.placeRows(in: file).count == 1)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: Chromium.known)
    func everySourceReadsProfilesWithoutPasswords(_ known: Chromium.Source) throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.json("Default/Bookmarks", ["roots": ["bookmark_bar": ["children": [
            ["type": "folder", "name": "Work", "children": [["type": "url", "name": "Docs", "url": "https://docs.test/", "date_added": "13300000000000000"]]]]]]])
        let history = try fixture.database("Profile 2/History", "CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,typed_count INTEGER,hidden INTEGER); INSERT INTO urls VALUES('https://history.test/','History',3,13300000000000000,2,0)")
        defer { sqlite3_close(history) }
        let cookies = try fixture.database("Default/Network/Cookies", "CREATE TABLE cookies(host_key TEXT,has_expires INTEGER,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER); INSERT INTO cookies VALUES('.signin.test',0,0,1,1)")
        defer { sqlite3_close(cookies) }
        let wallet = try fixture.database("Default/Web Data", "CREATE TABLE local_addresses(id TEXT); INSERT INTO local_addresses VALUES('address')")
        defer { sqlite3_close(wallet) }
        let source = fixture.source(known)
        #expect(source.profiles.map(\.lastPathComponent) == ["Default", "Profile 2"])
        #expect(source.files.isEmpty)
        #expect(Bookmarks.count(Chromium.bookmarks(in: source)) == 1)
        #expect(Chromium.places(in: source).map(\.url.host) == ["history.test"])
        #expect(Chromium.cookieCount(source) == 1)
        #expect(Chromium.cookieTally(source).sites == 1)
        #expect(Chromium.walletCount(source).addresses == 1)
    }

    @Test func accountBookmarksJoinTheProfilesOwnByFolder() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        func site(_ name: String, _ url: String) -> [String: Any] { ["type": "url", "name": name, "url": url] }
        func folder(_ name: String, _ kids: [[String: Any]]) -> [String: Any] { ["type": "folder", "name": name, "children": kids] }
        try fixture.json("Default/AccountBookmarks", ["roots": [
            "bookmark_bar": ["children": [site("Mail", "https://mail.test/"), folder("Work", [site("Docs", "https://docs.test/"), site("Plan", "https://plan.test/")])]],
            "other": ["children": [site("Read", "https://read.test/")]]]])
        try fixture.json("Default/Bookmarks", ["roots": [
            "bookmark_bar": ["children": [site("Mail", "https://mail.test/"), site("Local", "https://local.test/"),
                                          folder("Work", [site("Docs", "https://docs.test/"), site("Desk", "https://desk.test/")]),
                                          folder("Home", [site("Mail", "https://mail.test/")])]],
            "synced": ["children": [site("Phone", "https://phone.test/")]]]])
        // A profile with only the account's file is still a profile.
        try fixture.json("Profile 2/AccountBookmarks", ["roots": ["bookmark_bar": ["children": [site("Solo", "https://solo.test/")]]]])
        let source = fixture.source(Chromium.known[1])
        #expect(source.profiles.map(\.lastPathComponent) == ["Default", "Profile 2"])
        let marks = Chromium.bookmarks(in: source)
        func outline(_ nodes: [Bookmark]) -> [String] {
            nodes.map { $0.isFolder ? "\($0.title)[\(outline($0.children ?? []).joined(separator: ","))]" : $0.title }
        }
        // Account first, the Mac's after; Mail and Docs once in their
        // folder, Mail again in Home where it was filed too.
        #expect(outline(marks) == ["Mail", "Work[Docs,Plan,Desk]", "Other[Read]", "Local", "Home[Mail]", "Mobile[Phone]", "Solo"])
    }

    @Test func accountPasswordsAreDiscoveredAndProfileFoldersOrderedNumerically() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        for name in ["Profile 10", "Profile 2", "Default"] { try fixture.write("\(name)/Login Data For Account", Data()) }
        let source = fixture.source(Chromium.known[0])
        #expect(source.profiles.map(\.lastPathComponent) == ["Default", "Profile 2", "Profile 10"])
        #expect(source.files.count == 3)
        #expect(source.files.allSatisfy { $0.lastPathComponent == "Login Data For Account" })
    }

    @Test func liveHistorySnapshotIncludesWalAndImportHasNoThreeThousandPageCap() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("Default/History", """
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,typed_count INTEGER,hidden INTEGER);
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3105)
        INSERT INTO urls SELECT 'https://history.test/'||i,'Page '||i,1,13300000000000000+i,0,0 FROM n;
        """)
        defer { sqlite3_close(db) }
        let source = fixture.source(Chromium.known[1])
        let file = fixture.root.appendingPathComponent("Default/History")
        let original = try Data(contentsOf: file)
        let wal = try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal"))
        #expect(Chromium.places(in: source).count == 3105)
        #expect(Chromium.places(in: source, limit: 10).count == 10)
        #expect(try Data(contentsOf: file) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal")) == wal)
    }

    /// A backup that fails after its copy was opened removes the copy, and
    /// only once its connection is closed: unlinking it under the open
    /// connection was EXC_GUARD (vnode guard, unlink) in Yab on macOS 27.0.1,
    /// where a large History or Web Data ran out of the ten seconds
    /// (`partial`: the same cut-off with no time at all). `unreadable`: a
    /// source SQLite can't read, nothing copied. A plain process on 26.6.1
    /// gets no guard either way, so this checks the outcome, not the trap.
    @Test(arguments: ["partial", "unreadable"])
    func failedSnapshotClosesItsCopyBeforeRemovingIt(_ kind: String) throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        if kind == "partial" {
            let db = try fixture.database("Default/History", """
            PRAGMA journal_mode=WAL; CREATE TABLE t(x BLOB);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2000)
            INSERT INTO t SELECT randomblob(2000) FROM n;
            """)
            sqlite3_close(db)
        } else {
            try fixture.write("Default/History", Data(String(repeating: "not a database ", count: 512).utf8))
        }
        let copies = fixture.root.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("Default/History")
        #expect(throws: (any Error).self) { try Chromium.copyWithLog(file, into: copies, within: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: copies.path).isEmpty)
    }

    @Test func extensionsReadSecurePreferencesAndIntegerDisableReasons() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        var settings: [String: Any] = [:]
        for (id, disabled) in [("enabled", 0), ("disabled", 4)] {
            settings[id] = ["location": 1, "from_webstore": true, "path": "\(id)/1.0_0", "disable_reasons": disabled]
            try fixture.json("Default/Extensions/\(id)/1.0_0/manifest.json", ["name": "__MSG_name__", "default_locale": "en", "manifest_version": 3])
            try fixture.json("Default/Extensions/\(id)/1.0_0/_locales/en/messages.json", ["name": ["message": "Extension \(id)"]])
        }
        try fixture.json("Default/Secure Preferences", ["extensions": ["settings": settings]])
        let extensions = Chromium.extensions(in: fixture.source(Chromium.known[1]))
        #expect(extensions.count == 2)
        #expect(extensions.first?.enabled == true)
        #expect(extensions.first?.name == "Extension enabled")
        #expect(extensions.last?.enabled == false)
    }

    /// Arc's Preferences keep the keys given to extensions' commands under
    /// extensions.commands, "mac:Command+Shift+W" (read on adhd's and m4's
    /// Arc and Dia, 2026-10-19): they come with the extension, the Mac's
    /// only, and Ctrl there is ⌃ (feedback #163).
    @Test func extensionsCarryTheirCommandKeys() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let id = "hlofigcdgjlnalbkeeinfcjceabpamci"
        try fixture.json("Default/Extensions/\(id)/2.0.1_0/manifest.json", ["name": "Suspender", "manifest_version": 3])
        try fixture.json("Default/Secure Preferences", ["extensions": ["settings": [id: ["location": 1, "from_webstore": true, "path": "\(id)/2.0.1_0"]]]])
        try fixture.json("Default/Preferences", ["extensions": ["commands": [
            "mac:Command+Shift+W": ["command_name": "1-suspend-tab", "extension": id, "global": false],
            "mac:Ctrl+Shift+U": ["command_name": "4-unsuspend-active-window", "extension": id, "global": false],
            "windows:Ctrl+Shift+S": ["command_name": "2a-suspend-selected-tabs", "extension": id, "global": false],
            "mac:Alt+Shift+M": ["command_name": "_execute_action", "extension": "someoneelse", "global": false],
        ]]])
        let found = try #require(Chromium.extensions(in: fixture.source(Chromium.known[1])).first)
        #expect(found.keys == ["1-suspend-tab": "Command+Shift+W", "4-unsuspend-active-window": "Ctrl+Shift+U"])
        #expect(Chromium.storedHotkey("Command+Shift+W") == Hotkey("w", [.command, .shift]))
        #expect(Chromium.storedHotkey("Ctrl+Shift+U") == Hotkey("u", [.control, .shift]))
        #expect(Chromium.storedHotkey("Command+Shift+Period") == Hotkey(".", [.command, .shift]))
        #expect(Chromium.storedHotkey("MediaPlayPause") == nil)
    }

    @Test func bookmarksOnlyProfileHasNothingToReadAsTabs() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.json("Default/Bookmarks", ["roots": [:]])
        #expect(try TabImport.places(in: fixture.source(Chromium.known[1])).isEmpty)
    }
}

struct ChromiumSessionTests {
    static func int(_ value: Int32) -> Data {
        let n = UInt32(bitPattern: value)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
    }
    static func string(_ value: String, utf16: Bool = false) -> Data {
        let bytes = utf16 ? value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] } : Array(value.utf8)
        var data = int(Int32(utf16 ? value.utf16.count : bytes.count)) + Data(bytes)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
    static func command(_ id: UInt8, _ body: Data) -> Data {
        let size = body.count + 1
        return Data([UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size >> 8), id]) + body
    }
    static func navigation(_ tab: Int32, _ index: Int32, _ url: String, _ title: String) -> Data {
        let fields = int(tab) + int(index) + string(url) + string(title, utf16: true)
        return command(6, int(Int32(fields.count)) + fields)
    }
    static var session: Data {
        var data = Data("SNSS".utf8) + int(3)
        data += command(0, int(10) + int(1)) + command(2, int(1) + int(0))
        data += navigation(1, 0, "https://old.test/", "Old")
        data += navigation(1, 1, "https://current.test/#one", "Current")
        data += command(7, int(1) + int(1)) + command(12, int(1) + Data([1, 0, 0, 0]))
        data += command(0, int(10) + int(2)) + command(2, int(2) + int(1))
        data += navigation(2, 0, "https://group.test/", "Group")
        let token = Data((1...16).map(UInt8.init))
        data += command(25, int(2) + int(0) + token + Data([1, 0, 0, 0, 0, 0, 0, 0]))
        let metadata = token + string("Research", utf16: true) + int(1) + int(0)
        data += command(27, int(Int32(metadata.count)) + metadata)
        data += command(0, int(10) + int(3)) + navigation(3, 0, "https://closed.test/", "Closed")
        data += command(16, int(3) + Data(repeating: 0, count: 12))
        data += command(0, int(11) + int(4)) + navigation(4, 0, "https://window.test/", "Closed window")
        data += command(17, int(11) + Data(repeating: 0, count: 12))
        return data
    }

    @Test func sessionReplaysCurrentNavigationPinsGroupsAndClosures() {
        let tabs = Snss.tabs(in: Self.session)
        #expect(tabs.pinned.map(\.url.absoluteString) == ["https://current.test/#one"])
        #expect(tabs.pinned.first?.title == "Current")
        #expect(tabs.open.map(\.url.host) == ["group.test"])
        #expect(tabs.open.first?.folder == "Research")
    }

    @Test func damagedNewestSessionFallsBackAndLegacySessionsAreSupported() throws {
        for legacy in [false, true] {
            let fixture = ImportFixture()
            defer { fixture.remove() }
            try fixture.write(legacy ? "Default/Last Session" : "Default/Sessions/Session_1", Self.session)
            if !legacy { try fixture.write("Default/Sessions/Session_2", Data("bad header".utf8)) }
            let places = try TabImport.places(in: fixture.source(Chromium.known[1]))
            #expect(places.count == 1)
            #expect(places.first?.pinned.count == 1)
            #expect(places.first?.open.count == 1)
        }
    }

    @Test func brokenOrTruncatedCommandsDoNotCrashOrReadPastTheFile() {
        #expect(Snss.tabs(in: Data("SNSS".utf8) + Self.int(99)).open.isEmpty)
        #expect(Snss.tabs(in: Self.session + Data([255, 255, 6])).open.count == 1)
        #expect(Snss.tabs(in: Data("SNSS".utf8) + Self.int(3) + Self.command(6, Data(repeating: 255, count: 32))).open.isEmpty)
    }

    @Test func prunedNavigationDoesNotRestoreAnOlderOrRemovedPage() {
        for (command, selected) in [(UInt8(11), Int32(1)), (24, 1), (11, 0), (24, 0)] {
            var data = Data("SNSS".utf8) + Self.int(3)
            data += Self.command(0, Self.int(1) + Self.int(1))
            data += Self.navigation(1, 0, "https://removed.test/", "Removed")
            data += Self.navigation(1, 1, "https://shown.test/", "Shown")
            data += Self.navigation(1, 2, "https://forward.test/", "Forward")
            data += Self.command(7, Self.int(1) + Self.int(selected))
            let body = command == 11 ? Self.int(1) + Self.int(1) : Self.int(1) + Self.int(0) + Self.int(1)
            data += Self.command(command, body)
            #expect(Snss.tabs(in: data).open.first?.url.host == "shown.test")
        }
        var data = Data("SNSS".utf8) + Self.int(3)
        data += Self.command(0, Self.int(1) + Self.int(1))
        data += Self.navigation(1, 0, "https://shown.test/", "Shown")
        data += Self.navigation(1, 1, "https://removed.test/", "Removed")
        data += Self.command(5, Self.int(1) + Self.int(1))
        #expect(Snss.tabs(in: data).open.first?.url.host == "shown.test")
    }
}

/// Opt-in read-only audit on the Mac where the source browsers live.
/// Output contains counts, never page addresses or account credentials.
struct InstalledBrowserImportTests {
    @Test func installedAsidePortableDataRoundTrips() throws {
        guard let path = ProcessInfo.processInfo.environment["YAB_IMPORT_ASIDE_USERS"] else { return }
        let found = AsideImport.read(in: URL(fileURLWithPath: path))
        #expect(found.skipped == 0)
        #expect(found.errors.isEmpty)
        #expect(!found.notes.isEmpty && !found.chats.isEmpty)
        let fixture = ImportFixture()
        defer { fixture.remove() }
        #expect(AsideImport.take(found.notes, into: fixture.root.appendingPathComponent("memory")).added == found.notes.count)
        #expect(AsideImport.take(found.notes, into: fixture.root.appendingPathComponent("memory")).added == 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        for chat in found.chats {
            #expect(chat.archived == true && chat.thread == nil)
            try fixture.write("chats/\(chat.id).json", encoder.encode(chat))
        }
        let reopened = Chats.read(fixture.root.appendingPathComponent("chats"))
        #expect(Set(reopened.map(\.id)) == Set(found.chats.map(\.id)))
        for chat in found.chats { #expect(reopened.first { $0.id == chat.id } == chat) }
        print("YAB_ASIDE_PERSISTENCE \(found.notes.count) memory notes and routine definitions, \(found.chats.count) archived chats, \(found.skipped) skipped; repeat added 0")
    }

    @MainActor
    @Test func installedTabsSurviveNativeImportAndRepeat() throws {
        guard ProcessInfo.processInfo.environment["YAB_IMPORT_AUDIT"] == "1" else { return }
        #expect(Store.testing)
        guard Store.testing else { return }
        let previous = Spaces.read()
        let sharing = Spaces.sharing
        defer { Spaces.write(previous); Spaces.sharing = sharing }
        let browser = Browser()
        for source in Chromium.installed() {
            let places = (try? TabImport.places(in: source)) ?? []
            guard !places.isEmpty else { continue }
            let targets = places.map { place -> Space in
                var space = Space(id: UUID(), name: place.name, icon: "", ownSignIns: !place.shared,
                                  paint: SpacePaint(swatch: .custom, color: browser.prefs.backdropColor, grain: 0))
                space.origin = place.id
                space.signedInAs = "\(source.name):\(place.profile)"
                return space
            }
            browser.spaces = [browser.spaces.first { $0.id == browser.spaceID }! ] + targets
            defer { for space in targets { Session.erase(space: space.id) } }
            let first = browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: source)
            var expected = 0, saved = 0
            for (place, space) in zip(places, targets) {
                let urls = Set((place.pinned + place.kept + place.open).map { TabImport.key($0.url) })
                let session = Session.read(space: space.id)
                let persisted = Set(session.tabs.compactMap { URL(string: $0.url).map(TabImport.key) })
                #expect(persisted == urls)
                expected += urls.count
                saved += session.tabs.count
            }
            let repeated = browser.bring(places, withOpen: true, asSpaces: true, signIns: false, from: source)
            #expect(repeated.spaces == 0 && repeated.pinned == 0 && repeated.open == 0)
            #expect(first.pinned + first.open == expected && saved == expected)
            print("YAB_IMPORT_PERSISTENCE \(source.name): \(saved) tabs saved; repeat added 0")
        }
    }

    @Test func installedDataReadsThroughTheActualImporters() throws {
        guard ProcessInfo.processInfo.environment["YAB_IMPORT_AUDIT"] == "1" else { return }
        var results: [[String: Any]] = []
        for source in Chromium.installed() {
            let tabs = Result { try TabImport.places(in: source) }
            var row: [String: Any] = ["browser": source.name, "profiles": source.profiles.count,
                                      "passwords": Chromium.loginCount(source), "bookmarks": Bookmarks.count(Chromium.bookmarks(in: source)),
                                      "history": Chromium.places(in: source).count, "extensions": Chromium.extensions(in: source).count,
                                      "cookies": Chromium.cookieCount(source)]
            if let places = try? tabs.get() {
                row["places"] = places.count
                row["pins"] = places.reduce(0) { $0 + $1.pinned.count }
                row["kept"] = places.reduce(0) { $0 + $1.kept.count }
                row["open"] = places.reduce(0) { $0 + $1.open.count }
                row["splits"] = places.reduce(0) { $0 + $1.splits.count }
            } else { row["tabsReadable"] = false }
            if source.bundle == AsideImport.bundle {
                let found = AsideImport.read()
                row["memory"] = found.notes.count
                row["chats"] = found.chats.count
                row["skipped"] = found.skipped
                row["errors"] = found.errors
                let fixture = ImportFixture()
                defer { fixture.remove() }
                let copied = AsideImport.take(found.notes, into: fixture.root)
                #expect(copied.added == found.notes.count && copied.skipped == 0)
                #expect(AsideImport.take(found.notes, into: fixture.root).added == 0)
                #expect(found.errors.isEmpty)
            }
            results.append(row)
        }
        print("YAB_IMPORT_AUDIT " + String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
    }
}

struct BrowserDataImportTests {
    @Test func cookiesValidateTheDomainHashAndSkipExpiredAndPartitionedValues() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        // AES vector produced independently with openssl: SHA256(domain)
        // followed by the value, encrypted with Chromium's macOS recipe.
        let blob = "76313021a668312966fb049052867193deb0cbd86bd528e37370a5f02f04be5d428356ed71f272719c0d820c2a77f7da99978e"
        let db = try fixture.database("Cookies", """
        CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24);
        CREATE TABLE cookies(host_key TEXT,name TEXT,encrypted_value BLOB,value TEXT,path TEXT,expires_utc INTEGER,has_expires INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER,top_frame_site_key TEXT);
        INSERT INTO cookies VALUES
        ('example.com','session',X'\(blob)','','/',0,0,1,1,1,''),
        ('other.test','wrong-domain',X'\(blob)','','/',0,0,1,1,1,''),
        ('example.com','expired',X'\(blob)','','/',1,1,1,1,1,''),
        ('example.com','partitioned',X'\(blob)','','/',0,0,1,1,1,'https://top.test'),
        ('example.com','plain',X'','plain-cookie','/',0,0,1,0,0,'');
        """)
        defer { sqlite3_close(db) }
        let cookies = try Chromium.cookieRows(in: fixture.root.appendingPathComponent("Cookies"), key: ChromiumPasswordsTests.key)
        #expect(Set(cookies.map(\.name)) == ["session", "plain"])
        #expect(cookies.first { $0.name == "session" }?.value == "session-cookie")
        #expect(cookies.first { $0.name == "session" }?.httpOnly == true)
        #expect(cookies.first { $0.name == "plain" }?.value == "plain-cookie")
    }

    @Test func unrecognizedEncryptionIsNeverTreatedAsPlaintext() {
        #expect(Chromium.unwrap(Data("v20unsupported-ciphertext".utf8), key: ChromiumPasswordsTests.key) == nil)
        #expect(Chromium.unwrap(Data("v11unsupported-ciphertext".utf8), key: ChromiumPasswordsTests.key) == nil)
    }

    @Test func encryptedCardsAndAllCoexistingAddressSchemasAreRead() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let card = "76313021be28ec1947a35ffea7badf5f8fd8f81630f164a445983887020affc3018811"
        let db = try fixture.database("Web Data", """
        CREATE TABLE credit_cards(guid TEXT,name_on_card TEXT,expiration_month INTEGER,expiration_year INTEGER,card_number_encrypted BLOB,use_date INTEGER);
        INSERT INTO credit_cards VALUES('card','Mei',11,2031,X'\(card)',1700000000);
        CREATE TABLE addresses(guid TEXT,use_date INTEGER); INSERT INTO addresses VALUES('modern',1700000000);
        CREATE TABLE address_type_tokens(guid TEXT,type INTEGER,value TEXT);
        INSERT INTO address_type_tokens VALUES('modern',7,'Mei Chen'),('modern',77,'221 Mission St'),('modern',33,'SF');
        CREATE TABLE local_addresses(guid TEXT,use_date INTEGER); INSERT INTO local_addresses VALUES('local',1700000000);
        CREATE TABLE local_addresses_type_tokens(guid TEXT,type INTEGER,value TEXT);
        INSERT INTO local_addresses_type_tokens VALUES('local',7,'Jane Doe'),('local',30,'1 Main St'),('local',35,'94105');
        CREATE TABLE autofill_profiles(guid TEXT,company_name TEXT,street_address TEXT,city TEXT,state TEXT,zipcode TEXT,country_code TEXT,use_date INTEGER);
        INSERT INTO autofill_profiles VALUES('legacy','','2 Pine St','LA','CA','90001','US',1700000000);
        CREATE TABLE autofill_profile_names(guid TEXT,first_name TEXT,last_name TEXT,full_name TEXT);
        INSERT INTO autofill_profile_names VALUES('legacy','Sam','Smith','Sam Smith');
        """)
        defer { sqlite3_close(db) }
        let wallet = try Chromium.wallet(file: fixture.root.appendingPathComponent("Web Data"), key: ChromiumPasswordsTests.key, from: "Test")
        #expect(wallet.cards.count == 1)
        #expect(wallet.cards.first?.number == "4242424242424242")
        #expect(wallet.cards.first?.nickname == "")
        #expect(wallet.cards.first?.used?.timeIntervalSince1970 == 1700000000)
        #expect(Set(wallet.addresses.map(\.name)) == ["Mei Chen", "Jane Doe", "Sam Smith"])
    }
}
