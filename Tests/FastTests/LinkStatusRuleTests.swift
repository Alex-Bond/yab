import Testing
@testable import Fast

/// The link pill's rule (LinkStatus.Rule): only the pointer's own moves
/// show a link; a scroll under a pointer at rest shows none and takes the
/// pill off a link it carried away (rows 1051, 1181).
struct LinkStatusRuleTests {
    @Test func aMoveOntoALinkShowsItAtOnce() {
        var rule = LinkStatus.Rule()
        rule.moved()
        #expect(rule.next(showing: nil as String?, offered: "a") == "a")
        rule.moved()
        #expect(rule.next(showing: "a", offered: "b") == "b")
        rule.moved()
        #expect(rule.next(showing: "b", offered: nil) == nil)
    }

    @Test func aLinkAScrollBringsUnderAPointerAtRestShowsNothing() {
        var rule = LinkStatus.Rule()
        rule.moved()
        #expect(rule.next(showing: nil as String?, offered: nil) == nil)
        rule.scrolled()
        #expect(rule.next(showing: nil as String?, offered: "a") == nil)
        #expect(rule.next(showing: nil as String?, offered: "b") == nil)
        // Nothing has been said since the page opened: no move yet either.
        var fresh = LinkStatus.Rule()
        #expect(fresh.next(showing: nil as String?, offered: "a") == nil)
    }

    @Test func aScrollTakesThePillOffTheLinkItShowed() {
        var rule = LinkStatus.Rule()
        rule.moved()
        #expect(rule.next(showing: nil as String?, offered: "a") == "a")
        rule.scrolled()
        // Still on it: kept, as keys held say it again.
        #expect(rule.next(showing: "a", offered: "a") == "a")
        // Carried off it, onto another link or none: the pill goes.
        #expect(rule.next(showing: "a", offered: "b") == nil)
        rule.scrolled()
        #expect(rule.next(showing: "a", offered: nil) == nil)
    }

    @Test func aPointerMovingThroughAScrollShowsWhatItIsOver() {
        var rule = LinkStatus.Rule()
        rule.scrolled()
        rule.moved()
        #expect(rule.next(showing: nil as String?, offered: "a") == "a")
        rule.scrolled()
        rule.moved()
        #expect(rule.next(showing: "a", offered: "b") == "b")
        // The next word with no move in between is the scroll's again.
        #expect(rule.next(showing: "b", offered: "c") == nil)
    }
}
