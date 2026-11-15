import SyncKit
import XCTest
@testable import YabPhone

/// Sync's records as the app shows them: addresses, rows, folders, private
/// tabs, the tab in front, chats.
final class SyncMappingTests: XCTestCase {
    func testAddresses() {
        XCTAssertEqual(SyncMapping.address("https://www.figma.com/file/x/"), "figma.com/file/x")
        XCTAssertEqual(SyncMapping.address("http://localhost:5173"), "localhost:5173")
        XCTAssertEqual(SyncMapping.fullURL("localhost:5173"), "http://localhost:5173")
        XCTAssertEqual(SyncMapping.fullURL("figma.com/file/x"), "https://figma.com/file/x")
        XCTAssertEqual(SyncMapping.fullURL("https://a.test/"), "https://a.test/")
        XCTAssertEqual(SyncMapping.host("https://www.News.ycombinator.com/item?id=1"), "news.ycombinator.com")
        XCTAssertEqual(SyncMapping.port("http://localhost:5173/x"), ":5173")
        XCTAssertNil(SyncMapping.port("https://figma.com/file"))
        XCTAssertEqual(SyncMapping.siteName("linear.app"), "Linear")
        XCTAssertEqual(SyncMapping.siteName("github.com"), "GitHub")
        XCTAssertEqual(SyncMapping.siteName("news.ycombinator.com"), "Hacker News")
        XCTAssertEqual(SyncMapping.siteName("localhost"), "localhost")
        XCTAssertEqual(SyncMapping.siteName("docs.stripe.com"), "Stripe")
    }

    func testATabFromTheMacFindsItsPage() {
        let synced = SyncTab(id: "A", space: "S", url: "https://linear.app/tern/issue/ENG-412/invite-flow", title: "ENG-412 · Invite flow · Linear")
        let tab = SyncMapping.tab(synced, id: "A", old: nil)
        XCTAssertEqual(tab.page, "linear-invite")
        XCTAssertEqual(tab.site, "Linear")
        XCTAssertEqual(tab.icon, "linear")
        XCTAssertEqual(tab.url, "linear.app/tern/issue/ENG-412/invite-flow")
        // A name of your own wins over the page's title.
        var named = synced
        named.name = "Invite flow"
        XCTAssertEqual(SyncMapping.tab(named, id: "A", old: nil).title, "Invite flow")
        // A place with no page of the app's: its site's name and letter.
        let other = SyncMapping.tab(SyncTab(id: "B", space: "S", url: "http://localhost:5173/", title: "Tern"), id: "B", old: nil)
        XCTAssertNil(other.page)
        XCTAssertEqual(other.site, "localhost")
        XCTAssertEqual(other.port, ":5173")
    }

    func testATabKeepsItsLookWhileItsAddressStays() {
        let old = Tab(id: "t", title: "Old", site: "Figma", icon: "figma", url: "figma.com/design/x", page: "figma", host: "figma.com", onMac: true)
        let same = SyncMapping.tab(SyncTab(id: "t", space: "S", url: "https://figma.com/design/x", title: "New title"), id: "t", old: old)
        XCTAssertEqual(same.page, "figma")
        XCTAssertEqual(same.title, "New title")
        XCTAssertTrue(same.onMac)
        let moved = SyncMapping.tab(SyncTab(id: "t", space: "S", url: "https://news.ycombinator.com", title: "Hacker News"), id: "t", old: old)
        XCTAssertEqual(moved.page, "hn")
    }

    func testRealSyncedURLsNeverBecomeFixturesOrLoseTheirScheme() {
        let url = "http://example.org/a%2Fb?query=1#section"
        let synced = SyncTab(id: "real", space: "S", url: url, title: "Hacker News")
        let fixture = SyncMapping.Fixture(stem: "hn", fav: "hn", title: "Hacker News", site: "Hacker News", url: "https://news.ycombinator.com", dark: false)
        let real = SyncMapping.tab(synced, id: "real", old: nil, fixtures: [fixture], fixturesEnabled: false)
        XCTAssertEqual(real.url, url)
        XCTAssertEqual(real.navigationURL?.absoluteString, url)
        XCTAssertNil(real.page)
        XCTAssertEqual(real.host, "example.org")
        let old = Tab(id: "real", title: "Old", site: "Example", icon: "example", url: "https://example.org/a%2Fb?query=1#section")
        XCTAssertEqual(SyncMapping.tab(synced, id: "real", old: old, fixturesEnabled: false).url, url, "http and https are different navigations")
    }

    func testASpaceFromItsRow() {
        let s = "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10"
        let folder = SyncFolder(id: "F", space: s, name: "Onboarding v3", open: true)
        func tab(_ id: String, _ order: String, pin: String? = nil, kept: Bool = false, folder: String? = nil) -> SyncTab {
            SyncTab(id: id, space: s, order: order, url: "https://example.com/\(id)", title: "Tab \(id)", pin: pin, kept: kept, folder: folder)
        }
        var mirror = SyncMirror()
        mirror.spaces[s] = SyncSpace(id: s, name: "Work", icon: "💼", paint: SyncPaint(.object(["swatch": "custom", "color": "#7B61FF"])))
        mirror.folders["F"] = folder
        for t in [tab("p", "A", pin: "P"), tab("k1", "B", kept: true, folder: "F"), tab("k2", "C", kept: true, folder: "F"),
                  tab("k3", "D", kept: true), tab("t1", "E"), tab("t2", "F")] { mirror.tabs[t.id] = t }
        let row = mirror.row(s)
        XCTAssertEqual(row.pins.map(\.id), ["p"])
        XCTAssertEqual(row.kept.map(\.id), ["k1", "k2", "k3"])
        XCTAssertEqual(row.today.map(\.id), ["t1", "t2"])
        // The iPhone folded the folder and has a private tab and t2 in front.
        let old = Space(id: s, name: "Work", emoji: "💼", tint: RGB(1, 2, 3),
                        kept: [.folder(Folder(id: "F", name: "Onboarding v3", open: false, tabs: []))],
                        today: [Tab(id: "priv", title: "Private", site: "x", icon: "x", isPrivate: true)], current: "t2")
        let space = SyncMapping.space(mirror.spaces[s]!, row: row, old: old)
        XCTAssertEqual(space.pins.map(\.id), ["p"])
        XCTAssertEqual(space.folders.map(\.name), ["Onboarding v3"])
        XCTAssertEqual(space.folders.first?.tabs.map(\.id), ["k1", "k2"])
        XCTAssertEqual(space.folders.first?.open, false, "folding is the iPhone's own")
        XCTAssertEqual(space.keptTabs.map(\.id), ["k1", "k2", "k3"])
        // With none of sync's rows beside it before, after the rows that came.
        XCTAssertEqual(space.today.map(\.id), ["t1", "t2", "priv"], "private tabs stay, on this iPhone only")
        XCTAssertEqual(space.current, "t2")
        XCTAssertEqual(space.tint, RGB(231, 227, 255), "the Mac's color, mostly white")
        // t2 closed elsewhere: the row after it here takes its place (the
        // private one, kept where it stood)...
        mirror.apply([.tabGone("t2")])
        let after = SyncMapping.space(mirror.spaces[s]!, row: mirror.row(s), old: space)
        XCTAssertEqual(after.current, "priv")
        // ...and with none after it, the row before it.
        var last = space
        last.today.removeAll { $0.isPrivate }
        XCTAssertEqual(SyncMapping.space(mirror.spaces[s]!, row: mirror.row(s), old: last).current, "t1")
    }

    func testTheMirrorSaysWhichSpacesABatchTouched() {
        var mirror = SyncMirror()
        let t = SyncTab(id: "t", space: "A", url: "https://a.test", title: "A")
        XCTAssertEqual(mirror.apply([.tab(t)]), ["A"])
        var moved = t
        moved.space = "B"
        XCTAssertEqual(mirror.apply([.tab(moved)]), ["A", "B"])
        XCTAssertEqual(mirror.apply([.tabGone("t")]), ["B"])
        XCTAssertTrue(mirror.tabs.isEmpty)
    }

    /// Today is each device's own: the Macs' tabs of today, and those from
    /// before, stay out of the rows (so the app's rows, compared with the
    /// mirror, never close them), kept aside in `elsewhere`; a tab the Mac
    /// keeps comes in for every device.
    func testTheMacsTodayStaysOutOfTheIPhonesRows() {
        var mirror = SyncMirror(device: "iphone")
        let mine = SyncTab(id: "i", space: "A", order: "1", url: "https://i.test", title: "I", device: "iphone")
        let macs = SyncTab(id: "m", space: "A", order: "2", url: "https://m.test", title: "M", device: "mac")
        let old = SyncTab(id: "o", space: "A", order: "3", url: "https://o.test", title: "O")
        mirror.apply([.tab(mine), .tab(macs), .tab(old)])
        XCTAssertEqual(Set(mirror.tabs.keys), ["i"])
        XCTAssertEqual(mirror.row("A").today.map(\.id), ["i"])
        XCTAssertEqual(mirror.row("A").elsewhere.map(\.id), ["m", "o"])
        var kept = macs
        kept.kept = true
        kept.device = nil
        mirror.apply([.tab(kept)])
        XCTAssertEqual(mirror.row("A").kept.map(\.id), ["m"])
        XCTAssertEqual(mirror.row("A").elsewhere.map(\.id), ["o"])
        XCTAssertEqual(mirror.apply([.tabGone("o")]), ["A"])
        XCTAssertTrue(mirror.elsewhere.isEmpty)
        // Without a device (a line-less world) every tab is shown, as before.
        var all = SyncMirror()
        all.apply([.tab(mine), .tab(macs), .tab(old)])
        XCTAssertEqual(all.tabs.count, 3)
    }

    /// A pin's or a kept tab's home (the Mac's PinnedHome.swift) comes back
    /// out of every record the iPhone writes, as the Mac wrote it.
    func testATabsHomeSurvivesTheIPhonesWrites() throws {
        let record = Record(collection: SyncCollection.tab, id: "K", fields: [
            "parent": "S", "order": "A", "url": "https://mail.google.com/mail/u/0/#inbox/1", "title": "A mail",
            "kept": true, "home": "https://mail.google.com/mail/u/0/#inbox", "homeTitle": "Inbox",
        ])
        var tab = try XCTUnwrap(SyncTab(record))
        XCTAssertEqual(tab.home, "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(tab.homeTitle, "Inbox")
        tab.title = "A mail, renamed"
        XCTAssertEqual(tab.fields["home"], "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(tab.fields["homeTitle"], "Inbox")
        let row = RecordShapes.row(space: "S", tabs: [tab], folders: [:], pairs: [], orders: [:])
        let back = try XCTUnwrap(SyncTab(Record(collection: SyncCollection.tab, id: "K", fields: try XCTUnwrap(row.tabs["K"]))))
        XCTAssertEqual(back.home, tab.home)
        XCTAssertEqual(back.homeTitle, tab.homeTitle)

        // A record from an older copy has none and writes none, as the Mac.
        let older = try XCTUnwrap(SyncTab(Record(collection: SyncCollection.tab, id: "T", fields: ["parent": "S", "url": "https://a.test", "title": "A"])))
        XCTAssertNil(older.home)
        XCTAssertEqual(older.fields["home"], .null)
        XCTAssertEqual(older.fields["homeTitle"], .null)
    }

    func testIDsTheMacTakes() {
        var ids = IDs()
        let uuid = "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10"
        XCTAssertEqual(ids.sync(uuid), uuid)
        let made = ids.sync("work-hn")
        XCTAssertEqual(UUID(uuidString: made)?.uuidString, made, "an upper-case UUID")
        XCTAssertEqual(ids.sync("work-hn"), made)
        XCTAssertEqual(ids.local(made), "work-hn")
        XCTAssertNotEqual(ids.sync(uuid.lowercased()), uuid.lowercased(), "the Mac would give a lower-case id a new one")
    }

    func testRemovedChatKindsAreIgnored() {
        let record = Record(collection: SyncCollection.chat, id: "c:legacy", fields: ["kind": "code", "device": "mac-a"])
        XCTAssertNil(SyncChat(record))
    }

    func testAChatFromAMac() throws {
        let now = Date(timeIntervalSince1970: 1_759_700_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:k3", fields: [
            "device": "mac-a", "title": "Find a hotel", "state": "running", "updated": .number(now.timeIntervalSince1970 - 600),
            "started": .number(now.timeIntervalSince1970 - 900), "pinned": true,
        ])))
        func item(_ n: Int, _ kind: String, _ text: String) throws -> SyncChatItem {
            try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:k3/\(n)", fields: ["chat": "a:k3", "n": .number(Double(n)), "kind": .string(kind), "text": .string(text)])))
        }
        let items = [try item(1, "asked", "Find a hotel in Lisbon"), try item(2, "tool", "search"), try item(3, "message", "Memmo Alfama."),
                     try item(4, "asked", "Mac access was allowed for this task. Continue the original request: x")]
        let chat = SyncMapping.chat(head, items: items, sends: [], macAsleep: false, old: nil, now: now, calendar: calendar)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer, .typing])
        XCTAssertEqual(chat.messages.map(\.text).prefix(2), ["Find a hotel in Lisbon", "Memmo Alfama."])
        XCTAssertTrue(chat.pinned)
        XCTAssertEqual(chat.day, .today)
        XCTAssertEqual(chat.time.count, 5)
        // Words from here the Mac hasn't taken: shown, waiting for it while it sleeps.
        let send = try XCTUnwrap(SyncSend(Record(collection: "send", id: "s1", fields: ["device": "mac-a", "chat": "a:k3", "text": "A cheaper one?", "at": .number(1)])))
        var done = head
        done.state = "done"
        let waiting = SyncMapping.chat(done, items: items, sends: [send], macAsleep: true, old: nil, now: now, calendar: calendar)
        XCTAssertEqual(waiting.messages.map(\.role), [.you, .answer, .you, .wait])
        let older = SyncMapping.chat(SyncChat(Record(collection: "chat", id: "a:old", fields: ["device": "mac-a", "updated": .number(now.timeIntervalSince1970 - 86_400 * 30)]))!,
                                     items: [], sends: [], macAsleep: false, old: nil, now: now, calendar: calendar)
        XCTAssertEqual(older.day, .earlier)
        XCTAssertEqual(older.time, "Sep 5")
    }

    /// A card a tool made on the Mac stands under the turn's answer here;
    /// with no answer, on its own.
    func testResultCardsFollowTheAnswer() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:c", fields: ["device": "mac-a", "state": "done", "updated": 100])))
        func item(_ n: Int, _ kind: String, _ text: String, name: String = "") throws -> SyncChatItem {
            try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:c/\(n)", fields: ["chat": "a:c", "n": .number(Double(n)), "kind": .string(kind),
                                                                                          "name": .string(name), "text": .string(text), "state": "done"])))
        }
        let card = ResultCard(kind: .watch, title: "under $180", value: "$195", site: "fellowproducts.com", ref: "w1")
        let items = [try item(1, "asked", "Tell me when the Opus is under $180"), try item(2, "tool", "", name: "watch_page"),
                     try item(3, "card", card.json, name: "watch"), try item(4, "message", "Watching it.")]
        let chat = SyncMapping.chat(head, items: items, sends: [], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer])
        XCTAssertEqual(chat.messages.last?.cards, [card])
        let bare = SyncMapping.chat(head, items: Array(items.prefix(3)), sends: [], macAsleep: false, old: nil)
        let alone = try XCTUnwrap(bare.messages.first { !$0.cards.isEmpty })
        XCTAssertEqual(alone.cards, [card])
        XCTAssertEqual(alone.text, "")
        // Kept and read back with the chat.
        let kept = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(chat.messages[1]))
        XCTAssertEqual(kept.cards, [card])
    }

    func testTheQuietLinesWords() {
        XCTAssertEqual(SyncNote.macAsleep(2).words, "Mac asleep · 2 changes wait for it")
        XCTAssertEqual(SyncNote.macAsleep(1).words, "Mac asleep · 1 change waits for it")
        XCTAssertEqual(SyncNote.offline(50).words, "Offline · 50 changes wait to sync")
        XCTAssertEqual(SyncNote.removed.words, "Removed from Sync · Join Again")
    }

    func testRepeatedQuestionsAndSendFailuresRemainVisible() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:real", fields: ["device": "mac-a", "state": "done", "updated": 100])))
        let earlier = try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:real/1", fields: ["chat": "a:real", "n": 1, "kind": "asked", "text": "Again", "began": 1])))
        let waiting = try XCTUnwrap(SyncSend(Record(collection: "send", id: "one", fields: ["device": "mac-a", "chat": "a:real", "text": "Again", "at": 50])))
        let first = SyncMapping.chat(head, items: [earlier], sends: [waiting], macAsleep: true, old: nil)
        XCTAssertEqual(first.messages.map(\.role), [.you, .you, .wait], "same words are not deduplicated across turns")
        var failed = waiting
        failed.state = .failed("Not signed in")
        XCTAssertEqual(SyncMapping.chat(head, items: [earlier], sends: [failed], macAsleep: false, old: nil).messages.last?.text,
                       "Your Mac couldn’t take this question: Not signed in")
        var expired = waiting
        expired.state = .expired
        XCTAssertEqual(SyncMapping.chat(head, items: [earlier], sends: [expired], macAsleep: false, old: nil).messages.last?.text,
                       "This question expired before your Mac received it. Send it again.")
    }

    func testRunningLeftForHoursByAMacThatQuitIsNotWorking() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func head(_ ago: TimeInterval) throws -> SyncChat {
            try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:real", fields: [
                "device": "mac-a", "state": "running", "updated": .number(now.timeIntervalSince1970 - ago)])))
        }
        XCTAssertTrue(SyncMapping.chat(try head(600), items: [], sends: [], macAsleep: false, old: nil, now: now).working)
        XCTAssertFalse(SyncMapping.chat(try head(7 * 3600), items: [], sends: [], macAsleep: false, old: nil, now: now).working)
    }

    func testTakenContextIsReplacedByThePersonsQuestionWhenItsItemsArrive() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:real", fields: ["device": "mac-a", "state": "running", "updated": .number(Date().timeIntervalSince1970)])))
        let send = try XCTUnwrap(SyncSend(Record(collection: "send", id: "new", fields: ["device": "mac-a", "chat": "a:real", "text": "Page text and question", "question": "What is this?", "state": "taken", "at": 20, "took": 21])))
        let before = SyncMapping.chat(head, items: [], sends: [send], macAsleep: false, old: nil)
        XCTAssertEqual(before.messages.map(\.role), [.you, .typing])
        XCTAssertEqual(before.messages.first?.text, "What is this?")
        let asked = try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:real/1", fields: ["chat": "a:real", "n": 1, "kind": "asked", "text": "Page text and question", "began": 20])))
        let after = SyncMapping.chat(head, items: [asked], sends: [send], macAsleep: false, old: nil)
        XCTAssertEqual(after.messages.map(\.role), [.you, .typing])
        XCTAssertEqual(after.messages.first?.text, "What is this?")
    }

    func testTakenPromptMatchesTheMacsEightThousandCharacterItemLimit() throws {
        let head = try XCTUnwrap(SyncChat(Record(collection: "chat", id: "a:real", fields: ["device": "mac-a", "state": "running", "updated": .number(Date().timeIntervalSince1970)])))
        let prompt = "Question: Summarize this page\n" + String(repeating: "Actual page words ", count: 600)
        let send = try XCTUnwrap(SyncSend(Record(collection: "send", id: "new", fields: ["device": "mac-a", "chat": "a:real", "text": .string(prompt), "question": "Summarize this page", "state": "taken", "at": 20, "took": 21])))
        // SyncChats.items publishes String(item.text.prefix(8000)).
        let asked = try XCTUnwrap(SyncChatItem(Record(collection: "chatitem", id: "a:real/1", fields: ["chat": "a:real", "n": 1, "kind": "asked", "text": .string(String(prompt.prefix(8000))), "began": 20])))
        let chat = SyncMapping.chat(head, items: [asked], sends: [send], macAsleep: false, old: nil)
        XCTAssertEqual(chat.messages.map(\.role), [.you, .typing])
        XCTAssertEqual(chat.messages.first?.text, "Summarize this page")
    }

    func testPrivateTabsKeepTheirPlaceAmongTodays() {
        func tab(_ id: String, _ isPrivate: Bool = false) -> Tab {
            Tab(id: id, title: id, site: id, icon: id, isPrivate: isPrivate)
        }
        let ids = { (tabs: [Tab]) in tabs.map(\.id) }
        // In the middle: still between the same two, and the Mac's new tab first.
        XCTAssertEqual(ids(SyncMapping.keepingPrivates([tab("a"), tab("p", true), tab("b")], in: [tab("new"), tab("a"), tab("b")])),
                       ["new", "a", "p", "b"])
        // At the top: under the Mac's new tab, above the row it stood on.
        XCTAssertEqual(ids(SyncMapping.keepingPrivates([tab("p", true), tab("q", true), tab("a")], in: [tab("new"), tab("a")])),
                       ["new", "p", "q", "a"])
        // The row under it gone: after the one above.
        XCTAssertEqual(ids(SyncMapping.keepingPrivates([tab("a"), tab("p", true), tab("b")], in: [tab("a")])), ["a", "p"])
        // Everything around it gone: at the end.
        XCTAssertEqual(ids(SyncMapping.keepingPrivates([tab("p", true), tab("b")], in: [tab("c")])), ["c", "p"])
        // No private tab: sync's rows as they are.
        XCTAssertEqual(ids(SyncMapping.keepingPrivates([tab("a")], in: [tab("b"), tab("a")])), ["b", "a"])
    }
}
