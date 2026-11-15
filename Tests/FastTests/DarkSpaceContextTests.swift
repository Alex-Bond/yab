import AppKit
import Testing
@testable import Fast

/// #1606: arming a tab uses its own space, including when another window
/// has most recently changed the global default for new spaces.
@MainActor @Suite(.serialized)
struct DarkSpaceContextTests {
    @Test func anotherWindowsLightLookDoesNotDisableADarkSpacesPages() throws {
        let browser = Browser(windowID: UUID())
        let other = Browser(windowID: UUID())
        let appearance = NSApp.appearance
        let mode = Store.settings.object(forKey: DarkMode.key)
        let look = Store.settings.object(forKey: "backdrop.mode")
        let tab = Tab()
        defer {
            tab.close()
            for owner in [browser, other] {
                owner.dropSpare(); owner.dozing?.invalidate(); owner.stuck.timer?.invalidate(); owner.pressure?.cancel()
            }
            NSApp.appearance = appearance
            Store.settings.set(mode, forKey: DarkMode.key)
            Store.settings.set(look, forKey: "backdrop.mode")
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        Store.settings.set(DarkMode.withTheme.rawValue, forKey: DarkMode.key)
        tab.restore(url: URL(string: "https://dark-space.invalid/")!, title: "Light fixture")
        browser.prepare(tab)
        browser.prefs.lookMode = LookMode.dark.rawValue
        other.prefs.lookMode = LookMode.light.rawValue
        try #require(!tab.bench && tab.builtPage == nil)
        #expect(DarkPages.decision(for: tab, url: tab.address, host: nil) == .check)

        // Park the same tab in a dark space while the window wears Light.
        var paint = SpacePaint(browser.prefs)
        paint.mode = LookMode.dark.rawValue
        let space = Space(id: UUID(), name: "Dark", icon: "moon", ownSignIns: false, paint: paint)
        browser.spaces.append(space)
        browser.parked[space.id] = Parked(tabs: [tab], active: tab.id)
        browser.prefs.lookMode = LookMode.light.rawValue
        #expect(DarkPages.decision(for: tab, url: tab.address, host: nil) == .check)

        // A light space does not inherit a different window's dark look.
        paint.mode = LookMode.light.rawValue
        browser.spaces[browser.spaces.count - 1].paint = paint
        other.prefs.lookMode = LookMode.dark.rawValue
        #expect(DarkPages.decision(for: tab, url: tab.address, host: nil) == .none)
    }
}
