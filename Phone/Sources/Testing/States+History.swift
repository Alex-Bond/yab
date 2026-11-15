import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

/// History's named states, registered here and nowhere else: the screen with
/// pages (this iPhone's and the Mac's), searching, empty, Clear's ranges, a
/// row swiped to Delete, History as Settings' page, and the field offering
/// a page from History and a bookmark of the Mac's for typed words.
extension StateCatalog {
    static let history: [NamedState] = [
        NamedState("history.items", "History", "Today, Yesterday, a date; the Mac's pages say MacBook Pro. Its own sheet, × closes.") { app in
            seedHistory(app)
            app.showHistory()
        },
        NamedState("history.searching", "History: search", "«wiki»: the pages whose title or address has the word.") { app in
            seedHistory(app)
            app.history.query = "wiki"
            app.showHistory()
        },
        NamedState("history.empty", "History: empty", "Nothing opened yet: the clock and two lines.") { app in
            app.showHistory()
        },
        NamedState("history.clear", "History: Clear", "Clear History? Last Hour, Today, Today and Yesterday, All Time.") { app in
            seedHistory(app)
            app.showHistory()
            try? await Task.sleep(for: .milliseconds(700))
            app.history.asksClear = true
        },
        NamedState("history.swiped", "History: Delete", "Today's first row swiped left: a card, Delete behind it.") { app in
            seedHistory(app)
            app.showHistory()
            try? await Task.sleep(for: .milliseconds(700))
            guard let first = app.history.entries.first else { return }
            app.history.swipe = HistorySwipe(id: first.id, x: -Metrics.Swipe.tabOpen)
        },
        NamedState("history.ready", "Settings, History to open", "Settings' root over a few days of pages, for a finger to open History.") { app in
            seedHistory(app)
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
        },
        NamedState("history.settings", "History in Settings", "Settings › History: ‹ back to Settings.") { app in
            seedHistory(app)
            SettingsUI.shared.assumeDefaultBrowser = true
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.history)
        },
        NamedState("field.history", "History in the field", "«flyt»: History's page before the search (top hit), then a bookmark of the Mac's.") { app in
            seedHistory(app)
            app.surfaces.openField(.newTab)
            app.field.typed("flyt")
        },
    ]

    /// A few days of pages, relative to now so they fall on Today, Yesterday
    /// and a date whenever the picture is taken: this iPhone's visits, the
    /// Mac's in sync, and the Mac's bookmarks.
    @MainActor
    static func seedHistory(_ app: AppModel, now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sinceMidnight = now.timeIntervalSince(today)
        func todayAt(_ fraction: Double) -> Date { today.addingTimeInterval(sinceMidnight * fraction) }
        func day(_ back: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .day, value: -back, to: today)!.addingTimeInterval(Double(hour * 3_600 + minute * 60))
        }
        func visit(_ url: String, _ title: String, _ icon: String, _ at: Date, count: Int = 1) -> BrowserVisit {
            let host = URL(string: url)?.host()?.lowercased() ?? url
            return BrowserVisit(url: url, title: title, site: HistoryList.bare(host), icon: icon, host: host, visitedAt: at, count: count)
        }
        app.history.fixtureVisits = [
            visit("https://en.wikipedia.org/wiki/Lisbon", "Lisbon · Wikipedia", "wiki", todayAt(0.97), count: 2),
            visit("https://paulgraham.com/greatwork.html", "How to Do Great Work", "paul", todayAt(0.9), count: 3),
            visit("https://news.ycombinator.com/", "Hacker News", "hn", todayAt(0.6), count: 12),
            visit("https://en.wikipedia.org/wiki/Alfama", "Alfama · Wikipedia", "wiki", day(1, 21, 30)),
            visit("https://www.flytap.com/en-se/flights/lisbon", "Flights to Lisbon · TAP Air Portugal", "tap", day(1, 19, 50), count: 3),
            visit("https://www.theverge.com/", "The Verge", "verge", day(1, 18, 5), count: 4),
            visit("https://www.nngroup.com/videos/jakobs-law-internet-ux/", "Jakob's Law of Internet User Experience", "nng", day(1, 9, 15)),
            visit("https://nordbutik.se/fjord-linen-throw", "Fjord linen throw · Nordbutik", "nordbutik", day(3, 20, 40)),
            visit("https://www.timeout.com/lisbon", "The best things to do in Lisbon", "timeout", day(3, 12, 10)),
        ].sorted { $0.visitedAt > $1.visitedAt }
        func place(_ url: String, _ title: String, _ at: Date) -> SyncedPlace {
            SyncedPlace(key: HistoryList.key(url), url: url, title: title, last: at.timeIntervalSince1970.rounded(.down),
                        typed: false, device: "mac")
        }
        app.history.fixtureDevices["mac"] = app.macName
        app.history.adoptSynced([
            place("https://lumen.events/e/design-systems-night", "Design Systems Night · Stockholm", todayAt(0.75)),
            place("https://github.com/excalidraw/excalidraw/pull/12192", "feat(editor): wrap text at 800 and keep it clear of the side panels", day(1, 13, 40)),
            place("https://www.airbnb.com/rooms/alfama-loft", "Alfama loft with river view · Airbnb", day(3, 16, 25)),
        ], own: "iphone")
        app.history.adoptBookmarks([
            SyncBookmark(title: "Paul Graham: Essays", url: "https://paulgraham.com/articles.html"),
            SyncBookmark(title: "TAP Miles&Go", url: "https://www.flytap.com/en-se/miles-and-go"),
            SyncBookmark(title: "Lumen events", url: "https://lumen.events/"),
        ])
    }
}
