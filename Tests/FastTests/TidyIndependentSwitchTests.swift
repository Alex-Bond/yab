import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct TidyIndependentSwitchTests {
    @Test func carriedProfileKeepsTidyWithOtherAIOff() throws {
        let keys = ["ai.use", "models.mac.disabled", "tidy.tabs"]
        let old = keys.map { Store.settings.object(forKey: $0) }
        let stand = TidyTabs.benchAnswer
        defer {
            for (key, value) in zip(keys, old) { Store.settings.set(value, forKey: key) }
            TidyTabs.benchAnswer = stand
        }
        // A carried profile: no new Tidy preference means the existing default stays on.
        Store.settings.removeObject(forKey: "tidy.tabs")
        Store.settings.set(true, forKey: "models.mac.disabled")
        TidyTabs.benchAnswer = "{}"
        for level in ["off", "asked", "on"] {
            Store.settings.set(level, forKey: "ai.use")
            let window = UUID(), browser = Browser(windowID: window)
            let tabs = (0..<10).map { i in
                let tab = Tab()
                tab.restore(url: URL(string: "https://tidy-switch.test/\(i)")!, title: "Tab \(i)")
                browser.prepare(tab)
                return tab
            }
            defer {
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                tabs.forEach { $0.close() }; browser.lay([])
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
            }
            browser.lay(tabs)
            #expect(browser.tidyTabsLoose.count == 10)
            #expect(browser.canTidyTabs, "Tidy stays offered with AI \(level), with a model available")
            browser.prefs.tidyTabs = false
            #expect(!browser.canTidyTabs)
            browser.prefs.tidyTabs = true
            #expect(browser.canTidyTabs)
        }
    }
}
