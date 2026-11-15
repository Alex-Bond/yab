import AppKit
import Testing
import WebKit
import SyncKit
@testable import Fast

/// A live folder's rows (docs/live-folders.md, "Rows, pages and sleep"):
/// 1. a row the folder brings is a link with its status, refreshed from the
///    source; a refresh or a new row never builds a page;
/// 2. opened, it is an ordinary tab and sleeps as today's tabs do, whatever
///    the folder does to it after;
/// 3. sync carries the row and its status, and a row come by sync is
///    unloaded too;
/// 4. only a tab moved in by hand, or taken out, keeps the kept rules.
/// Kept, every pull request opened from a folder stayed loaded for the
/// session, however big.
@MainActor
@Suite(.serialized)
struct LiveFolderSleepTests {
    private func world(_ body: (Browser) async throws -> Void) async rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        try await body(browser)
    }

    private func loaded(_ tabs: [Tab]) async throws {
        for tab in tabs {
            for _ in 0..<150 where tab.loading { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!tab.loading)
        }
    }

    /// A pull request as the source lists it; the host never answers, so
    /// no test reaches a real site.
    private func item(_ n: Int, _ words: LiveWords?) -> LiveItem {
        let url = URL(string: "http://127.0.0.1:9/acme/yab/pull/\(n)")!
        return LiveItem(key: LiveFolder.key(url)!, url: url, title: "Pull request \(n)", group: "acme/yab", words: words, updated: nil)
    }

    private func folder() -> Nest {
        let nest = Nest(name: "Pull Requests")
        nest.live = Live(source: "github.pulls", host: "github.com", show: LiveGitHub.shownAtFirst)
        return nest
    }

    // 1 and 2: rows come and change with no page; one opened stays ordinary.
    @Test func aRefreshBringsRowsAndStatusAndNeverAPage() async throws {
        try await world { browser in
            // Open in today's before the folder lists it: the folder takes it in.
            let today = browser.open(URL(string: "http://127.0.0.1:9/acme/yab/pull/9")!, foreground: true)
            let front = browser.open(URL(string: "about:blank#front")!, foreground: true)
            try await loaded([today, front])
            #expect(today.builtPage != nil && !today.kept)
            let nest = folder()
            let rows = { browser.tabs.filter { $0.nest === nest } }
            let row = { (n: Int) in rows().first { $0.live?.key == self.item(n, nil).key } }

            LiveFolders.shared.apply((1...5).map { item($0, .review) } + [item(9, .review)], to: nest, in: browser)
            try await Task.sleep(for: .milliseconds(300))
            let brought = rows().filter { $0.id != today.id }
            #expect(brought.count == 5)
            #expect(brought.allSatisfy { $0.asleep && $0.builtPage == nil }, "a row the folder brings has no page")
            #expect(rows().allSatisfy { $0.kept && $0.placedByFolder })
            #expect(row(9)?.id == today.id, "today's tab of the same pull request moved in")

            // Words change, one goes, two come: still no page anywhere.
            LiveFolders.shared.apply((2...7).map { item($0, .failing) } + [item(9, .failing)], to: nest, in: browser)
            try await Task.sleep(for: .milliseconds(300))
            #expect(row(1) == nil)
            #expect(row(6) != nil && row(7) != nil)
            #expect(rows().filter { $0.id != today.id }.allSatisfy { $0.asleep && $0.builtPage == nil })
            #expect(rows().allSatisfy { $0.live?.words == .failing })

            // The open one, taken in and refreshed by the folder, is still an
            // ordinary tab: left, the timer and memory out may take it.
            #expect(today.placedByFolder)
            #expect(browser.awake(because: today) == nil)
            today.touch(at: Date(timeIntervalSinceNow: -660))
            #expect(browser.mayLighten(today))
        }
    }

    // 2 and 4: opened rows sleep as today's; by hand keeps the kept rules.
    @Test func anOpenedRowSleepsAsTodaysTabsDo() async throws {
        try await world { browser in
            let pull = browser.open(URL(string: "about:blank#acme-yab-pull-12")!, foreground: true)
            let made = browser.open(URL(string: "about:blank#acme-yab-pull-13")!, foreground: true)
            let hand = browser.open(URL(string: "about:blank#acme-yab-pull-14")!, foreground: true)
            // Past the last few tabs used, which nothing puts down.
            let others = (0...Browser.keepRecent).map {
                browser.open(URL(string: "about:blank#other-\($0)")!, foreground: true)
            }
            try await loaded([pull, made, hand] + others)
            #expect(!browser.recentlyUsed().contains(pull.id))
            let folder = UUID()
            // Brought by the folder.
            pull.kept = true
            pull.live = LiveMark(key: "github.com/acme/yab/pull/12", words: .review, seen: nil, folder: folder)
            // The pull request you just made, moved in by the folder itself.
            made.kept = true
            made.live = LiveMark(key: "github.com/acme/yab/pull/13", words: nil, seen: nil, folder: folder, yours: true, moved: true)
            // Moved in by your hand: the folder gives it words, nothing more.
            hand.kept = true
            hand.live = LiveMark(key: "github.com/acme/yab/pull/14", words: nil, seen: nil, folder: folder, yours: true)
            #expect(pull.placedByFolder && made.placedByFolder && !hand.placedByFolder)
            #expect(pull.broughtByFolder && !made.broughtByFolder, "the folder never takes away the one you made")

            #expect(browser.awake(because: pull) == nil, "a folder's row is no tab you chose to keep")
            #expect(browser.awake(because: made) == nil)
            #expect(browser.awake(because: hand) == "kept")

            // Left eleven minutes: memory out and a page grown heavy may take it.
            for tab in [pull, made, hand] { tab.touch(at: Date(timeIntervalSinceNow: -660)) }
            #expect(browser.mayLighten(pull) && browser.mayLighten(made))
            #expect(!browser.mayLighten(hand))
            #expect([pull.id, made.id].contains(browser.relief(now: AwakeClock.now)?.id ?? UUID()))

            // Past the timer's wait (Sleep Tabs on), the timer takes it too.
            let later = AwakeClock.now + Browser.sleepAfter + 60
            let idle = Set(browser.idleTabs(within: Browser.sleepAfter, now: later).map(\.id))
            #expect(idle.contains(pull.id) && idle.contains(made.id))
            #expect(!idle.contains(hand.id))

            // Taken out of the folder by hand, it is yours: kept again.
            pull.live = nil
            #expect(!pull.placedByFolder)
            #expect(browser.awake(because: pull) == "kept")
        }
    }

    // 3: sync carries rows and status; a row come by sync is unloaded.
    @Test func aRowComeBySyncIsUnloadedAndKeepsWhoPutItThere() async throws {
        try await world { here in
            let nest = folder()
            LiveFolders.shared.apply((1...3).map { item($0, .review) }, to: nest, in: here)
            let rows = here.tabs.filter { $0.nest === nest }
            #expect(rows.count == 3)
            // One the folder moved in (the one you made), one you moved in by hand.
            rows[1].live?.yours = true
            rows[1].live?.moved = true
            rows[2].live?.yours = true
            let written = Session.Shape(tabs: rows.compactMap { here.sessionEntry($0, id: $0.id) }, front: nil)
            #expect(written.tabs.count == 3)

            let space = UUID()
            let out = SyncShapes.rows([space: written], orders: [:])
            let journal = try Journal(path: nil, device: "live-sleep-test")
            try journal.reconcile(SyncShapes.tab, out.tabs)
            try journal.reconcile(SyncShapes.folder, out.folders)
            let come = SyncShapes.row(space, tabs: journal.all(SyncShapes.tab), folders: journal.all(SyncShapes.folder), pairs: [],
                                      here: .init(tabs: [], front: nil))
            #expect(come.tabs.count == 3)
            #expect(come.tabs.allSatisfy { $0.live?.words == .review && $0.folderLive?.source == "github.pulls" })

            try await world { there in
                there.adopt(come, in: there.spaceID)
                try await Task.sleep(for: .milliseconds(300))
                // By what it is: this process still holds the first Mac's tabs, so
                // the ids come back new (Tab.returning).
                let arrived = rows.compactMap { row in there.tabs.first { $0.live?.key == row.live?.key } }
                #expect(arrived.count == 3)
                #expect(arrived.allSatisfy { $0.asleep && $0.builtPage == nil }, "a row come by sync has no page")
                #expect(arrived.allSatisfy { $0.kept && $0.nest?.live?.source == "github.pulls" && $0.live?.words == .review })
                #expect(arrived[0].placedByFolder && arrived[1].placedByFolder)
                #expect(!arrived[2].placedByFolder, "moved in by hand on the other Mac: kept rules here too")
            }
        }
    }
}
