import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Fast

/// Measures the production SwiftUI status Text and its padding. These are
/// intrinsic-layout checks, not pointer, pixel or reporter-profile acceptance.
@MainActor @Suite(.serialized)
struct LiveStatusLayoutTests {
    private func withTab(_ check: (Fast.Tab) throws -> Void) throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Fast.Tab(configuration: configuration)
        tab.restore(url: URL(string: "https://live-status.invalid/fixture")!, title: "Owned fixture")
        defer { tab.close() }
        try check(tab)
        #expect(tab.builtPage == nil, "Status layout must not construct a page or sign in")
    }

    private func size(_ tab: Fast.Tab, clear: CGFloat) -> NSSize {
        let host = NSHostingView(rootView: LiveWordsView(tab: tab, clearance: clear))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test(arguments: [false, true])
    func actualStatusTextLeavesTheOccupiedEndSlotClear(column: Bool) throws {
        try withTab { tab in
            tab.live = LiveMark(key: "owned", words: .late)
            let clear = TabEnd.clear(tab, hovering: true, slotted: true, speaker: !column,
                                     unkeeps: column, pitch: column ? TabEnd.beside : TabEnd.across)
            try #require(clear > 0)
            let statuses: [LiveSaid?] = [nil, LiveSaid(text: "$3,800 · −$150", loud: true)]
            for said in statuses {
                tab.live?.said = said
                let natural = size(tab, clear: 0)
                let occupied = size(tab, clear: clear)
                try #require(natural.width > 0 && natural.height > 0, "The actual status Text must be laid out")
                #expect(abs(occupied.width - natural.width - clear) < 0.5,
                        "The production status must reserve the existing end slot outside its glyphs")
                #expect(abs(occupied.height - natural.height) < 0.5)
            }
        }
    }

    @Test func aTabWithoutStatusDoesNotGainAnInvisibleGap() throws {
        try withTab { tab in
            #expect(!LiveWordsView.hasWords(tab))
            let clear = TabEnd.clear(tab, hovering: true, slotted: true, speaker: false, unkeeps: true, pitch: TabEnd.beside)
            try #require(clear > 0)
            let empty = size(tab, clear: clear)
            #expect(empty.width < 0.5 && empty.height < 0.5)
            tab.live = LiveMark(key: "owned", words: nil)
            #expect(!LiveWordsView.hasWords(tab))
            #expect(size(tab, clear: clear).width < 0.5)
        }
    }

    @Test func aFaceBesideTheCrossReservesBothExistingSlots() throws {
        try withTab { tab in
            tab.live = LiveMark(key: "owned", words: .late)
            let cross = TabEnd.clear(tab, hovering: true, slotted: true, speaker: false, unkeeps: true, pitch: TabEnd.beside)
            // Only local tab state: no task/session is created or bound.
            tab.unread = AgentFeed.Unread(session: "owned-layout-fixture")
            try #require(tab.wearsFace)
            let both = TabEnd.clear(tab, hovering: true, slotted: true, speaker: false, unkeeps: true, pitch: TabEnd.beside)
            try #require(both > cross)
            let single = size(tab, clear: cross), double = size(tab, clear: both)
            #expect(abs(double.width - single.width - (both - cross)) < 0.5)
        }
    }

    @Test func aKeptSleepingTabWithoutAnEndControlKeepsItsNaturalStatusWidth() throws {
        try withTab { tab in
            tab.kept = true
            tab.live = LiveMark(key: "owned", words: .late)
            try #require(tab.putDown && LiveWordsView.hasWords(tab))
            let clear = TabEnd.clear(tab, hovering: false, slotted: false, speaker: false, unkeeps: true, pitch: TabEnd.beside)
            #expect(clear == 0)
            #expect(size(tab, clear: clear).width == size(tab, clear: 0).width)
        }
    }
}
