import Foundation
import Testing
@testable import Fast

/// A site sending one download in parts, each started by the page seconds
/// after the click (Google Drive's "zip 1 of 4", #1940): one card for all of
/// them, asked once, never a card per part.
@MainActor
@Suite(.serialized)
struct DownloadPartsAskTests {
    private func fixture(_ check: (Browser, Tab, String) throws -> Void) rethrows {
        let browser = Browser(windowID: UUID())
        let tab = Tab()
        // A site of its own per test: the answers are kept by site.
        let host = "parts-\(UUID().uuidString.prefix(8).lowercased()).example"
        tab.restore(url: URL(string: "https://\(host)/folder")!, title: "Drive")
        browser.outside.append(tab)
        defer {
            browser.dropAsks(tab)
            SiteDownloads.forgetMany(host)
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        try check(browser, tab, host)
    }

    @Test func partsThatComeWhileTheCardIsUpWaitOnItAndOneAllowLetsThemAllIn() {
        fixture { browser, tab, host in
            var said: [Bool] = []
            browser.askDownloads(host, name: "drive-download-001.zip", many: false, on: tab) { said.append($0) }
            #expect(tab.asks.map(\.kind) == [.download])
            browser.askDownloads(host, name: "drive-download-002.zip", many: true, on: tab) { said.append($0) }
            browser.askDownloads(host, name: "drive-download-003.zip", many: true, on: tab) { said.append($0) }
            // Still one card, now the "multiple files" one.
            #expect(tab.asks.map(\.kind) == [.downloads])
            #expect(said.isEmpty)
            browser.answer(tab, .yes(nil))
            #expect(said == [true, true, true])
            #expect(tab.asks.isEmpty && browser.manyAsking.isEmpty)
            // The parts still to come go without asking: the site's
            // automatic downloads are allowed (Site Controls lists it).
            #expect(SiteDownloads.many(for: host) == true)
        }
    }

    @Test func aLoneUnaskedFileKeepsItsOwnCardAndDontAllowRefusesWhatWaits() {
        fixture { browser, tab, host in
            var said: [Bool] = []
            browser.askDownloads(host, name: "report.pdf", many: false, on: tab) { said.append($0) }
            #expect(tab.asks.map(\.kind) == [.download])
            browser.answer(tab, .no)
            #expect(said == [false])
            #expect(SiteDownloads.answer(for: host) == false)
            // One file is not the site's automatic downloads.
            #expect(SiteDownloads.many(for: host) == nil)
        }
    }

    @Test func dontAllowOnThePartsCardRefusesThemAllAndBlocksOnlyTheSitesAutomaticDownloads() {
        fixture { browser, tab, host in
            var said: [Bool] = []
            browser.askDownloads(host, name: "drive-download-001.zip", many: false, on: tab) { said.append($0) }
            browser.askDownloads(host, name: "drive-download-002.zip", many: true, on: tab) { said.append($0) }
            browser.answer(tab, .no)
            #expect(said == [false, false])
            #expect(SiteDownloads.many(for: host) == false)
            // Blocked: a later page's one file is still asked about.
            #expect(SiteDownloads.answer(for: host) == nil)
        }
    }

    @Test func aCardTakenAwayByLeavingRefusesEveryWaitingPartAndKeepsNothing() {
        fixture { browser, tab, host in
            var said: [Bool] = []
            browser.askDownloads(host, name: "a.zip", many: true, on: tab) { said.append($0) }
            browser.askDownloads(host, name: "b.zip", many: true, on: tab) { said.append($0) }
            browser.asksMoved(tab, to: URL(string: "https://elsewhere.example.net/")!, committed: true)
            #expect(said == [false, false])
            #expect(SiteDownloads.many(for: host) == nil)
            // The next file asks again.
            browser.askDownloads(host, name: "c.zip", many: true, on: tab) { said.append($0) }
            #expect(tab.asks.map(\.kind) == [.downloads])
        }
    }
}
