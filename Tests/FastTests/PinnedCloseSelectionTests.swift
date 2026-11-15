import Foundation
import Testing
@testable import Fast

@MainActor
struct PinnedCloseSelectionTests {
    private func world(_ body: (Browser) -> Void) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.lay([])
        defer {
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        body(browser)
    }

    private func page(_ browser: Browser, _ name: String, pin: Bool = false, kept: Bool = false) -> Tab {
        let tab = browser.open(URL(string: "about:blank#\(name)")!, foreground: false)
        if pin { browser.pin(tab) }
        if kept { browser.keepTabs([tab]) }
        return tab
    }

    @Test(arguments: [false, true])
    func closingPinReturnsToTheLastViewedHeldPage(kept: Bool) {
        world { browser in
            let previous = page(browser, "previous", pin: !kept, kept: kept)
            let closing = page(browser, "closing", pin: true)
            browser.select(previous)
            browser.select(closing)
            browser.shut([closing], byKey: true)
            #expect(browser.active === previous && !browser.fieldShowing)
            #expect(closing.asleep && closing.pin != nil)
            #expect(browser.tabs.count == 2 && browser.ghosts.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func mostRecentAwakePageWinsAcrossPinnedAndTodaysTabs(pinMostRecent: Bool) {
        world { browser in
            let pin = page(browser, "pin", pin: true)
            let today = page(browser, "today")
            let closing = page(browser, "closing", pin: true)
            browser.select(closing)
            pin.touch(at: Date(timeIntervalSince1970: pinMostRecent ? 20 : 10))
            today.touch(at: Date(timeIntervalSince1970: pinMostRecent ? 10 : 20))
            browser.close(closing)
            #expect(browser.active === (pinMostRecent ? pin : today))
            #expect(!browser.fieldShowing)
        }
    }

    @Test func repeatedCloseDoesNotWakePinsPutDownEarlier() {
        world { browser in
            let previous = page(browser, "previous", pin: true)
            let closing = page(browser, "closing", pin: true)
            browser.select(previous)
            browser.select(closing)
            browser.close(closing)
            #expect(browser.active === previous)
            browser.shut(browser.chosen, byKey: true)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect(previous.asleep && closing.asleep)
            #expect(browser.tabs.count == 2)
        }
    }

    @Test func sleepingHeldPagesAreSkippedEvenIfMoreRecent() {
        world { browser in
            let sleeping = page(browser, "sleeping", pin: true)
            let kept = page(browser, "kept", kept: true)
            let today = page(browser, "today")
            let closing = page(browser, "closing", pin: true)
            sleeping.rest(closing: true)
            kept.rest(closing: true)
            sleeping.touch(at: Date(timeIntervalSinceNow: 60))
            kept.touch(at: Date(timeIntervalSinceNow: 120))
            browser.select(closing)
            browser.close(closing)
            #expect(browser.active === today)
            #expect(sleeping.asleep && kept.asleep)
        }
    }

    @Test func awakePinWinsOverMoreRecentSleepingTodaysTab() {
        world { browser in
            let previous = page(browser, "previous", pin: true)
            let today = page(browser, "today")
            let closing = page(browser, "closing", pin: true)
            today.rest()
            today.touch(at: Date(timeIntervalSinceNow: 60))
            browser.select(closing)
            browser.close(closing)
            #expect(browser.active === previous && today.asleep)
        }
    }

    @Test func sleepingTodaysTabIsNotWokenWhenNoLivePageRemains() {
        world { browser in
            let today = page(browser, "today")
            let closing = page(browser, "closing", pin: true)
            today.rest()
            browser.select(closing)
            browser.close(closing)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect(today.asleep)
        }
    }

    // Register #1071 (@mufaaf): pins X and reddit, one of today's. On X,
    // then reddit, then today's, closing today's left the field with
    // nothing in front; as in Arc it goes back to reddit, the page before.
    @Test(arguments: [false, true])
    func closingTheLastOfTodaysReturnsToThePinViewedJustBefore(kept: Bool) {
        world { browser in
            let x = page(browser, "x", pin: true)
            let reddit = page(browser, "reddit", pin: !kept, kept: kept)
            let home = page(browser, "home")
            browser.select(x)
            browser.select(reddit)
            browser.select(home)
            browser.shut([home], byKey: true)
            #expect(browser.active === reddit && !browser.fieldShowing)
            #expect(!browser.tabs.contains { $0 === home })
            #expect(!reddit.asleep && !x.asleep)
            // Both kinds of retained page follow the live picking order.
            // X put down then ends on the field; neither is woken again.
            browser.shut(browser.chosen, byKey: true)
            #expect(browser.active === x && reddit.asleep)
            browser.shut(browser.chosen, byKey: true)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect(x.asleep && reddit.asleep && browser.tabs.count == 2)
        }
    }

    @Test func thePinJustBeforeWinsOverTodaysNeighbor() {
        world { browser in
            let pin = page(browser, "pin", pin: true)
            let older = page(browser, "older")
            let closing = page(browser, "closing")
            browser.select(older)
            browser.select(pin)
            browser.select(closing)
            browser.close(closing)
            #expect(browser.active === pin && !older.asleep)
        }
    }

    // As Arc's ⌘W (evals/close-order/close_order.py): one of today's just
    // before is where closing goes, not the neighbor in the row.
    @Test func todaysJustBeforeWinsOverTheNeighbor() {
        world { browser in
            let pin = page(browser, "pin", pin: true)
            let first = page(browser, "first")
            _ = page(browser, "neighbor")
            let closing = page(browser, "closing")
            browser.select(pin)
            browser.select(first)
            browser.select(closing)
            browser.close(closing)
            #expect(browser.active === first)
        }
    }

    // One step back only: on the tab ⌘W just landed on, ⌘W again takes the
    // neighbor above, then below, as Arc does, not the page before that.
    @Test func closingAgainTakesTheNeighborNotFurtherBack() {
        world { browser in
            let a = page(browser, "a")
            let b = page(browser, "b")
            let c = page(browser, "c")
            let d = page(browser, "d")
            // The row, newest first: d c b a.
            browser.select(a)
            browser.select(d)
            browser.select(c)
            browser.close(c)
            #expect(browser.active === d)
            // The neighbor above d, or below when d heads the row; never a,
            // the page before.
            let row = browser.tabs
            let at = row.firstIndex { $0 === d }!
            let neighbor = at > 0 ? row[at - 1] : row[at + 1]
            browser.close(d)
            #expect(neighbor === b)
            #expect(browser.active === b)
        }
    }

    // A tab opened behind counts as one just left, as Arc's ⌘W and ⌃Tab
    // both have it.
    @Test func aTabOpenedBehindIsWhereClosingGoes() {
        world { browser in
            let before = page(browser, "before")
            let here = page(browser, "here")
            browser.select(before)
            browser.select(here)
            let behind = page(browser, "behind")
            browser.close(here)
            #expect(browser.active === behind)
        }
    }

    // An agent's own tabs stand under today's last one and are touched as
    // the agent works: closing never lands on one, today's or a pin alike.
    @Test(arguments: [false, true])
    func closingNeverLandsOnAnAgentsTab(pinned: Bool) {
        world { browser in
            let closing = page(browser, "closing", pin: pinned)
            let agent = browser.benchOpen(URL(string: "about:blank#agent")!)
            browser.select(closing)
            agent.touch(at: Date(timeIntervalSinceNow: 60))
            browser.close(closing)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect(browser.tabs.contains { $0 === agent })
        }
    }

    @Test func aPinPutDownSinceIsNotWokenForTodaysClose() {
        world { browser in
            let reddit = page(browser, "reddit", pin: true)
            let home = page(browser, "home")
            browser.select(reddit)
            browser.select(home)
            reddit.rest(closing: true)
            browser.close(home)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect(reddit.asleep)
        }
    }

    /// Pins in the order they were picked, no clock set by hand: ⌘W on the
    /// last goes back to the one picked before it, pin or today's.
    @Test(arguments: [false, true])
    func closingAPinFollowsThePickingOrder(todayLast: Bool) {
        world { browser in
            let today = page(browser, "today")
            let x = page(browser, "x", pin: true)
            let reddit = page(browser, "reddit", pin: true)
            if todayLast {
                browser.select(x)
                browser.select(today)
            } else {
                browser.select(today)
                browser.select(x)
            }
            browser.select(reddit)
            browser.shut([reddit], byKey: true)
            #expect(browser.active === (todayLast ? today : x) && !browser.fieldShowing)
            #expect(reddit.asleep)
        }
    }
}
