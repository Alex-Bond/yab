import Foundation
import Testing
import WebKit
@testable import Fast

struct RecentTabSuggestionsTests {
    @MainActor private func page(_ address: String, title: String = "Home / X", seen: TimeInterval,
                                 store: WKWebsiteDataStore, bench: Bool = false) -> Tab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let tab = Tab(bench: bench, configuration: configuration)
        tab.restore(url: URL(string: address)!, title: title)
        tab.touch(at: Date(timeIntervalSince1970: seen))
        return tab
    }

    @MainActor private func recent(_ tabs: [Tab]) -> [Suggestion] {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            for tab in tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        browser.lay(tabs)
        return browser.quietRows().filter { $0.kind == .open }
    }

    @MainActor @Test func duplicatePagesKeepTheNewestTabAndLeaveRoomForThreeDestinations() {
        let store = WKWebsiteDataStore.nonPersistent()
        let oldest = page("https://x.com/home", seen: 1, store: store)
        let other = page("https://example.test/other", title: "Other", seen: 2, store: store)
        let apple = page("https://secure6.store.apple.com/shop/checkout/thankyou", title: "Apple", seen: 3, store: store)
        let older = page("https://x.com/home", title: "(1) Home / X", seen: 4, store: store)
        let newest = page("https://x.com/home", seen: 5, store: store)
        let tabs = [oldest, other, apple, older, newest]

        let rows = recent(tabs)
        #expect(rows.map(\.tab) == [newest.id, apple.id, other.id])
        #expect(rows.first?.key == "Home / X")
        #expect(rows.first?.url == newest.address)
    }

    @MainActor @Test(arguments: [
        "https://x.com/messages",
        "https://x.com/home?account=one",
        "https://x.com/home#following",
        "https://x.com:8443/home",
        "http://x.com/home",
        "https://www.x.com/home"
    ])
    func completeAddressesRemainSeparate(_ address: String) {
        let store = WKWebsiteDataStore.nonPersistent()
        let first = page("https://x.com/home", seen: 1, store: store)
        let second = page(address, seen: 2, store: store)
        #expect(recent([first, second]).map(\.tab) == [second.id, first.id])
    }

    @MainActor @Test func separateSignInsKeepTheirOwnRows() {
        let first = page("https://x.com/home", seen: 1, store: .nonPersistent())
        let second = page("https://x.com/home", seen: 2, store: .nonPersistent())
        #expect(recent([first, second]).map(\.tab) == [second.id, first.id])
    }

    @MainActor @Test func ineligibleDuplicateDoesNotHideTheUsersTab() {
        let store = WKWebsiteDataStore.nonPersistent()
        let mine = page("https://x.com/home", seen: 1, store: store)
        let agent = page("https://x.com/home", seen: 2, store: store, bench: true)
        #expect(recent([mine, agent]).map(\.tab) == [mine.id])
    }
}
