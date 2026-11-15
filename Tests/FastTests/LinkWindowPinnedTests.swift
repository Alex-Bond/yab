import AppKit
import Foundation
import Testing
@testable import Fast

/// Register 1012 (#615): a small window's field given a page that is
/// already open, a pinned one most of all, opens it in that small window.
/// It used to switch the main window to the pin and leave the small window
/// where it was; with no main window on screen, nothing seemed to happen.
/// The main window's own field still switches to the open tab.
@MainActor
@Suite(.serialized)
struct LinkWindowPinnedTests {
    @MainActor private final class World {
        let browser: Browser
        let pinnedURL = URL(string: "https://www.pinned1012.test/")!
        let openURL = URL(string: "https://open1012.test/page")!
        let pinned: Tab
        let other: Tab
        let current: Tab
        let guest: Tab
        let shell: NSWindow
        let previousSuggestions = Store.settings.object(forKey: "search.suggest")

        init() {
            _ = NSApplication.shared
            browser = Browser(windowID: UUID())
            browser.prefs.searchSuggest = false
            pinned = Tab(later: Store.websites)
            pinned.restore(url: pinnedURL, title: "Pinned")
            pinned.pin = "P"
            other = Tab(later: Store.websites)
            other.restore(url: openURL, title: "Open")
            current = Tab(later: Store.websites)
            current.restore(url: URL(string: "https://current1012.test/")!, title: "Current")
            for tab in [pinned, other, current] { browser.prepare(tab) }
            browser.lay([pinned, other, current])
            browser.activeID = current.id
            browser.history = History([])
            guest = Tab(later: Store.websites)
            guest.restore(url: URL(string: "https://guest1012.test/start")!, title: "Guest")
            browser.prepare(guest)
            browser.outside.append(guest)
            shell = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            shell.isReleasedWhenClosed = false
        }

        func close() {
            browser.letGo()
            shell.close()
            Store.settings.set(previousSuggestions, forKey: "search.suggest")
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            }
        }

        /// ⌘L in the small window, then the row for `tab` taken with Return.
        func takeInGuest(_ tab: Tab) {
            browser.edit(over: guest, in: shell)
            browser.replaceTyped(Address.pretty(tab.address!), completing: false)
            browser.query.offers = [Suggestion(key: tab.label, title: Tab.place(tab.address!), url: tab.address, kind: .open, tab: tab.id)]
            browser.picked = 0
            browser.submit()
        }
    }

    @Test func rule() {
        let id = UUID()
        let url = URL(string: "https://pinned1012.test/")!
        let open = Suggestion(key: "Pinned", title: "", url: url, kind: .open, tab: id)
        #expect(Browser.guestKeeps(open, making: nil) == url)
        #expect(Browser.guestKeeps(open, making: .tab) == nil, "⌘T's field keeps switching to the tab")
        #expect(Browser.guestKeeps(open, making: .split) == nil)
        #expect(Browser.guestKeeps(Suggestion(key: "Visited", title: "", url: url, kind: .visited), making: nil) == nil)
        #expect(Browser.guestKeeps(Suggestion(key: "Copy", title: "", url: url, kind: .command(.copyAddress), tab: id), making: nil) == nil)
        #expect(Browser.guestKeeps(Suggestion(key: "No address", title: "", url: nil, kind: .open, tab: id), making: nil) == nil)
    }

    /// The reporter's steps: a pin, a small window, the pin's address.
    @Test func pinnedRowOpensInSmallWindow() {
        let w = World(); defer { w.close() }
        w.takeInGuest(w.pinned)
        #expect(w.guest.address == w.pinnedURL, "The small window goes to the pinned site")
        #expect(w.browser.activeID == w.current.id, "The main window stays where it was")
        #expect(w.pinned.address == w.pinnedURL)
        #expect(w.browser.outside.contains { $0 === w.guest })
        #expect(!w.browser.editing)
    }

    @Test func openRowOpensInSmallWindow() {
        let w = World(); defer { w.close() }
        w.takeInGuest(w.other)
        #expect(w.guest.address == w.openURL)
        #expect(w.browser.activeID == w.current.id)
    }

    /// The reporter's exact address typed, no row picked by hand.
    @Test func typedPinnedAddressOpensInSmallWindow() {
        let w = World(); defer { w.close() }
        w.browser.edit(over: w.guest, in: w.shell)
        w.browser.replaceTyped(w.pinnedURL.absoluteString, completing: false)
        w.browser.submit()
        #expect(w.guest.address == w.pinnedURL)
        #expect(w.browser.activeID == w.current.id)
    }

    /// The small window's field shows where the row goes: Open, not Switch to Tab.
    @Test func smallWindowRowSaysOpen() {
        let w = World(); defer { w.close() }
        w.browser.edit(over: w.guest, in: w.shell)
        w.browser.replaceTyped(Address.pretty(w.pinnedURL), completing: false)
        w.browser.query.offers = [Suggestion(key: "Pinned", title: "", url: w.pinnedURL, kind: .open, tab: w.pinned.id)]
        w.browser.picked = 0
        #expect(w.browser.fieldActions.first?.title == "Open")
    }

    /// The main window: ⌘L on its own page, the pin's row switches to the pin.
    @Test func mainWindowStillSwitchesToPin() {
        let w = World(); defer { w.close() }
        w.browser.edit()
        w.browser.replaceTyped(Address.pretty(w.pinnedURL), completing: false)
        w.browser.query.offers = [Suggestion(key: "Pinned", title: "", url: w.pinnedURL, kind: .open, tab: w.pinned.id)]
        w.browser.picked = 0
        w.browser.submit()
        #expect(w.browser.activeID == w.pinned.id)
        #expect(w.current.address?.host() == "current1012.test")
        #expect(w.guest.address?.host() == "guest1012.test")
    }
}
