import CryptoKit
import Foundation
import Testing
import SyncKit
@testable import Fast

/// What the Mac writes into sync, held to the bytes it wrote before the
/// record shapes moved into SyncKit (SyncWireFixtures): spaces, rows,
/// bookmarks, history and chats, every field and every absent one, with
/// explicitly named additions to the wire format since then.
@MainActor
struct SyncWireTests {
    init() { SyncShapes.register() }

    static let canonical: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func json(_ c: SyncShapes.Collection) -> String {
        String(data: try! canonical.encode(c), encoding: .utf8)!
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func t(_ minutesAgo: Double) -> Double { 1_759_700_000 - minutesAgo * 60 + 17.4 }

    /// Fails with the bytes written now, so a fixture can be taken from the log.
    private func expectFixture(_ name: String, _ c: SyncShapes.Collection, adding additions: SyncFields = [:]) {
        let now = Self.json(c)
        var expected = SyncWireFixtures.json[name]
        if !additions.isEmpty, let data = expected?.data(using: .utf8) {
            let before = try! JSONDecoder().decode(SyncShapes.Collection.self, from: data)
            expected = Self.json(before.mapValues { $0.merging(additions) { _, added in added } })
        }
        let ok = expected == now
        if !ok { print("WIRE-FIXTURE \(name) \(now)") }
        #expect(ok, "\(name) differs from its fixture and declared additions")
    }

    // MARK: Inputs

    static let first = Space.firstID
    static let work = UUID(uuidString: "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10")!
    static let lisbon = UUID(uuidString: "B0C1D2E3-F405-4617-8829-3A4B5C6D7E8F")!

    static func paint(_ json: String) -> SpacePaint { try! JSONDecoder().decode(SpacePaint.self, from: Data(json.utf8)) }

    static var spaces: [Space] {
        [
            Space(id: first, name: "Personal", icon: "🏠", ownSignIns: false),
            Space(id: work, name: "Work", icon: "💼", ownSignIns: true,
                  paint: paint(##"{"swatch":"custom","color":"#7B61FF","grain":true,"grainAmount":0.5,"colors":["#7B61FF","#FF61A6"],"transparency":0.2}"##),
                  origin: "Arc:7F1"),
            Space(id: lisbon, name: "Lisbon ✈️ trip, a long name to see it whole", icon: "🇵🇹", ownSignIns: false,
                  paint: paint(##"{"swatch":"custom","color":"#00AA88","grain":false}"##)),
        ]
    }
    static let spaceOrders = [first.uuidString: "V", lisbon.uuidString: "X"]

    static let folderKept = "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B"
    static let folderOuter = "E5F60718-293A-44B5-86C7-D8E9F0A1B2C3"
    static let folderSearch = "D4E5F607-1829-43A4-B5C6-D7E8F90A1B2C"

    static var shapes: [UUID: Session.Shape] {
        var live = Live()
        live.show = ["review"]
        live.hidden = ["me/old"]
        let mark = LiveMark(key: "github.com/me/yab/pull/12", words: .review, seen: nil, folder: UUID(uuidString: folderKept),
                            yours: true, came: Date(timeIntervalSince1970: t(90)))
        let path = [Session.Step(id: folderOuter, name: "Projects", open: false, mark: "🗂")]
        func entry(_ n: Int, _ url: String, _ title: String) -> Session.Entry {
            Session.Entry(url: url, title: title, pin: nil, seen: t(Double(n)), id: String(format: "11111111-0000-4000-8000-%012d", n))
        }
        var tabs: [Session.Entry] = []
        var e = entry(1, "https://mail.google.com/mail/u/0/", "Inbox (3)")
        e.pin = "M"; e.visits = 40; e.depth = 0.37
        e.home = "https://mail.google.com/"; e.homeTitle = "Gmail"
        tabs.append(e)
        e = entry(2, "https://linear.app/yab/team/YAB/active", "Active issues")
        e.pin = "L"; e.name = "Linear"; e.seen = t(600)
        tabs.append(e)
        e = entry(3, "https://github.com/me/yab/pull/12", "Sync for iPhone #12")
        e.kept = true; e.folder = folderKept; e.folderName = "Pull requests"; e.folderOpen = true; e.folderLive = live
        e.live = mark; e.folderMark = "🔀"; e.folderPath = path; e.home = "https://github.com/me/yab/pulls"; e.homeTitle = nil
        tabs.append(e)
        e = entry(4, "https://github.com/me/yab/pull/13", "Fix the field #13")
        e.seen = nil; e.kept = true; e.folder = folderKept; e.folderName = "Pull requests"; e.folderOpen = true
        e.folderLive = live; e.folderMark = "🔀"; e.folderPath = path
        tabs.append(e)
        e = entry(5, "https://docs.google.com/document/d/abc/edit", "Q4 plan")
        e.kept = true; e.customMark = "📄"; e.name = "Plan"; e.home = "https://docs.google.com/"; e.homeTitle = "Docs"
        tabs.append(e)
        e = entry(6, "https://www.google.com/search?q=lisbon+hotels", "lisbon hotels - Google Search")
        e.folder = folderSearch; e.folderName = "lisbon hotels"; e.folderOpen = false; e.folderSearch = "lisbon hotels"; e.folderToday = true
        tabs.append(e)
        e = entry(7, "https://www.booking.com/hotel/pt/memmo.html", "Memmo Alfama")
        e.seen = t(4.9); e.folder = folderSearch; e.folderName = "lisbon hotels"; e.folderOpen = false
        e.folderSearch = "lisbon hotels"; e.folderToday = true
        tabs.append(e)
        e = entry(8, "https://news.ycombinator.com/", "Hacker News")
        e.seen = t(0.2); e.visits = 3; e.depth = 1
        tabs.append(e)
        e = entry(9, "https://figma.com/file/x", "")
        tabs.append(e)
        let work = Session.Shape(tabs: tabs, active: 7, pairs: [Session.Pair(first: 7, second: 8, share: 0.42)])
        var noID = Session.Entry(url: "https://example.com/", title: "No id: never written", pin: nil, seen: nil)
        noID.id = nil
        let personal = Session.Shape(tabs: [
            Session.Entry(url: "https://calendar.google.com/", title: "Calendar", pin: "C", seen: t(30), id: "22222222-0000-4000-8000-000000000001"),
            noID,
            Session.Entry(url: "https://www.youtube.com/watch?v=abc", title: "A talk", pin: nil, seen: t(120), id: "22222222-0000-4000-8000-000000000002"),
        ], active: 0)
        return [Self.work: work, first: personal]
    }
    static let tabOrders = ["11111111-0000-4000-8000-000000000001": "M", "11111111-0000-4000-8000-000000000005": "a",
                            "11111111-0000-4000-8000-000000000008": "Z"]

    static var tree: [Bookmark] {
        [
            Bookmark(id: UUID(uuidString: "33333333-0000-4000-8000-000000000001")!, title: "Yab", url: "https://yetanotherbrowser.com/",
                     children: nil, added: Date(timeIntervalSince1970: t(9000))),
            Bookmark(id: UUID(uuidString: "33333333-0000-4000-8000-000000000002")!, title: "Reading", url: nil, children: [
                Bookmark(id: UUID(uuidString: "33333333-0000-4000-8000-000000000003")!, title: "Essay", url: "https://paulgraham.com/greatwork.html",
                         children: nil, added: nil),
                Bookmark(id: UUID(uuidString: "33333333-0000-4000-8000-000000000004")!, title: "Deeper", url: nil, children: [
                    Bookmark(id: UUID(uuidString: "33333333-0000-4000-8000-000000000005")!, title: "Paper", url: "https://arxiv.org/abs/1234.5678",
                             children: nil, added: Date(timeIntervalSince1970: t(100))),
                ], added: nil),
            ], added: Date(timeIntervalSince1970: t(8000))),
        ]
    }
    static let markOrders = ["33333333-0000-4000-8000-000000000002": "k"]

    static var visits: [Visit] {
        let places: [(String, String, Bool)] = [
            ("https://www.Example.com/", "Example", true),
            ("https://example.com/Path/To?q=1#frag", "Path with a query", false),
            ("http://localhost:3000/app", "A local server", true),
            ("https://[2001:db8::1]:8443/x", "IPv6", false),
            ("https://github.com/me/yab/pull/12", "A title well over three hundred characters " + String(repeating: "x", count: 320), false),
            ("https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo", "São Paulo", false),
        ]
        return places.enumerated().map { i, p in
            let url = URL(string: p.0)!
            return Visit(url: p.0, key: Address.pretty(url).lowercased(), title: p.1, count: 3,
                         last: Date(timeIntervalSince1970: t(Double(i) * 7)), typed: p.2 ? 2 : nil)
        }
    }

    static func chat(steps: Int) -> Chat {
        let began = Date(timeIntervalSince1970: t(20))
        let items: [ChatItem] = (0..<steps).map { i in
            let kinds: [ChatItem.Kind] = [.asked, .tool, .message, .thinking, .command]
            let start = began.addingTimeInterval(Double(i))
            return ChatItem(id: "item-\(i)", kind: kinds[i % kinds.count], name: i % 5 == 1 ? "open" + String(repeating: "n", count: 220) : "",
                            detail: i % 5 == 1 ? "booking.com" + String(repeating: "d", count: 520) : "",
                            text: "Step \(i) " + String(repeating: "word ", count: i % 7 + (i == 2 ? 2000 : 0)),
                            state: i == steps - 1 ? .running : .done, began: start, ended: i == steps - 1 ? nil : start.addingTimeInterval(0.5))
        }
        return Chat(id: "k3j9x2", title: "Find a hotel in Lisbon", began: .field, cli: "claude", model: "opus", items: items,
                    pinned: true, archived: nil, unread: true, state: "running", answer: String(repeating: "An answer. ", count: 500),
                    started: began, updated: began.addingTimeInterval(200))
    }

    static var plainChat: Chat {
        var chat = chat(steps: 3)
        chat.model = nil; chat.pinned = false; chat.archived = true; chat.unread = nil; chat.answer = "Done."; chat.state = "done"
        return chat
    }

    // MARK: Out, as before

    @Test func spacesAreWrittenAsBefore() {
        expectFixture("space", SyncShapes.spaces(Self.spaces, orders: Self.spaceOrders))
    }

    @Test func rowsAreWrittenAsBefore() {
        let rows = SyncShapes.rows(Self.shapes, orders: Self.tabOrders)
        expectFixture("tab", rows.tabs)
        expectFixture("folder", rows.folders, adding: Self.folderAdditions)
        expectFixture("pair", rows.pairs)
    }

    /// Folder fields added after the frozen fixtures were taken: colors, and
    /// an ordinary folder moved among today's (Nest.ordinaryToday, 1948e3e37).
    static let folderAdditions: SyncFields = ["color": .null, "ordinaryToday": .null]

    @Test func bookmarksAreWrittenAsBefore() {
        expectFixture("bookmark", SyncShapes.bookmarks(Self.tree, orders: Self.markOrders))
    }

    @Test func historyIsWrittenAsBefore() {
        expectFixture("visit", SyncShapes.visits(Self.visits))
    }

    @Test func chatsAreWrittenAsBefore() {
        let id = SyncChats.id(agent: "k3j9x2")
        expectFixture("chat", [id: SyncChats.head(Self.chat(steps: 3), kind: "agent", device: "mac-a", live: true),
                               "a:plain": SyncChats.head(Self.plainChat, kind: "agent", device: "mac-b")])
        expectFixture("chatitem", SyncChats.items(Self.chat(steps: 3), record: id))
        // The last 80 of a long chat, by their digest: 152 steps in.
        let long = Self.json(SyncChats.items(Self.chat(steps: 152), record: id))
        if Self.digest(long) != SyncWireFixtures.longChatDigest { print("WIRE-FIXTURE longChatDigest \(Self.digest(long))") }
        #expect(Self.digest(long) == SyncWireFixtures.longChatDigest)
    }

    // MARK: In, through SyncKit's values

    /// Each record of a fixture, as a device would have it, read by
    /// SyncKit's value for its collection and written again: the same
    /// fields and values, plus only the declared additions. The input
    /// stays the old fixture, exercising records without the newer fields.
    private func readsBack(_ name: String, adding additions: SyncFields = [:], _ read: (Record) -> SyncFields?) throws {
        let data = try #require(SyncWireFixtures.json[name]).data(using: .utf8)!
        let fixture = try JSONDecoder().decode(SyncShapes.Collection.self, from: data)
        #expect(!fixture.isEmpty)
        for (id, fields) in fixture {
            let record = Record(collection: name, id: id, fields: fields.filter { !$0.value.isNull })
            let again = read(record)
            let expected = fields.merging(additions) { _, added in added }
            #expect(again == expected, "\(name) \(id) read and written again differs")
        }
    }

    @Test func everyRecordReadsBackTheSameThroughSyncKit() throws {
        try readsBack("space") { SyncSpace($0)?.fields }
        try readsBack("tab") { SyncTab($0)?.fields }
        try readsBack("folder", adding: Self.folderAdditions) { SyncFolder($0)?.fields }
        try readsBack("pair") { SyncPair($0)?.fields }
        try readsBack("bookmark") { SyncBookmark($0)?.fields }
        try readsBack("visit") { SyncVisit($0)?.fields }
        try readsBack("chat") { SyncChat($0)?.fields }
        try readsBack("chatitem") { SyncChatItem($0)?.fields }
    }

    @Test func folderColorsSurviveWritingReadingAndClearing() throws {
        let journal = try Journal(path: nil, device: "mac-a")
        for color in ["teal", nil] as [String?] {
            let shape = Session.Shape(tabs: [
                Session.Entry(url: "https://example.com/", title: "Design", kept: true,
                              folder: Self.folderKept, folderName: "Design", folderOpen: true,
                              folderPath: [Session.Step(id: Self.folderOuter, name: "Projects", open: false, color: color)],
                              folderColor: color, id: "colored-tab"),
            ], active: 0)
            let out = SyncShapes.rows([Self.work: shape], orders: [:])
            #expect(Set(out.folders.keys) == [Self.folderKept, Self.folderOuter])
            for fields in out.folders.values { #expect(fields["color"] == Value(color)) }
            try journal.reconcile(SyncShapes.folder, out.folders)
            let folders = journal.living(SyncShapes.folder)
            #expect(folders.count == 2)
            for record in folders {
                let folder = try #require(SyncFolder(record))
                #expect(folder.color == color)
                #expect(folder.fields == out.folders[record.id])
            }
            let back = SyncShapes.row(Self.work, tabs: records(SyncShapes.tab, out.tabs), folders: folders, pairs: [], here: shape)
            let tab = try #require(back.tabs.first)
            #expect(tab.folder == Self.folderKept)
            #expect(tab.folderColor == color)
            #expect(tab.folderPath == shape.tabs[0].folderPath)
        }
    }

    /// The iPhone's own writer for a tab, a space and a bookmark is the
    /// Mac's: one made from the same values writes the same bytes.
    @Test func thePhonesWritersAreTheMacs() {
        let rows = SyncShapes.rows(Self.shapes, orders: Self.tabOrders)
        let tabs = rows.tabs.map { id, fields in SyncTab(Record(collection: "tab", id: id, fields: fields.filter { !$0.value.isNull }))! }
        let folders = Dictionary(rows.folders.map { id, fields in
            (id, SyncFolder(Record(collection: "folder", id: id, fields: fields.filter { !$0.value.isNull }))!)
        }, uniquingKeysWith: { a, _ in a })
        for space in [Self.work, Self.first] {
            let mine = tabs.filter { $0.space == space.uuidString }.sorted(by: RecordShapes.placed)
            let out = RecordShapes.row(space: space.uuidString, tabs: mine, folders: folders, pairs: [], orders: rows.tabs.compactMapValues { $0["order"]?.string })
            #expect(Self.json(out.tabs) == Self.json(rows.tabs.filter { $0.value["parent"]?.string == space.uuidString }))
        }
        #expect(RecordShapes.spaces(SyncShapes.spaces(from: records("space", SyncShapes.spaces(Self.spaces, orders: Self.spaceOrders))).map { s in
            SyncSpace(id: s.id.uuidString, name: s.name, icon: s.icon, ownSignIns: s.ownSignIns,
                      paint: s.paint.flatMap { try? Value(encoding: $0) }.flatMap(SyncPaint.init), origin: s.origin)
        }, orders: Self.spaceOrders) == SyncShapes.spaces(Self.spaces, orders: Self.spaceOrders))
    }

    private func records(_ collection: String, _ c: SyncShapes.Collection) -> [Record] {
        c.map { Record(collection: collection, id: $0.key, fields: $0.value.filter { !$0.value.isNull }) }
    }
}
