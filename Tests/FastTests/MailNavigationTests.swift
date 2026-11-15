import AppKit
import Testing
@testable import Fast
@testable import MailCore

@MainActor
@Suite(.serialized)
struct MailNavigationTests {
    private func fixture(enabled: Bool, _ body: (Browser) throws -> Void) rethrows {
        let keys = ["mail", MailExperiment.key, "sidebar", "mail.pin.asked"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        Store.settings.set(enabled, forKey: "mail")
        Store.settings.set(enabled, forKey: MailExperiment.key)
        Store.settings.set(false, forKey: "mail.pin.asked")
        let id = UUID(), browser = Browser(windowID: id)
        let back = MailSpaceState.shared.back
        let turned = MailSpaceState.shared.turnedSidebar
        defer {
            if browser.inMail { browser.leaveMail() }
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            browser.writeSession(now: true)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            MailSpaceState.shared.back = back
            MailSpaceState.shared.turnedSidebar = turned
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
        }
        try body(browser)
    }

    private func page(_ browser: Browser, url: URL, active: Bool = true) -> Tab {
        let tab = Tab()
        browser.prepare(tab)
        tab.restore(url: url, title: "Page")
        browser.lay(browser.tabs + [tab])
        if active { browser.activeID = tab.id }
        return tab
    }

    @Test(arguments: [false, true])
    func cancelledMailTabDoesNotReturnToTheSidebar(_ enabled: Bool) {
        fixture(enabled: enabled) { browser in
            let tab = page(browser, url: MailPage.url)
            // The state seen by the policy callback after Tab.go: already
            // addressed to Mail, so the old isBlank check missed it.
            #expect(!tab.isBlank)
            browser.routeMailNavigation(MailPage.url, from: tab)
            #expect(browser.inMail == enabled)
            if enabled {
                #expect(browser.mailPageTab != nil)
                browser.leaveMail()
            }
            #expect(browser.tabs.isEmpty)
            #expect(browser.underTab !== tab)
            #expect(browser.ghosts.allSatisfy { !MailPage.isMail($0.url) })
            browser.dismiss()
            // Escape may return to Mail's own space from an empty browser
            // space. It must never restore the cancelled tab in the sidebar.
            #expect(!browser.tabs.contains { $0 === tab })
            #expect(browser.inMail || browser.tabs.isEmpty)
        }
    }

    @Test func backgroundMailOpenIsRemovedWithoutChangingTheActivePage() {
        fixture(enabled: true) { browser in
            let site = page(browser, url: URL(string: "https://example.test/")!)
            let mail = page(browser, url: MailPage.url, active: false)
            browser.routeMailNavigation(MailPage.url, from: mail)
            #expect(!browser.inMail)
            #expect(browser.tabs.map(\.id) == [site.id])
            #expect(browser.active === site)
            #expect(browser.ghosts.isEmpty)
        }
    }

    @Test func deliberateMailPinRemainsADoor() {
        fixture(enabled: true) { browser in
            let site = page(browser, url: URL(string: "https://example.test/")!)
            let mail = page(browser, url: MailPage.url, active: false)
            mail.pin = "M"
            browser.routeMailNavigation(MailPage.url, from: mail)
            #expect(browser.tabs.contains { $0 === mail })
            #expect(browser.active === site)
            #expect(!browser.inMail)
        }
    }

    @Test(arguments: [false, true], [Browser.Way.here, .ahead, .behind])
    func fieldRoutesMailWithoutReplacingTheCurrentPage(_ enabled: Bool, _ way: Browser.Way) {
        fixture(enabled: enabled) { browser in
            let url = URL(string: "https://example.test/")!
            let site = page(browser, url: url)
            browser.send(MailPage.url, way)
            #expect(browser.inMail == (enabled && way != .behind))
            if browser.inMail { browser.leaveMail() }
            #expect(browser.tabs.map(\.id) == [site.id])
            #expect(site.address == url)
        }
    }

    @Test(arguments: [false, true])
    func oldSessionRestoresOnlyExplicitMailPins(_ enabled: Bool) throws {
        try fixture(enabled: enabled) { browser in
            let id = try #require(browser.windowID)
            Session.write(now: true, window: id, .init(tabs: [
                .init(url: MailPage.url.absoluteString, title: "Mail"),
                .init(url: "https://example.test/", title: "Site"),
                .init(url: MailPage.url.absoluteString, title: "Mail", pin: "M")
            ], active: 1))
            let row = browser.loadRow(Space.firstID)
            defer { for tab in row.tabs { tab.close() } }
            #expect(row.tabs.count == (enabled ? 2 : 1))
            #expect(row.tabs.filter { MailPage.isMail($0.address) }.allSatisfy { $0.pin != nil })
            #expect(row.tabs.first { $0.id == row.active }?.address?.host == "example.test")
        }
    }
}
