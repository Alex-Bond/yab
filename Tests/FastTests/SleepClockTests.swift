import AppKit
import Testing
@testable import Fast

/// When tabs sleep: on the awake clock, never a kept row on the timer, and
/// memory running short taking one tab at a time.
struct SleepClockTests {
    /// A window with `count` hidden pages behind the one on screen.
    @MainActor private func world(_ count: Int) async throws -> (Browser, [Tab], () -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let hidden = (0..<count).map { browser.open(URL(string: "about:blank#hidden\($0)")!, foreground: true) }
        _ = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        for tab in hidden {
            for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(!tab.loading)
            #expect(browser.awake(because: tab) == nil)
        }
        // Opened in front one after another, each was left in turn: none
        // was ever gone back to, so none is among the last few used
        // (RecentTabsSleepTests).
        browser.recent = []
        let done = {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        return (browser, hidden, done)
    }

    @Test func wallClockMomentsLandOnTheAwakeClock() {
        let wall = Date(timeIntervalSince1970: 1_000_000)
        // Two hours before, the Mac awake all the while.
        #expect(AwakeClock.since(wall.addingTimeInterval(-7200), now: 10_000, wall: wall) == 10_000 - 7200)
        // Before the Mac started: below zero, and still as long ago.
        #expect(AwakeClock.since(wall.addingTimeInterval(-7200), now: 600, wall: wall) == 600 - 7200)
        // A moment ahead of the wall clock, set back since, is now.
        #expect(AwakeClock.since(wall.addingTimeInterval(60), now: 600, wall: wall) == 600)
    }

    @MainActor @Test func idleTimeCountsOnlyTheMacAwake() async throws {
        let (browser, hidden, done) = try await world(1)
        defer { done() }
        let tab = hidden[0]
        tab.touch()
        let now = AwakeClock.now
        // However far the wall clock went while the Mac slept, the tab has
        // been left only as long as the awake clock says.
        #expect(tab.idle(at: now) < 5)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: now + Browser.usualSleepAfter - 60).isEmpty)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: now + Browser.usualSleepAfter + 60).map(\.id) == [tab.id])

        // Brought back from the session file, last seen two hours ago.
        tab.touch(at: Date().addingTimeInterval(-7200))
        #expect(abs(tab.idle(at: AwakeClock.now) - 7200) < 5)
        #expect(browser.idleTabs(within: 3600, now: AwakeClock.now).map(\.id) == [tab.id])
    }

    @MainActor @Test func keptRowsStayAwakeOnTheTimer() async throws {
        let (browser, hidden, done) = try await world(1)
        defer { done() }
        let tab = hidden[0]
        tab.touch()
        tab.kept = true
        let now = AwakeClock.now
        #expect(browser.awake(because: tab) == "kept")
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: now + 24 * 3600).isEmpty)
        // Memory out: never, as a pin, however long it was left.
        #expect(browser.relief(now: now + 5 * 60) == nil)
        #expect(browser.relief(now: now + 11 * 60) == nil)
        #expect(browser.relief(now: now + 24 * 3600) == nil)
        // A swollen or stuck page goes whether kept or not.
        #expect(browser.mayPutDown(tab))

        tab.kept = false
        #expect(browser.awake(because: tab) == nil)
        #expect(browser.idleTabs(within: Browser.usualSleepAfter, now: now + Browser.usualSleepAfter + 60).map(\.id) == [tab.id])
    }

    @MainActor @Test func memoryOutTakesOnlyATabLeftTenMinutes() async throws {
        let (browser, hidden, done) = try await world(2)
        defer { done() }
        for tab in hidden { tab.touch() }
        let now = AwakeClock.now
        // Only a tab left alone ten minutes.
        #expect(browser.relief(now: now) == nil)
        #expect(browser.relief(now: now + 60) == nil)
        #expect(browser.relief(now: now + 9 * 60) == nil)
        let first = try #require(browser.relief(now: now + 11 * 60))
        #expect(hidden.contains { $0 === first })
        // Never a pin, however long.
        for tab in hidden { tab.pin = "P" }
        #expect(browser.relief(now: now + 3600) == nil)
        for tab in hidden { tab.pin = nil }
        // A tab heard in the last minute stays.
        hidden[0].heardAt = Date()
        #expect(browser.awake(because: hidden[0]) == "played sound a moment ago")
        #expect(browser.relief(now: now + 11 * 60)?.id == hidden[1].id)
        hidden[0].heardAt = Date(timeIntervalSinceNow: -61)
        #expect(browser.awake(because: hidden[0]) == nil)
        hidden[0].heardAt = nil
    }
}
