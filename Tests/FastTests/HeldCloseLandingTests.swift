import Foundation
import Testing
@testable import Fast

/// Closing a retained place unloads its page, then chooses among live pages
/// of this Space. It never wakes another retained place or a sleeping Today.
@MainActor
struct HeldCloseLandingTests {
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

    @Test(arguments: [false, true], [false, true])
    func pinAndKeptClosesShareTheLastLiveHeldPage(closingKept: Bool, previousKept: Bool) {
        world { browser in
            let previous = page(browser, "previous", pin: !previousKept, kept: previousKept)
            let today = page(browser, "older-today")
            let closing = page(browser, "closing", pin: !closingKept, kept: closingKept)
            browser.select(today)
            browser.select(previous)
            browser.select(closing)
            browser.shut([closing], byKey: true)
            #expect(browser.active === previous && !browser.fieldShowing)
            #expect(closing.asleep && (closing.pin != nil || closing.kept))
            #expect(browser.tabs.count == 3 && browser.ghosts.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func backgroundClosePreservesThePageAlreadyOnScreen(closingKept: Bool) {
        world { browser in
            let active = page(browser, "active", pin: true)
            let newer = page(browser, "newer", pin: true)
            let closing = page(browser, "background", pin: !closingKept, kept: closingKept)
            browser.select(newer)
            browser.select(active)
            browser.shut([closing])
            #expect(browser.active === active && !browser.fieldShowing)
            #expect(closing.asleep && !newer.asleep)
        }
    }

    @Test(arguments: [false, true])
    func noLiveAlternativeLeavesTheFieldWithoutWakingTodays(closingKept: Bool) {
        world { browser in
            let today = page(browser, "sleeping-today")
            let pin = page(browser, "sleeping-pin", pin: true)
            let kept = page(browser, "sleeping-kept", kept: true)
            let closing = page(browser, "closing", pin: !closingKept, kept: closingKept)
            for tab in [today, pin, kept] { tab.rest(closing: true) }
            browser.select(closing)
            browser.shut([closing], byKey: true)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect([today, pin, kept, closing].allSatisfy { $0.asleep })
            #expect(browser.tabs.count == 4 && browser.ghosts.isEmpty)
        }
    }

    @Test func repeatedKeptClosesWalkLivePagesAndStop() {
        world { browser in
            let pin = page(browser, "pin", pin: true)
            let first = page(browser, "first-kept", kept: true)
            let second = page(browser, "second-kept", kept: true)
            browser.select(pin)
            browser.select(first)
            browser.select(second)
            browser.shut([second], byKey: true)
            #expect(browser.active === first && second.asleep)
            browser.shut([first], byKey: true)
            #expect(browser.active === pin && first.asleep)
            browser.shut([pin], byKey: true)
            #expect(browser.activeID == nil && browser.fieldShowing)
            #expect([pin, first, second].allSatisfy { $0.asleep })
        }
    }
}
