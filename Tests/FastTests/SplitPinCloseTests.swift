import Foundation
import Testing
@testable import Fast

/// ⌘W on a pinned or kept tab in Split View (register #443): its page is
/// put down and the pin or the kept row stays, never taken away; the other
/// half has the window alone, as Arc's ⌘W on a pinned tab in a split.
@MainActor
struct SplitPinCloseTests {
    private func window() -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        return (browser, id)
    }

    private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private func settle(_ browser: Browser) async throws {
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(30))
            browser.settleNow()
        }
    }

    private let held = URL(string: "https://example.test/held")!
    private let page = URL(string: "https://example.test/page")!

    /// A pin or kept tab in a pair itself, as Arc's splits brought in make
    /// one (SpaceImport.adopt) and older sessions hold: ⌘W puts it down,
    /// out of the pair, and the other half has the width.
    private func heldInPair(_ browser: Browser, kept: Bool) -> (held: Tab, other: Tab) {
        let tab = browser.open(held, foreground: false)
        if kept { browser.keepTabs([tab]) } else { browser.pin(tab) }
        let other = browser.open(page, foreground: true)
        browser.pairs.append(Pair(first: tab.id, second: other.id, share: 0.5))
        browser.select(tab)
        return (tab, other)
    }

    @Test(arguments: [false, true])
    func cmdWOnAHeldHalfPutsItDown(kept: Bool) async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (tab, other) = heldInPair(browser, kept: kept)
        #expect(browser.pair(of: tab.id) != nil && browser.active === tab)
        browser.shut([tab], byKey: true)
        try await settle(browser)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(kept ? tab.kept : tab.pin != nil)
        #expect(tab.asleep)
        #expect(browser.pair(of: tab.id) == nil)
        #expect(browser.tabs.contains { $0 === other })
        #expect(browser.active === other && browser.stagePair == nil)
    }

    /// ⌘W on the half of today's leaves the pin or kept tab where it is.
    @Test(arguments: [false, true])
    func cmdWOnTheOtherHalfLeavesTheHeldOne(kept: Bool) async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (tab, other) = heldInPair(browser, kept: kept)
        browser.focus(other)
        browser.shut([other], byKey: true)
        try await settle(browser)
        #expect(browser.tabs.contains { $0 === tab } && (kept ? tab.kept : tab.pin != nil))
        #expect(!browser.tabs.contains { $0 === other })
        #expect(browser.pairs.isEmpty)
    }

    /// A pair kept whole, above the line (Arc's pinned split): ⌘W on a half
    /// puts both down, they stay a pair and kept, and you land off them.
    @Test func cmdWOnAKeptPairPutsBothDown() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let loose = browser.open(URL(string: "https://example.test/loose")!, foreground: false)
        let left = browser.open(held, foreground: true)
        let right = browser.open(page, foreground: false)
        browser.split(right, with: left)
        try await settle(browser)
        browser.keepTabs([left])
        #expect(left.kept && right.kept && browser.pair(of: left.id) != nil)
        browser.select(left)
        browser.focus(right)
        browser.shut([right], byKey: true)
        try await settle(browser)
        #expect(left.kept && right.kept)
        #expect(left.asleep && right.asleep)
        #expect(browser.pair(of: left.id)?.contains(right.id) == true)
        #expect(browser.active === loose && browser.stagePair == nil)
    }

    /// A pin or kept tab carried beside a page: ⌘W on its copy closes the
    /// copy, the pin or kept row stays, the page has the width.
    @Test(arguments: [false, true])
    func cmdWOnACopyKeepsTheHeldTab(kept: Bool) async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let tab = browser.open(held, foreground: false)
        if kept { browser.keepTabs([tab]) } else { browser.pin(tab) }
        let current = browser.open(page, foreground: true)
        browser.split(tab, with: current)
        let pair = try #require(browser.pair(of: current.id))
        let copy = try #require(browser.tab(id: pair.other(than: current.id)))
        #expect(copy !== tab)
        browser.focus(copy)
        browser.shut([copy], byKey: true)
        try await settle(browser)
        #expect(browser.tabs.contains { $0 === tab } && (kept ? tab.kept : tab.pin != nil))
        #expect(!browser.tabs.contains { $0 === copy })
        #expect(browser.active === current && browser.pairs.isEmpty)
    }
}
