import AppKit
import Foundation
import Testing
@testable import Fast

/// ⌥↩ and ⌥-click in ⌘T's and ⌘L's field put the place in Split View
/// beside the page in front, as Arc's command bar does (feedback #323).
@MainActor
@Suite(.serialized)
struct FieldSplitTests {
    private func window(width: CGFloat = 1400) -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: width, height: 900)
        return (browser, id)
    }

    private func forget(_ browser: Browser, _ id: UUID) {
        for tab in browser.tabs + browser.parkedTabs { tab.close() }
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
    }

    private func url(_ path: String) -> URL { URL(string: "https://example.test/\(path)")! }

    /// ⌥ alone is Split View; ⌘ still decides with it held.
    @Test func optionAsksForSplit() {
        #expect(Browser.way(for: [.option]) == .split)
        #expect(Browser.way(for: []) == .here)
        #expect(Browser.way(for: [.command]) == .behind)
        #expect(Browser.way(for: [.command, .shift]) == .ahead)
    }

    @Test func optionReturnOpensBesideThePage() async throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let page = browser.open(url("page"), foreground: true)
        browser.newTab()
        browser.typed = "https://example.test/beside"
        browser.submitAlternate()
        for _ in 0..<100 where browser.pair(of: page.id) == nil { try await Task.sleep(for: .milliseconds(50)) }
        let pair = try #require(browser.pair(of: page.id))
        let beside = try #require(browser.tab(id: pair.other(than: page.id)))
        #expect(beside.address == url("beside"))
        #expect(pair.first == page.id)
        #expect(browser.tabs.count == 2 && !browser.fieldShowing)
    }

    /// In a pair already, the other half gives way and stays a tab.
    @Test func optionReturnInAPairReplacesTheOtherHalf() async throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let page = browser.open(url("page"), foreground: true)
        let old = browser.open(url("old"), foreground: false)
        browser.split(old, with: page)
        browser.settleNow()
        #expect(browser.pair(of: page.id) != nil)
        browser.select(page)
        browser.newTab()
        browser.typed = "https://example.test/new"
        browser.submitAlternate()
        for _ in 0..<100 where browser.pair(of: page.id)?.contains(old.id) == true { try await Task.sleep(for: .milliseconds(50)) }
        let pair = try #require(browser.pair(of: page.id))
        #expect(browser.tab(id: pair.other(than: page.id))?.address == url("new"))
        #expect(browser.pairs.count == 1)
        #expect(browser.tabs.contains { $0 === old } && browser.pair(of: old.id) == nil)
    }

    /// An open tab's row, ⌥-clicked: that tab goes beside, no copy made.
    @Test func optionOnAnOpenTabPutsItBeside() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        let other = browser.open(url("other"), foreground: true)
        let page = browser.open(url("page"), foreground: true)
        browser.newTab()
        browser.take(Suggestion(key: other.label, title: "", url: other.address, kind: .open, tab: other.id), .split)
        #expect(browser.pair(of: page.id)?.contains(other.id) == true)
        #expect(browser.tabs.count == 2 && !browser.fieldShowing)
    }

    /// No room for a pair: a tab of its own in front, as Return would.
    @Test func tooNarrowOpensATab() async throws {
        let (browser, id) = window(width: 300)
        defer { forget(browser, id) }
        let page = browser.open(url("page"), foreground: true)
        browser.newTab()
        browser.typed = "https://example.test/narrow"
        browser.submitAlternate()
        for _ in 0..<100 where browser.tabs.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(browser.pairs.isEmpty)
        #expect(browser.tabs.count == 2 && browser.active !== page)
        #expect(browser.active?.address == url("narrow"))
    }

    /// ⌘K's list says so, with ⌥↩ beside it.
    @Test func actionsListSplitView() throws {
        let (browser, id) = window()
        defer { forget(browser, id) }
        _ = browser.open(url("page"), foreground: true)
        #expect(browser.splitsBeside)
        let (narrow, other) = window(width: 300)
        defer { forget(narrow, other) }
        _ = narrow.open(url("page"), foreground: true)
        #expect(!narrow.splitsBeside)
    }
}
