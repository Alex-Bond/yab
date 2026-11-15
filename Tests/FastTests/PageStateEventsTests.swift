import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PageStateEventsTests {
    private final class Listener: PageStateEvents {
        var states: [PageStateChange] = []
        func page(_ page: any PageHandle, changed state: PageStateChange) { states.append(state) }
    }

    @Test func webKitCopiesStateAndUnsubscribesWithoutChangingTheNavigationListener() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: config)
        let first = Listener(), second = Listener()
        defer { page.stateEvents = nil; page.stopLoading(); Tab.end(page) }
        page.stateEvents = first
        #expect(first.states == [.fullscreen(false)])
        page.navigate(html: "<title>State events</title><p>local page</p>", base: URL(string: "https://state.test/"))
        for _ in 0..<300 where !first.states.contains(.title("State events")) || page.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.states.contains(.title("State events")))
        #expect(first.states.contains(.loading(true)) && first.states.contains(.loading(false)))
        #expect(first.states.contains(.url(page.url)))
        #expect(first.states.contains(.theme(PageColor(page.themeColor))) || page.themeColor == nil)
        let count = first.states.count
        page.stateEvents = second
        _ = try await page.run("document.title = 'Second listener'; true")
        for _ in 0..<150 where !second.states.contains(.title("Second listener")) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(second.states.contains(.title("Second listener")))
        #expect(first.states.count == count)
        page.stateEvents = nil
        let stopped = second.states.count
        _ = try await page.run("document.title = 'After stop'; true")
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.states.count == stopped)
    }

    @Test func tabReceivesRealWebKitStateThroughItsIndependentStateListener() async throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let page = tab.page
        page.navigate(html: "<title>Tab state</title><p>local page</p>", base: URL(string: "https://state.test/"))
        for _ in 0..<300 where tab.title != "Tab state" || page.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.title == "Tab state" && tab.address == page.url && !tab.loading)
        #expect(tab.hasBackHistory == page.canGoBack && tab.canGoForward == page.canGoForward)
        #expect(page.stateEvents === tab)
        page.events = nil
        _ = try await page.run("document.title = 'Moved delegate'; true")
        for _ in 0..<150 where tab.title != "Moved delegate" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.title == "Moved delegate", "Changing the browser delegate does not detach state")
    }
}
