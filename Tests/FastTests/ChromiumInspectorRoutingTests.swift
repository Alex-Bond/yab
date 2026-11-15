import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumInspectorRoutingTests {
    @Test(arguments: [false, true])
    func anUnbuiltChromiumTabUsesItsNativeInspector(picker: Bool) throws {
        _ = NSApplication.shared
        let previousEngine = Store.settings.string(forKey: PageEngineSelection.key)
        Store.settings.set("chromium", forKey: PageEngineSelection.key)
        defer {
            if let previousEngine { Store.settings.set(previousEngine, forKey: PageEngineSelection.key) }
            else { Store.settings.removeObject(forKey: PageEngineSelection.key) }
        }
        let browser = Browser(windowID: UUID())
        var builds = 0
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in
            builds += 1
            return ChromiumPage(tab: tab)
        }
        let tab = Tab(shy: true, bench: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://inspector-routing.example/")!, title: "Sleeping Chromium tab")
        browser.lay([tab]); browser.activeID = tab.id
        defer {
            browser.closeDevTools()
            tab.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        #expect(tab.builtPage == nil)
        if picker { browser.inspectElement() } else { browser.openDevTools(.elements) }
        #expect(builds == 1)
        #expect(tab.builtPage?.engine == .chromium)
        #expect(tab.chromiumDev != nil)
        #expect(browser.inspected == nil) // No WebKit inspector was selected.
    }
}
