import AppKit
import Testing
import WebKit
@testable import Fast

/// Back and forward beside other tabs loading. WebKit keeps one
/// back-forward cache for the process pool every tab shares: other tabs'
/// pages going into it pushed this one's out, and its step, loading the
/// page again, hung after its response, the page before still showing
/// (Tab.stepPatience). LinkWindowHelmTests' ⌘[ and ⌘] waited 20 s for it
/// in whole-suite runs on m4 and renderer-2. With nothing done about it
/// this failed 5 rounds in 5 on m4 (farm a82eb4d7957642fb).
@MainActor
@Suite(.serialized)
struct HistoryStepTests {
    static func page(_ title: String) -> URLRequest {
        let html = "<!doctype html><title>\(title)</title><body>\(title)</body>"
        return URLRequest(url: URL(string: "data:text/html;charset=utf-8;base64," + Data(html.utf8).base64EncodedString())!)
    }

    /// What the page last said, for a step that never arrived.
    static var seen = ""

    static func settle(_ web: any PageHandle, on title: String, within seconds: TimeInterval) async -> TimeInterval {
        let start = Date()
        var now: Any?, asks = 0
        while Date().timeIntervalSince(start) < seconds {
            now = try? await web.run("document.title")
            asks += 1
            if now as? String == title, !web.isLoading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        seen = "the title \(String(describing: now)) after \(asks) asks, loading \(web.isLoading), "
            + "process \(web.contentProcess.map(String.init) ?? "none"), at \(web.url?.absoluteString.prefix(40) ?? "nil")"
        return Date().timeIntervalSince(start)
    }

    @Test func stepsBesideTabsLoadingArrive() async throws {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        // No extensions in these pages: beside a whole test run a page of
        // the shared extension controller that navigates just as another
        // suite unloads the last extension is ended by WebKit (its
        // WebExtensionController messages are [Validator=hasLoadedContexts]:
        // "Received an invalid message ... from WebContent process"), and
        // the step hangs the same without them.
        let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: browser.spaceID), extensions: false))
        browser.prepare(tab)
        browser.outside.append(tab)
        let page = tab.page
        let engine: PageEngineKind = ForcedEngine.chromium ? .chromium : .webKit
        #expect(page.engine == engine, "history steps must use the selected engine")
        // In a window, as a tab's page is, off every screen.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(page)
        window.orderFront(nil)
        // Other tabs' pages, in the same pool, each navigation putting the
        // page it leaves into the pool's cache.
        let others = (0..<12).map { _ in
            let other = Tab(configuration: Web.configuration(store: Spaces.store(for: browser.spaceID), extensions: false))
            browser.prepare(other)
            browser.outside.append(other)
            other.page.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
            #expect(other.page.engine == engine, "competing pages must use the same selected engine")
            return other
        }
        defer {
            for other in others { other.close() }
            page.removeFromSuperview()
            window.close()
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        // The two pages first, as long as they take: beside a whole test
        // run the first one was not in after 20 s, once after 58 (m4
        // 6316b6a06cbf4659, adhd 121a19c4499747d0). The steps are what is
        // timed.
        for title in ["First", "Second"] {
            page.navigate(to: Self.page(title))
            let took = await Self.settle(page, on: title, within: 120)
            try #require(took < 120, "\(title) never loaded: \(Self.seen)")
        }
        try #require(page.canGoBack)
        if let web = page.webKit {
            try #require(web.backForwardList.backItem != nil)
        } else {
            let history = try await (try #require(page as? ChromiumPage)).navigationHistory()
            try #require(!history.pages(back: true).isEmpty,
                         "a real native entry must exist before the timed steps")
        }
        for (index, other) in others.enumerated() { other.page.navigate(to: Self.page("other \(index) 0")) }
        try await Task.sleep(for: .milliseconds(300))

        var slow: [String] = []
        for step in 0..<12 {
            for (index, other) in others.enumerated() { other.page.navigate(to: Self.page("other \(index) \(step + 1)")) }
            let back = step % 2 == 0
            back ? tab.back() : tab.forward()
            // Hung, a step waited for good; asked again after a second (and
            // two, and four, if a try hangs too), it goes in a moment.
            let took = await Self.settle(page, on: back ? "First" : "Second", within: 10)
            if took >= 10 {
                slow.append("step \(step) \(back ? "back" : "forward"): \(String(format: "%.1f", took)) s, \(Self.seen)")
                break
            }
        }
        #expect(slow.isEmpty, "\(slow); asked again \(tab.stepsAgain) times; last turns \(tab.stepTrace)")
    }
}
