import Foundation
import Testing
@testable import Fast

/// Split View with the pins, as Arc has it: a pin makes a pair with a copy
/// of its page and stays in the grid (#258), pinning a half of a pair leaves
/// the pair on screen (#246), and ⌃⌘\ where no pair can be had says why
/// (#245b).
@MainActor
struct SplitPinTests {
    private func window(width: CGFloat = 1400) -> (Browser, UUID) {
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.splitBook.place = CGRect(x: 0, y: 0, width: width, height: 900)
        return (browser, id)
    }

    private func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
    }

    private let docs = URL(string: "https://example.test/docs")!
    private let page = URL(string: "https://example.test/page")!

    /// Split with Current Tab on a pin: the pin stays a square, a copy of its
    /// page is the half.
    @Test func aPinSplitsAsACopyAndStaysPinned() throws {
        let (browser, id) = window()
        defer { forget(id) }
        let pin = browser.open(docs, foreground: false)
        browser.pin(pin)
        let current = browser.open(page, foreground: true)
        #expect(!browser.canPair(pin, current))
        #expect(browser.canCarry(pin, beside: current))
        browser.split(pin, with: current)
        #expect(browser.pairs.count == 1)
        #expect(pin.pin != nil && browser.pair(of: pin.id) == nil)
        let pair = try #require(browser.pair(of: current.id))
        let half = try #require(browser.tabs.first { $0.id == pair.other(than: current.id) })
        #expect(half.pin == nil && half.address == docs)
    }

    /// ⌃⌘\ on a pin in front asks for the other half, and the open tab
    /// chosen goes beside a copy of the pin's page.
    @Test func splitViewFromAPin() {
        let (browser, id) = window()
        defer { forget(id) }
        let other = browser.open(page, foreground: false)
        let pin = browser.open(docs, foreground: true)
        browser.pin(pin)
        #expect(browser.active === pin)
        #expect(Command.splitView.available(in: browser))
        browser.splitView()
        #expect(browser.asked == .split)
        #expect(browser.splitTakes(other))
        browser.take(Suggestion(key: other.label, title: "", url: other.address, kind: .open, tab: other.id))
        #expect(browser.pairs.count == 1)
        #expect(browser.pair(of: other.id) != nil && browser.pair(of: pin.id) == nil)
        #expect(pin.pin != nil)
    }

    /// Pinning a half: the pair stays on screen with the same two tabs, and
    /// a new square on the half's page is in the grid.
    @Test func pinningAHalfKeepsTheSplit() throws {
        let (browser, id) = window()
        defer { forget(id) }
        let left = browser.open(page, foreground: true)
        let right = browser.open(docs, foreground: false)
        browser.split(right, with: left)
        let before = try #require(browser.pairs.first)
        let square = try #require(browser.pin(right))
        #expect(square !== right)
        #expect(square.pin != nil && (square.pending ?? square.address) == docs)
        #expect(right.pin == nil)
        #expect(browser.pairs == [before])
        #expect(browser.pair(of: square.id) == nil)
        #expect(browser.tabs.first === square)
    }

    /// The same for several picked at once, a loose tab among them pinned
    /// itself.
    @Test func pinningAGroupWithAHalfKeepsTheSplit() {
        let (browser, id) = window()
        defer { forget(id) }
        let loose = browser.open(URL(string: "https://example.test/loose")!, foreground: false)
        let left = browser.open(page, foreground: true)
        let right = browser.open(docs, foreground: false)
        browser.split(right, with: left)
        browser.pin([loose, right])
        #expect(browser.pairs.count == 1 && browser.pair(of: right.id) != nil)
        #expect(loose.pin != nil && right.pin == nil)
        let pins = browser.tabs.filter { $0.pin != nil }
        #expect(pins.count == 2)
        #expect(pins.contains { ($0.pending ?? $0.address) == docs && $0 !== right })
        #expect(pins.allSatisfy { browser.pair(of: $0.id) == nil })
    }

    /// ⌃⌘\ in a window too narrow for two halves: nothing opens, the corner
    /// says why.
    @Test func tooNarrowSaysWhy() {
        let (browser, id) = window(width: 500)
        defer { forget(id) }
        _ = browser.open(page, foreground: true)
        _ = browser.open(docs, foreground: false)
        #expect(browser.splitRefusal(browser.active!) == "Window is too narrow for Split View")
        browser.splitView()
        #expect(browser.asked != .split && browser.pairs.isEmpty)
        #expect(browser.toaster.words == "Window is too narrow for Split View")
    }

    /// Wide enough, a page has nothing to say no to.
    @Test func wideEnoughHasNoRefusal() {
        let (browser, id) = window()
        defer { forget(id) }
        let tab = browser.open(page, foreground: true)
        #expect(browser.splitRefusal(tab) == nil)
        browser.pin(tab)
        #expect(browser.splitRefusal(tab) == nil)
    }

    // MARK: - the copy goes with the pair (row 383)

    /// What a pair coming apart leaves to run, run: the halves let go and the
    /// copy closed (`dropCarried`), a few beats.
    private func settle(_ browser: Browser) async throws {
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(30))
            browser.settleNow()
        }
    }

    /// A page beside a pin: the pin, the page in front, and the copy of the
    /// pin's page in the pair with it.
    private func pinPair(_ browser: Browser) throws -> (pin: Tab, page: Tab, copy: Tab) {
        let pin = browser.open(docs, foreground: false)
        browser.pin(pin)
        let current = browser.open(page, foreground: true)
        browser.split(pin, with: current)
        let pair = try #require(browser.pair(of: current.id))
        let copy = try #require(browser.tabs.first { $0.id == pair.other(than: current.id) })
        #expect(copy.carriedFrom == pin.id && browser.carriedHome(copy) === pin)
        return (pin, current, copy)
    }

    /// Separated, the copy closes; the pin stays in the grid and the page
    /// stays a tab.
    @Test func separatingClosesTheCopy() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (pin, current, copy) = try pinPair(browser)
        browser.separate(browser.pair(of: current.id), keeping: current.id)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(!browser.tabs.contains { $0.id == copy.id })
        #expect(browser.tabs.contains { $0 === pin } && pin.pin != nil)
        #expect(browser.tabs.contains { $0 === current })
        #expect(browser.tabs.filter { $0.pin == nil && $0.address == docs }.isEmpty)
    }

    /// Separated with the copy in front: you land on the pin, the copy gone.
    @Test func separatingFromTheCopyLandsOnThePin() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (pin, current, copy) = try pinPair(browser)
        browser.separate(browser.pair(of: current.id), keeping: copy.id)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(!browser.tabs.contains { $0.id == copy.id })
        #expect(browser.active === pin)
        #expect(browser.tabs.contains { $0 === current })
    }

    /// The cross on the copy's band: the copy goes, not into today's.
    @Test func leavingTheCopyClosesIt() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (pin, current, copy) = try pinPair(browser)
        browser.leaveSplit(copy.id)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(!browser.tabs.contains { $0.id == copy.id })
        #expect(pin.pin != nil && browser.tabs.contains { $0 === current })
    }

    /// The other half closed: the pair goes whole, you land on the pin.
    @Test func closingTheOtherHalfClosesTheCopy() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (pin, current, copy) = try pinPair(browser)
        browser.close(current)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(!browser.tabs.contains { $0.id == copy.id || $0.id == current.id })
        #expect(browser.active === pin && pin.pin != nil)
    }

    /// A copy taken to another site is a tab like any other: it stays.
    @Test func aCopyTakenElsewhereStays() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let (pin, current, copy) = try pinPair(browser)
        copy.go(to: URL(string: "https://elsewhere.test/")!)
        #expect(browser.carriedHome(copy) == nil)
        browser.separate(browser.pair(of: current.id), keeping: current.id)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(browser.tabs.contains { $0 === copy })
        #expect(pin.pin != nil)
    }

    /// A pair of two of today's tabs comes apart as ever: both stay.
    @Test func plainPairsKeepBothTabs() async throws {
        let (browser, id) = window()
        defer { forget(id) }
        let left = browser.open(page, foreground: true)
        let right = browser.open(docs, foreground: false)
        browser.split(right, with: left)
        browser.separate(browser.pair(of: left.id), keeping: left.id)
        try await settle(browser)
        #expect(browser.pairs.isEmpty)
        #expect(browser.tabs.contains { $0 === left } && browser.tabs.contains { $0 === right })
    }
}
