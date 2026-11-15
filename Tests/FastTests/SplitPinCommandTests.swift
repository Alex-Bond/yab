import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct SplitPinCommandTests {
    private func world(blocked: Bool = false, _ body: (Browser, Tab, Tab, Pair, UUID) throws -> Void) rethrows {
        let id = UUID(), browser = Browser(windowID: id)
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
        }
        let left = Tab(), right = Tab(bench: blocked)
        for tab in [left, right] { browser.prepare(tab) }
        left.restore(url: URL(string: "https://left.test/page")!, title: "Left")
        right.restore(url: URL(string: "https://right.test/page")!, title: "Right")
        browser.lay([left, right])
        browser.activeID = left.id
        browser.splitBook.place = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let pair = Pair(first: left.id, second: right.id, share: 0.6)
        browser.pairs = [pair]
        try body(browser, left, right, pair, id)
    }

    @Test(arguments: [false, true], [false, true])
    func shortcutTogglesTheWholeSplit(rightFront: Bool, bothPicked: Bool) {
        world { browser, left, right, pair, _ in
            browser.activeID = rightFront ? right.id : left.id
            if bothPicked { browser.extend(to: rightFront ? left : right) }
            #expect(browser.several == bothPicked)
            let front = browser.activeID
            browser.togglePin()
            #expect(left.pin != nil && right.pin != nil)
            #expect(browser.tabs.map(\.id) == [left.id, right.id])
            #expect(browser.gridPins.map(\.id) == [left.id])
            #expect(browser.pinCellCount == 1)
            #expect(browser.stagePair == pair && browser.activeID == front)
            browser.togglePin()
            #expect(left.pin == nil && right.pin == nil)
            #expect(browser.gridPins.isEmpty)
            #expect(browser.pairs == [pair] && browser.stagePair == pair)
            #expect(browser.activeID == front)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func fieldPinAndUnpinActOnBothPages(rightFront: Bool, bothPicked: Bool) throws {
        try world { browser, left, right, pair, id in
            browser.activeID = rightFront ? right.id : left.id
            if bothPicked { browser.extend(to: rightFront ? left : right) }
            #expect(browser.several == bothPicked)
            let front = browser.activeID
            #expect(Command.pinTab.available(in: browser))
            #expect(!Command.unpinTab.available(in: browser))
            Command.pinTab.run(in: browser)
            #expect(left.pin != nil && right.pin != nil)
            #expect(browser.gridPins.map(\.id) == [left.id])
            #expect(browser.tabs.count == 2 && browser.stagePair == pair)
            #expect(!Command.pinTab.available(in: browser))
            #expect(Command.unpinTab.available(in: browser))
            Command.unpinTab.run(in: browser)
            #expect(left.pin == nil && right.pin == nil)
            #expect(browser.pairs == [pair] && browser.gridPins.isEmpty)
            #expect(browser.tabs.map(\.id) == [left.id, right.id])
            #expect(browser.activeID == front && browser.stagePair == pair)
            let saved = Session.read(space: browser.spaceID, window: id)
            let written = try #require(saved.pairs?.first)
            #expect(saved.tabs.count == 2 && saved.pairs?.count == 1)
            #expect(saved.tabs[written.first].pin == nil && saved.tabs[written.second].pin == nil)
            #expect(abs(written.share - pair.share) < 0.001)
            #expect(Command.pinTab.available(in: browser))
            #expect(!Command.unpinTab.available(in: browser))
        }
    }

    @Test(arguments: [false, true])
    func commandPinnedSplitRestoresAndOpensAsOnePin(field: Bool) throws {
        try world { browser, left, right, pair, id in
            browser.activeID = right.id
            if field { Command.pinTab.run(in: browser) } else { browser.togglePin() }
            browser.writeSession(now: true)
            let saved = Session.read(space: browser.spaceID, window: id)
            let written = try #require(saved.pairs?.first)
            #expect(saved.tabs.count == 2 && saved.pairs?.count == 1)
            #expect(saved.tabs[written.first].pin != nil && saved.tabs[written.second].pin != nil)
            #expect(saved.tabs[written.first].url == left.address?.absoluteString)
            #expect(saved.tabs[written.second].url == right.address?.absoluteString)
            #expect(abs(written.share - 0.6) < 0.001)
            browser.pairs = []
            for tab in browser.tabs { tab.close() }
            browser.lay([])
            browser.activeID = nil
            let row = browser.loadRow(browser.spaceID)
            browser.lay(row.tabs)
            browser.pairs = row.pairs
            let restored = try #require(browser.pinPair(of: row.tabs.first?.id))
            #expect(restored.first == pair.first && restored.second == pair.second)
            #expect(abs(restored.share - pair.share) < 0.001)
            #expect(row.active == right.id)
            #expect(browser.gridPins.count == 1 && browser.pinnedCount == 2)
            let square = try #require(browser.tab(id: restored.first))
            browser.tapTab(square)
            #expect(browser.stagePair == restored)
            #expect(browser.pinMate(of: square)?.address == right.address)
            Command.unpinTab.run(in: browser)
            #expect(browser.tabs.allSatisfy { $0.pin == nil })
            #expect(browser.pairs == [restored] && browser.stagePair == restored)
        }
    }

    @Test func anUnpinnablePartnerNeverLeavesASinglePagePin() {
        world(blocked: true) { browser, left, right, pair, _ in
            #expect(!browser.canPinPair(pair))
            #expect(!Command.pinTab.available(in: browser))
            Command.pinTab.run(in: browser)
            browser.togglePin()
            #expect(left.pin == nil && right.pin == nil)
            #expect(browser.tabs.count == 2 && browser.pairs == [pair])
        }
    }

    @Test(arguments: [false, true])
    func twoExistingPinsBecomeOnePinWithoutCopies(field: Bool) throws {
        try world { browser, left, right, _, _ in
            browser.pairs = []
            browser.pin(left)
            browser.pin(right)
            browser.split(right, with: left)
            let copies = try #require(browser.pair(of: browser.activeID))
            #expect(!copies.contains(left.id) && !copies.contains(right.id))
            if field { Command.pinTab.run(in: browser) } else { browser.togglePin() }
            browser.settleNow()
            let pinned = try #require(browser.pinPair(of: left.id))
            #expect(pinned.first == left.id && pinned.second == right.id)
            #expect(browser.tabs.map(\.id) == [left.id, right.id])
            #expect(browser.gridPins.map(\.id) == [left.id])
            #expect(browser.stagePair == pinned)
        }
    }

    @Test(arguments: [false, true])
    func aStandalonePageStillPinsAndUnpinsItself(field: Bool) {
        world { browser, left, right, _, _ in
            browser.pairs = []
            Command.pinTab.run(in: browser)
            #expect(left.pin != nil && right.pin == nil)
            #expect(browser.gridPins.map(\.id) == [left.id])
            if field { Command.unpinTab.run(in: browser) } else { browser.togglePin() }
            #expect(left.pin == nil && right.pin == nil)
            #expect(browser.tabs.count == 2 && browser.pairs.isEmpty)
        }
    }
}
