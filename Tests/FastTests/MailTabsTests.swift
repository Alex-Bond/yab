import AppKit
import Testing
@testable import Fast
@testable import MailCore

/// Pages opened from mail stay in mail's space as tabs of its own, listed in
/// its column (MailTabRows), and mail is one click away from any of them.
@MainActor
@Suite(.serialized)
struct MailTabsTests {
    private func fixture(_ body: (Browser) throws -> Void) rethrows {
        let keys = ["mail", MailExperiment.key, "sidebar", "mail.pin.asked"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        Store.settings.set(true, forKey: "mail")
        Store.settings.set(true, forKey: MailExperiment.key)
        Store.settings.set(false, forKey: "mail.pin.asked")
        let id = UUID(), browser = Browser(windowID: id)
        let back = MailSpaceState.shared.back
        let turned = MailSpaceState.shared.turnedSidebar
        defer {
            if browser.inMail { browser.leaveMail() }
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            for suffix in ["", "-\(Space.mailID.uuidString)"] {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString)\(suffix).json"))
            }
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            MailSpaceState.shared.back = back
            MailSpaceState.shared.turnedSidebar = turned
            MailList.shared.paging = false
            for (key, value) in zip(keys, saved) { Store.settings.set(value, forKey: key) }
        }
        try body(browser)
    }

    /// A page kept from a peek over mail: takeIn, as keepPeek does.
    private func keep(_ browser: Browser, _ url: String) -> Tab {
        let tab = Tab()
        browser.prepare(tab)
        tab.restore(url: URL(string: url)!, title: "Page")
        browser.takeIn(tab)
        return tab
    }

    @Test func keptPageIsATabOfMailListedUnderItsLists() throws {
        try fixture { browser in
            browser.enterMail()
            let mail = try #require(browser.mailPageTab)
            #expect(browser.tabs.first === mail)
            #expect(!MailList.shared.paging)
            let page = keep(browser, "https://aws.example.test/terms")
            #expect(browser.inMail)
            #expect(browser.active === page)
            #expect(browser.mailTabs.map(\.id) == [page.id])
            #expect(MailList.shared.paging)
            // The tab right after mail's page: the newest first under the lists.
            #expect(browser.tabs.firstIndex { $0 === page } == 1)
        }
    }

    @Test func listChosenBringsMailBackAndKeepsTheTab() throws {
        try fixture { browser in
            browser.enterMail()
            let mail = try #require(browser.mailPageTab)
            let page = keep(browser, "https://aws.example.test/terms")
            browser.showMailPage()
            #expect(browser.active === mail)
            #expect(!MailList.shared.paging)
            #expect(browser.mailTabs.contains { $0 === page })
        }
    }

    @Test func closingATabOfMailLandsOnMailNotTheNextTab() throws {
        try fixture { browser in
            browser.enterMail()
            let mail = try #require(browser.mailPageTab)
            let other = keep(browser, "https://billing.example.test/")
            browser.showMailPage()
            let page = keep(browser, "https://aws.example.test/terms")
            #expect(browser.active === page)
            browser.shut(page)
            #expect(browser.active === mail)
            #expect(browser.mailTabs.map(\.id) == [other.id])
        }
    }

    @Test func mailPageIsNeverClosedByHandInItsSpace() throws {
        try fixture { browser in
            browser.enterMail()
            let mail = try #require(browser.mailPageTab)
            browser.shut(mail)
            #expect(browser.tabs.contains { $0 === mail })
            #expect(browser.active === mail)
        }
    }

    @Test func mailTabsAreWrittenAndComeBack() throws {
        try fixture { browser in
            browser.enterMail()
            _ = keep(browser, "https://aws.example.test/terms")
            browser.writeSession(now: true)
            let row = browser.loadRow(Space.mailID)
            defer { for tab in row.tabs { tab.close() } }
            #expect(row.tabs.map { $0.pending?.host } == ["aws.example.test"])
        }
    }

    /// An agent's tab of mail's space (docs/mail.md, The mail space): never a loose
    /// row, and over the email as a live peek that, put away, leaves the tab
    /// working where it was.
    @Test func agentsTabPeeksLiveAndStays() throws {
        try fixture { browser in
            browser.enterMail()
            let mail = try #require(browser.mailPageTab)
            let page = keep(browser, "https://cal.example.test/anna")
            page.agent = "mail-town-test"
            browser.select(mail)
            #expect(!browser.mailTabs.contains { $0 === page })
            // Up live: in sight, as the tab in front is.
            browser.peeking = page
            browser.peekFrom = mail.id
            #expect(browser.isLive(page))
            #expect(browser.onScreen(page.id))
            browser.closePeek()
            #expect(browser.peeking == nil)
            #expect(!page.gone)
            #expect(browser.tabs.contains { $0 === page })
            #expect(!browser.onScreen(page.id))
            // Nowhere to show a peek: a click is the tab itself.
            browser.tapTab(page)
            #expect(browser.active === page)
            #expect(MailChat.lookedAt(in: browser))
        }
    }
}
