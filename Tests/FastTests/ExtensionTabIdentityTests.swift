import Foundation
import Testing
import WebKit
@testable import Fast

/// A tab can appear in both the displayed row and a space's parked row
/// while spaces switch. Extension tab notifications must report one identity.
@MainActor
@Suite(.serialized)
struct ExtensionTabIdentityTests {
    @Test func aRepeatedTabSurvivesFollowingAndReordering() async throws {
        // Followed as a window of its own, not made the first one: other
        // suites set that while this one runs beside them.
        let id = UUID(), owner = Extensions.shared
        let browser = Browser(windowID: id)
        owner.follow(browser)
        defer {
            owner.unfollow(browser)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        let a = browser.open(URL(string: "data:text/html,%3Ctitle%3EA%3C/title%3E")!, foreground: true)
        let b = browser.open(URL(string: "data:text/html,%3Ctitle%3EB%3C/title%3E")!, foreground: false, atEnd: true)
        browser.lay([a, b])
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        try await Task.sleep(for: .milliseconds(200))
        // The same object can overlap the row and a space's parked row
        // during a switch. Keep the visible row stable through the debounce;
        // about:blank rows may be replaced by their asynchronous setup.
        let parked = UUID()
        browser.parked[parked] = Parked(tabs: [a], active: a.id)
        browser.lay([a, b])
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        #expect((browser.tabs + browser.parkedTabs).map(\.id) == [a.id, b.id, a.id])
        try await Task.sleep(for: .milliseconds(200))
        #expect(browser.tabs.map(\.id) == [a.id, b.id])
        #expect((browser.tabs + browser.parkedTabs).map(\.id) == [a.id, b.id, a.id])
        #expect(owner.visibleTabs(in: browser).map(\.id) == [a.id, b.id])
        browser.lay([b, a])
        #expect(browser.tabs.map(\.id) == [b.id, a.id])
        try await Task.sleep(for: .milliseconds(200))
        #expect((browser.tabs + browser.parkedTabs).map(\.id) == [b.id, a.id, a.id])
        #expect(owner.visibleTabs(in: browser).map(\.id) == [b.id, a.id])
        // The getter also tolerates overlap in a row before any asynchronous
        // page setup can change it.
        browser.lay([b, a, b, a])
        #expect(browser.tabs.map(\.id) == [b.id, a.id, b.id, a.id])
        #expect(owner.visibleTabs(in: browser).map(\.id) == [b.id, a.id])
        browser.parked.removeValue(forKey: parked)
        browser.lay([b])
        #expect(browser.tabs.map(\.id) == [b.id])
        try await Task.sleep(for: .milliseconds(200))
        #expect(owner.visibleTabs(in: browser).map(\.id) == [b.id])
    }
}
