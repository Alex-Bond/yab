import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct PinnedFieldNavigationTests {
    private func world(_ body: (Browser, Tab) -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        let pin = Tab()
        browser.prepare(pin)
        pin.restore(url: URL(string: "https://mail.google.com/mail/u/0/#inbox")!, title: "Gmail")
        browser.lay([pin])
        browser.activeID = pin.id
        browser.pin(pin)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        body(browser, pin)
    }

    private let destination = URL(string: "https://field-destination.test/new")!

    @Test func typedAddressLeavesThePinAtHome() {
        world { browser, pin in
            let home = pin.address, pending = pin.pending
            browser.edit()
            browser.send(destination, .here)
            #expect(browser.tabs.count == 2)
            #expect(browser.active !== pin)
            #expect(browser.active?.pending == destination || browser.active?.address == destination)
            #expect(browser.active?.pin == nil)
            #expect(pin.address == home && pin.pending == pending && pin.home == home)
            #expect(pin.title == "Gmail")
        }
    }

    @Test func historyAndSearchRowsLeaveThePinAtHome() {
        for kind in [Suggestion.Kind.visited, .search] {
            world { browser, pin in
                let home = pin.address, pending = pin.pending
                browser.edit()
                browser.take(Suggestion(key: "destination", title: "Destination", url: destination, kind: kind))
                #expect(browser.tabs.count == 2 && browser.active !== pin)
                #expect(pin.address == home && pin.pending == pending && pin.home == home)
            }
        }
    }

    @Test func unchangedAddressDoesNotOpenATab() {
        world { browser, pin in
            let pending = pin.pending
            browser.edit()
            browser.submit()
            #expect(browser.tabs.count == 1 && browser.active === pin)
            #expect(pin.pending == pending)
        }
    }

    @Test func ordinaryTabStillNavigatesInPlace() {
        world { browser, pin in
            browser.unpin(pin)
            browser.edit()
            browser.send(destination, .here)
            #expect(browser.tabs.count == 1 && browser.active === pin)
            #expect(pin.pending == destination || pin.address == destination)
        }
    }

    @Test func commandReturnOpensBehindWithoutSelectingIt() {
        world { browser, pin in
            let home = pin.address, pending = pin.pending
            browser.edit()
            browser.send(destination, .behind)
            #expect(browser.tabs.count == 2 && browser.active === pin)
            #expect(pin.address == home && pin.pending == pending)
        }
    }
}
