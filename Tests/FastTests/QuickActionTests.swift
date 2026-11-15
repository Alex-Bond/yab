import Foundation
import Testing
@testable import Fast

@MainActor
struct QuickActionTests {
    private struct Snapshot: Encodable {
        let actions: [QuickAction]
        let personalized: Set<String> = []
        let dismissed: Set<String> = []
    }

    private func history(_ pairs: [(String, Int)]) -> History {
        History(pairs.map { host, count in
            Visit(url: "https://\(host)/recent", key: host + "/recent", title: host,
                  count: count, last: Date(), typed: nil)
        })
    }

    @Test func siteScoresInOneWalkMatchEachSiteWalkedAlone() {
        let now = Date()
        let urls = ["https://docs.google.com/document/d/1", "https://WWW.Notion.so/page", "https://user@github.com:443/new",
                    "http://docs.google.com/spreadsheets/d/2?x=1", "https://notion.so.evil.com/", "https://evil.com/notion.so",
                    "https://sheets.google.com#top", "notaurl", "https://figma.com", "https://www.figma.com/file/abc"]
        var visits: [String: Visit] = [:]
        for (index, url) in urls.enumerated() {
            visits["k\(index)"] = Visit(url: url, key: "k\(index)", title: "", count: index + 1, last: now, typed: index % 2)
        }
        let sites: [(host: String, path: String?)] = [("docs.google.com", "/document"), ("docs.google.com", "/spreadsheets"),
                                                      ("notion.so", nil), ("github.com", nil), ("sheets.google.com", nil),
                                                      ("figma.com", nil), ("figma.com", "/file")]
        let together = History.siteScores(visits, sites: sites, now: now)
        // The old way: every address parsed, for each site on its own.
        for (index, site) in sites.enumerated() {
            let alone = visits.values.reduce(0.0) { score, visit in
                guard let url = URL(string: visit.url), let found = url.host()?.lowercased(),
                      found == site.host || found == "www." + site.host else { return score }
                if let path = site.path, !url.path().hasPrefix(path) { return score }
                let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
                return score + Double(visit.count + 2 * (visit.typed ?? 0)) * exp(-days / 30)
            }
            #expect(together[index] == alone, "\(site)")
        }
        #expect(together[2] > 0 && together[3] > 0)
    }

    @Test func aLargeHistoryIsWeighedOffTheMainThreadAndStillSuggests() async {
        let now = Date()
        var list = (0..<(History.cap + 500)).map { index in
            Visit(url: "https://example\(index).com/", key: "example\(index).com", title: "", count: 1, last: now, typed: nil)
        }
        list.append(Visit(url: "https://notion.so/recent", key: "notion.so/recent", title: "", count: 18, last: now, typed: nil))
        list.append(Visit(url: "https://sheets.google.com/recent", key: "sheets.google.com/recent", title: "", count: 7, last: now, typed: nil))
        let actions = QuickActions(history: History(list), stored: Data())
        for _ in 0..<200 where actions.action("new-document")?.url != "https://notion.new" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(actions.action("new-document")?.url == "https://notion.new")
        #expect(actions.suggestions.contains { $0.id == "new-spreadsheet" })
    }

    @Test func aliasesFindAnActionWithoutChangingSiteSearch() {
        let actions = QuickActions(history: history([]), stored: Data())
        #expect(actions.exact("doc")?.id == "new-document")
        #expect(actions.matches("new doc").first?.id == "new-document")
        #expect(actions.exact("docs.new") == nil)
        #expect(actions.matches("do").count == 1)
    }

    @Test func historyChoosesNotionAndSuggestsUnaddedFormats() {
        let visits = history([("notion.so", 18), ("docs.google.com", 3), ("sheets.google.com", 7)])
        let actions = QuickActions(history: visits, stored: Data())
        #expect(actions.action("new-document")?.url == "https://notion.new")
        #expect(actions.suggestions.contains { $0.id == "new-spreadsheet" })
        #expect(actions.action("new-meeting")?.url == "https://meet.new")
    }

    @Test func aUserChosenProviderSurvivesLaterHistory() {
        let visits = history([("notion.so", 18)])
        let actions = QuickActions(history: visits, stored: Data())
        var document = actions.action("new-document")!
        document.url = "https://docs.new"
        #expect(actions.put(document) == nil)
        actions.refresh(from: visits)
        #expect(actions.action("new-document")?.url == "https://docs.new")
    }

    @Test func addressAndAliasValidation() {
        let actions = QuickActions(history: history([]), stored: Data())
        var custom = QuickAction(id: "mine", name: "Open", url: "javascript:alert(1)", alias: "open", custom: true)
        #expect(actions.problem(with: custom) != nil)
        custom.url = "https://example.com/new"
        custom.alias = "doc"
        #expect(actions.problem(with: custom)?.contains("New document") == true)
        custom.alias = "two words"
        #expect(actions.problem(with: custom) != nil)
        custom.alias = "write"
        #expect(actions.problem(with: custom) == nil)
    }

    @Test func aDisabledActionStillOwnsItsHotkey() throws {
        let key = Hotkey("f15", [.control, .option, .command]).stored
        let first = QuickAction(id: "first", name: "First", url: "https://example.com/first",
                                alias: "first", shortcut: key, enabled: false, custom: true)
        let stored = try JSONEncoder().encode(Snapshot(actions: [first]))
        let actions = QuickActions(history: history([]), stored: stored)
        let second = QuickAction(id: "second", name: "Second", url: "https://example.com/second",
                                 alias: "second", shortcut: key, custom: true)
        #expect(actions.put(second)?.contains("First") == true)
        #expect(actions.action("second") == nil)
    }

    @Test func enablingLegacyDuplicateShowsAnErrorAndKeepsItOff() throws {
        let key = Hotkey("f15", [.control, .option, .command]).stored
        let first = QuickAction(id: "first", name: "First", url: "https://example.com/first",
                                alias: "first", shortcut: key, custom: true)
        let second = QuickAction(id: "second", name: "Second", url: "https://example.com/second",
                                 alias: "second", shortcut: key, enabled: false, custom: true)
        let stored = try JSONEncoder().encode(Snapshot(actions: [first, second]))
        let actions = QuickActions(history: history([]), stored: stored)
        #expect(actions.setEnabled("second", true)?.contains("First") == true)
        #expect(actions.action("second")?.enabled == false)
    }

    @Test func intentWordsFindActionsAndSuggestions() {
        let visits = history([("sheets.google.com", 7)])
        let actions = QuickActions(history: visits, stored: Data())
        #expect(actions.matches("new").map(\.id) == ["new-document", "new-meeting"])
        #expect(actions.matches("call").map(\.id) == ["new-meeting"])
        #expect(actions.matches("cre mee").map(\.id) == ["new-meeting"])
        #expect(actions.matches("new york").isEmpty)
        #expect(actions.offered("new sh").map(\.id) == ["new-spreadsheet"])
        #expect(actions.offered("new").map(\.id) == ["new-spreadsheet"])
        #expect(actions.offered("zoom").isEmpty)
    }

    @Test func somethingMadeIsCountedOnceAndPicksTheProvider() {
        let actions = QuickActions(history: history([("docs.google.com", 9)]), stored: Data())
        let start = Date()
        for day in 0..<3 {
            let now = start.addingTimeInterval(Double(day) * 3600)
            actions.noticed(URL(string: "https://www.notion.so/new")!, now: now)
            // The page it made, a moment later: the same thing.
            actions.noticed(URL(string: "https://www.notion.so/Untitled-\(day)")!, title: "Untitled", now: now.addingTimeInterval(3))
        }
        #expect(actions.count("notion", now: start) == 3)
        #expect(actions.action("new-document")?.url == "https://notion.new")
        // Read, not made: someone else's document by its name.
        actions.noticed(URL(string: "https://docs.google.com/document/d/abc/edit")!, title: "Q4 plan - Google Docs")
        #expect(actions.count("docs") == 0)
        actions.noticed(URL(string: "https://docs.google.com/document/d/xyz/edit")!, title: "Untitled document - Google Docs")
        #expect(actions.count("docs") == 1)
    }

    @Test func meetingsJoinedDontMoveNewMeetingButStartedOnesDo() {
        let actions = QuickActions(history: history([("zoom.us", 40)]), stored: Data())
        actions.noticed(URL(string: "https://zoom.us/j/81234567")!)
        #expect(actions.action("new-meeting")?.url == "https://meet.new")
        let start = Date()
        for minute in 0..<3 {
            actions.noticed(URL(string: "https://zoom.us/s/8123456\(minute)")!, now: start.addingTimeInterval(Double(minute) * 120))
        }
        #expect(actions.action("new-meeting")?.url == "https://zoom.new")
        #expect(actions.matches("zoom").map(\.id) == ["new-meeting"])
    }

    @Test func madeByHandHintsTheAliasTwiceAtMost() {
        let actions = QuickActions(history: history([]), stored: Data())
        let start = Date()
        actions.noticed(URL(string: "https://docs.google.com/document/u/0/create")!, now: start)
        #expect(actions.hinting(now: start)?.id == "new-document")
        actions.showedHint("new-document", now: start)
        actions.showedHint("new-document", now: start.addingTimeInterval(10))
        actions.showedHint("new-document", now: start.addingTimeInterval(120))
        #expect(actions.hinting(now: start.addingTimeInterval(130)) == nil)

        // Opened by the action itself: nothing to teach.
        let other = QuickActions(history: history([]), stored: Data())
        other.ran(URL(string: "https://docs.new")!)
        other.noticed(URL(string: "https://docs.new")!)
        #expect(other.hinting() == nil)
        #expect(other.count("docs") == 1)
    }

    @Test func catalogOffersOnlyCheckedMakersForSitesInUse() {
        let actions = QuickActions(history: history([("linear.app", 12), ("github.com", 30), ("example.com", 90)]), stored: Data())
        let offered = Set(actions.suggestions.map(\.id))
        #expect(offered == ["new-linear-issue", "new-repository"])
        let issue = actions.suggestion("new-linear-issue")!
        actions.accept(issue)
        #expect(actions.exact("issue")?.url == "https://linear.new")
        #expect(actions.suggestion("new-linear-issue") == nil)
    }
}
