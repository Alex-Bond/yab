import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct HistoryPlaceReturnTests {
    private func drainDiary() async {
        await withCheckedContinuation { done in
            Diary.shared.list(before: nil) { _ in done.resume() }
        }
    }

    @Test func commandTRestoresTheHistoryQueryAsWellAsItsLabel() async throws {
        try #require(Store.testing)
        let browser = Browser(windowID: UUID())
        browser.history = History([])
        let url = URL(string: "https://omnibox-bench.invalid/history-return")!
        defer {
            browser.close()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            Diary.shared.forget(keys: [Diary.key(url)])
        }
        Diary.shared.visit(url, title: "History return fixture", tab: UUID(), quiet: true)
        await drainDiary()

        browser.openFresh()
        browser.enterPlace(.history)
        await drainDiary()
        #expect(browser.query.stock.visits.contains { $0.title == "History return fixture" })

        // A quiet visit belongs in All Time but never creates a day thread.
        // Restoring By Thread must ask for threads, not label a page list as
        // By Thread. The prior test checked the label alone and missed this.
        browser.query.placeFilter = FieldPlace.byThread
        browser.askHistory()
        await drainDiary()
        browser.close()
        browser.pressNewTab()
        await drainDiary()
        #expect(browser.query.place == .history)
        #expect(browser.query.placeFilter == FieldPlace.byThread)
        #expect(browser.query.stock.ended, "the restored thread query must have answered")
        #expect(browser.query.stock.visits.allSatisfy { $0.what.isThread })

        // The direct History action opens All Time again, with real rows,
        // after the remembered destination was a different query.
        browser.close()
        browser.openPlace(.history)
        await drainDiary()
        #expect(browser.query.placeFilter == 0)
        #expect(browser.query.stock.visits.contains { $0.title == "History return fixture" })

        // A directly opened History is not a Cmd-T destination.
        // Enter through the field before checking its restored All Time rows.
        browser.close()
        browser.newTab()
        #expect(browser.query.place == nil)
        browser.enterPlace(.history)
        await drainDiary()

        // Picking a row calls close(). The next Cmd-T must load it again.
        browser.close()
        browser.pressNewTab()
        await drainDiary()
        #expect(browser.query.placeFilter == 0)
        #expect(browser.query.stock.visits.contains { $0.title == "History return fixture" })
    }
}
