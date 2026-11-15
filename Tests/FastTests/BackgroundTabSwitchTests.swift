import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct BackgroundTabSwitchTests {
    @Test func experimentalRowUsesTheSameNativeSettingAsSettings() throws {
        let previous = Store.settings.object(forKey: SwitcherStrip.key)
        defer { Store.settings.set(previous, forKey: SwitcherStrip.key) }
        Store.settings.removeObject(forKey: SwitcherStrip.key)
        #expect(!SwitcherStrip.on)
        let item = try #require(SettingsItem.all.first { $0.id == "experimental-switcher-strip" })
        #expect(NativeActions.classification(item) == "read_write")
        let setting = try #require(NativeSetting.all.first { $0.id == item.id })
        let prefs = Preferences()
        #expect(setting.read(prefs) == .bool(false))
        try setting.write(prefs, .bool(true))
        #expect(SwitcherStrip.on && setting.read(prefs) == .bool(true))
        try setting.write(prefs, .bool(false))
        #expect(!SwitcherStrip.on && setting.read(prefs) == .bool(false))
        #expect(TaskWords.nativeRequest("turn on Ctrl-Tab row"))
        #expect(TaskWords.nativeRequest("turn off recent tabs over the page"))
    }

    @Test(arguments: [false, true]) func walksEveryBackgroundTabInBothDirections(strip: Bool) {
        let previous = Store.settings.object(forKey: SwitcherStrip.key)
        Store.settings.set(strip, forKey: SwitcherStrip.key)
        defer {
            if let previous { Store.settings.set(previous, forKey: SwitcherStrip.key) }
            else { Store.settings.removeObject(forKey: SwitcherStrip.key) }
        }
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tabs = (0..<13).map { index in
            let tab = Tab(shy: true, engine: .chromium, factory: factory)
            tab.restore(url: URL(string: "https://example.test/\(index)")!, title: "Tab \(index)")
            tab.touch(at: Date(timeIntervalSince1970: Double(100 - index)))
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        browser.activeID = tabs[0].id
        defer {
            browser.cancelSwitch()
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        for direction in [1, -1] {
            var reached = Set<Tab.ID>()
            for _ in tabs.indices {
                browser.switchStep(direction)
                let walk = browser.switcher
                if let picked = walk.picked { reached.insert(picked.id) }
                #expect(walk.visibleIndices.count <= Switcher.most)
                #expect(walk.visibleIndices.contains(walk.at))
            }
            #expect(reached == Set(tabs.map(\.id)))
            browser.cancelSwitch()
            #expect(browser.switcher.visibleIndices.isEmpty)
        }
        // The share picker still offers its short recent list.
        #expect(browser.recentTabs().tabs.count == Switcher.most)
        browser.switchStep(-1)
        #expect(browser.switcher.picked === tabs.last)
        browser.landSwitch()
        #expect(browser.activeID == tabs.last?.id)
    }
}
