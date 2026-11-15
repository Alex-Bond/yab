import AppKit
import Testing
@testable import Fast

/// Request #615: an interactive card beside the floating sidebar belongs
/// to it until the card closes; passive tab previews still follow hover.
@MainActor @Suite(.serialized)
struct BrimInteractiveCardTests {
    private func world(_ body: (Browser, NSWindow, Tab) throws -> Void) rethrows {
        let windowID = UUID(), browser = Browser(windowID: windowID)
        let tab = Tab()
        tab.restore(url: URL(string: "https://sidebar-card.test/")!, title: "Card")
        browser.prepare(tab)
        browser.lay([tab])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        Brim.keep(window, for: browser)
        defer {
            browser.glance.drop()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
        try body(browser, window, tab)
    }

    @Test func anActionableTabCardHoldsTheSidebarUntilDismissed() {
        world { browser, window, tab in
            browser.glance.pretend(tab.id, true)
            browser.glance.hold(true)
            #expect(browser.glance.shown == tab.id && browser.glance.taking)
            #expect(Brim.benchColumnHeld(in: window, browser) == "card")
            browser.glance.drop()
            #expect(Brim.benchColumnHeld(in: window, browser).isEmpty)
        }
    }

    @Test func aClosedFoldersContentsHoldTheSidebar() {
        world { browser, window, tab in
            let folder = Nest(name: "Trips", open: false)
            tab.kept = true
            tab.nest = folder
            browser.takeOwnFolders()
            browser.folderBook.refresh()
            browser.glance.pretendFolder(folder.key, true)
            #expect(browser.glance.shownFolder == folder.key && browser.glance.searching)
            #expect(Brim.benchColumnHeld(in: window, browser) == "card")
            browser.glance.drop()
            #expect(Brim.benchColumnHeld(in: window, browser).isEmpty)
        }
    }

    @Test func aPassiveTabCardDoesNotHoldTheSidebar() {
        world { browser, window, tab in
            browser.glance.pretend(tab.id, true)
            #expect(browser.glance.shown == tab.id && !browser.glance.taking)
            #expect(Brim.benchColumnHeld(in: window, browser).isEmpty)
        }
    }

    @Test func anObsoleteHoldWithoutADisplayedCardDoesNotHoldTheSidebar() {
        world { browser, window, _ in
            browser.glance.hold(true)
            #expect(browser.glance.taking && browser.glance.shown == nil && browser.glance.shownFolder == nil)
            #expect(Brim.benchColumnHeld(in: window, browser).isEmpty)
        }
    }

    @Test func aMenuHoldsTheSidebarUntilTrackingEnds() {
        world { browser, window, _ in
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
            #expect(Brim.benchColumnHeld(in: window, browser) == "menu")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil)
            #expect(Brim.benchColumnHeld(in: window, browser).isEmpty)
        }
    }
}
