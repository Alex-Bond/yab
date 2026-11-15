import Foundation
import Testing
@testable import Fast

@MainActor
struct TabTransferTests {
    private func tab(_ name: String, in browser: Browser) -> Tab {
        let tab = Tab()
        tab.restore(url: URL(string: "https://transfer.test/\(name)")!, title: name)
        browser.prepare(tab)
        return tab
    }

    private func world(_ body: (Browser) -> Void) {
        let id = UUID()
        let browser = Browser(windowID: id)
        defer {
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        body(browser)
    }

    @Test func movingLastPageLeavesBookmarksAsleep() {
        world { browser in
            let pin = tab("pin", in: browser)
            pin.pin = "P"
            let kept = tab("kept", in: browser)
            kept.kept = true
            let moved = tab("moved", in: browser)
            browser.lay([pin, kept, moved])
            browser.activeID = moved.id
            browser.typed = "old search"
            let focus = browser.query.focusRequest

            browser.moveOut(moved)

            #expect(browser.tabs.map(\.id) == [pin.id, kept.id])
            #expect(pin.asleep && kept.asleep)
            #expect(browser.active == nil && browser.chosen.isEmpty)
            #expect(browser.fieldShowing && browser.fresh)
            #expect(browser.typed.isEmpty && browser.query.focusRequest > focus)
        }
    }

    @Test func movingPageSelectsAnotherTodayTabBeforeBookmarks() {
        world { browser in
            let ordinary = tab("ordinary", in: browser)
            let moved = tab("moved", in: browser)
            let kept = tab("kept", in: browser)
            kept.kept = true
            browser.lay([ordinary, moved, kept])
            browser.activeID = moved.id

            browser.moveOut(moved)

            #expect(browser.active === ordinary)
            #expect(kept.asleep)
        }
    }

    @Test func movingInactivePageKeepsTheCurrentBookmark() {
        world { browser in
            let kept = tab("kept", in: browser)
            kept.kept = true
            let moved = tab("moved", in: browser)
            browser.lay([kept, moved])
            browser.activeID = kept.id
            let focus = browser.query.focusRequest

            browser.moveOut(moved)

            #expect(browser.active === kept)
            #expect(browser.query.focusRequest == focus)
        }
    }

    @Test func sharedPageStandInIsNotSelectedAfterTransfer() {
        world { browser in
            let kept = tab("kept", in: browser)
            kept.kept = true
            let moved = tab("moved", in: browser)
            moved.kept = true
            let standIn = tab("moved", in: browser)
            standIn.kept = true
            browser.lay([kept, moved])
            browser.activeID = moved.id

            browser.moveOut(moved, leaving: standIn)

            #expect(browser.tabs.map(\.id) == [kept.id, standIn.id])
            #expect(browser.active == nil && browser.fieldShowing)
            #expect(kept.asleep && standIn.asleep)
        }
    }
}
