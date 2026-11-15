import CoreGraphics
import Testing
@testable import Fast

/// How far a tab's title stops short of its end (TabEnd.clear): the cross
/// alone at the very end, and nothing else in the tab but
/// what the page is doing, a face, a ring or a speaker.
@MainActor
struct TabEndTests {
    @Test func crossAloneAtTheEnd() {
        let tab = Tab(bench: true)
        // The cross's slot and its air, at rest with something there and
        // under the pointer alike: no book or sliders come in beside it.
        #expect(TabEnd.clear(tab, hovering: true, slotted: true) == 21)
        #expect(TabEnd.clear(tab, hovering: false, slotted: true) == 21)
        #expect(TabEnd.clear(tab, hovering: false, slotted: false) == 0)
    }

    @Test func crossBesideAFace() {
        let tab = Tab(bench: true)
        tab.agent = "claude"
        #expect(TabEnd.clear(tab, hovering: false, slotted: true) == 21)
        #expect(TabEnd.clear(tab, hovering: true, slotted: true) == 21 + TabEnd.across)
    }

    @Test func crossBesideTheSpeaker() {
        let tab = Tab(bench: true)
        tab.noisy = true
        let beside: CGFloat = AudioWatch.canMute ? TabEnd.across : 0
        #expect(TabEnd.clear(tab, hovering: true, slotted: true) == 21 + beside)
    }

    /// Along the top the cross's square stands as far in from the tab's
    /// end as above and below it (RowPlate.strip): since a51c1b99b the tab
    /// follows Density, 24 five in on a comfortable 34, 20 four in on a
    /// compact 28.
    @Test func crossSquareFourIn() {
        let square = RowPlate.strip
        #expect(square.inset == (Density.current == .compact ? 4 : 5))
        #expect(TabEnd.stripEnd + TabEnd.stripSlot / 2 - square.side / 2 == square.inset)
    }
}
