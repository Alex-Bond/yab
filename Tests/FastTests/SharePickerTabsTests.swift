import AppKit
import Foundation
import Testing
@testable import Fast

// The share box's Tab door: the tabs ⌃Tab walks, the rest found by typing.
@MainActor
struct SharePickerTabsTests {
    @Test func offersTheRecentTabsAndFindsTheRest() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let now = Date()
        let all = (0..<8).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://site\(index).test/")!, title: "Site \(index)")
            tab.touch(at: now.addingTimeInterval(TimeInterval(-index * 60)))
            browser.prepare(tab)
            return tab
        }
        browser.lay(all)
        browser.activeID = all[0].id

        let recent = browser.recentTabs().tabs
        #expect(recent.map(\.id) == all.prefix(Switcher.most).map(\.id))

        let picker = SharePicker(token: "token", frame: nil, host: "meet.google.com", audio: false)
        picker.fill(browser, caller: all[0])
        #expect(picker.items(.tabs).map(\.title) == ["Site 1", "Site 2", "Site 3", "Site 4"])

        picker.typed = "site 7"
        #expect(picker.items(.tabs).map(\.title) == ["Site 7"])
    }
}
