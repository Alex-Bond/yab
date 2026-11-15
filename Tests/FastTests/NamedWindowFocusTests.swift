import Foundation
import Testing
@testable import Fast

/// A named window's tab WebKit asks to bring forward (register 1661): only a
/// tab of the row, not in front yet, not an agent's, right after your input.
struct NamedWindowFocusTests {
    let tab = UUID(), front = UUID()

    @Test func aTabOfTheRowComesForwardRightAfterYourClick() {
        #expect(Browser.bringsForward(tab: tab, active: front, inRow: true, bench: false, lastInput: 100, now: 100.2))
        #expect(Browser.bringsForward(tab: tab, active: front, inRow: true, bench: false, lastInput: 100, now: 101.5))
    }

    @Test func aPageAskingOnItsOwnTakesNothingOver() {
        #expect(!Browser.bringsForward(tab: tab, active: front, inRow: true, bench: false, lastInput: nil, now: 100))
        #expect(!Browser.bringsForward(tab: tab, active: front, inRow: true, bench: false, lastInput: 100, now: 102))
        #expect(!Browser.bringsForward(tab: tab, active: front, inRow: true, bench: false, lastInput: 101, now: 100))
    }

    @Test func onlyTheRowsOwnTabsAndNeverAnAgentsOrTheOneInFront() {
        #expect(!Browser.bringsForward(tab: tab, active: front, inRow: false, bench: false, lastInput: 100, now: 100.1))
        #expect(!Browser.bringsForward(tab: tab, active: front, inRow: true, bench: true, lastInput: 100, now: 100.1))
        #expect(!Browser.bringsForward(tab: tab, active: tab, inRow: true, bench: false, lastInput: 100, now: 100.1))
    }
}
