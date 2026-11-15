import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct CountIconProofTests {
    @Test func firstLoadIsUnknownEvenWithANumber() {
        var proof = CountIconProof()
        proof.observe(count: 20, icon: "number-20")
        #expect(!proof.unchanged)
        proof.observe(count: 20, icon: "number-20")
        #expect(!proof.unchanged)
    }

    @Test func numericIconAndCountChangingTogetherNeverAuthorizeAnOverlay() {
        var proof = CountIconProof()
        for n in 0...25 {
            proof.observe(count: n, icon: "number-\(n)")
            #expect(!proof.unchanged)
        }
    }

    @Test func oneCountTransitionWithTheSameIconIsTheRequiredEvidence() {
        var proof = CountIconProof()
        proof.observe(count: 20, icon: "static")
        proof.observe(count: 21, icon: "static")
        #expect(proof.unchanged)
        proof.observe(count: 0, icon: "static")
        #expect(proof.unchanged)
        proof.observe(count: 22, icon: "static")
        #expect(proof.unchanged)
    }

    @Test func iconChangesRevokeEvidenceBeforeOrAfterTheNextCountChange() {
        for changesTogether in [false, true] {
            var proof = CountIconProof()
            proof.observe(count: 20, icon: "static")
            proof.observe(count: 21, icon: "static")
            #expect(proof.unchanged)
            proof.observe(count: changesTogether ? 22 : 21, icon: "number-22")
            #expect(!proof.unchanged)
            // Repeating the snapshot is not a count transition.
            proof.observe(count: changesTogether ? 22 : 21, icon: "number-22")
            #expect(!proof.unchanged)
        }
    }

    @Test func anIconUpdateBeforeTheTitleIsPartOfTheSameCountInterval() {
        var proof = CountIconProof()
        proof.observe(count: 20, icon: "number-20")
        proof.observe(count: 20, icon: "number-21")
        proof.observe(count: 21, icon: "number-21")
        #expect(!proof.unchanged)
        proof.observe(count: 21, icon: "number-22")
        proof.observe(count: 22, icon: "number-22")
        #expect(!proof.unchanged)
    }

    @Test func aKnownCountIconCannotBecomeStaticProofWhenTitleAndIconDisagree() {
        var proof = CountIconProof()
        proof.observe(count: 20, icon: "number-20")
        proof.observe(count: 21, icon: "number-21")
        #expect(!proof.unchanged)
        proof.observe(count: 20, icon: "number-21")
        #expect(!proof.unchanged)
        proof.observe(count: 19, icon: "number-21")
        #expect(!proof.unchanged)
    }

    @Test func aMissingFeedIsNotAZeroToUnreadTransition() {
        var proof = CountIconProof()
        proof.observe(count: nil, icon: "static")
        proof.observe(count: 20, icon: "static")
        #expect(!proof.unchanged)
        proof.observe(count: 21, icon: "static")
        #expect(proof.unchanged)

        var changing = CountIconProof()
        changing.observe(count: nil, icon: "number-20")
        changing.observe(count: nil, icon: "number-21")
        changing.observe(count: 20, icon: "number-21")
        changing.observe(count: 21, icon: "number-21")
        #expect(!changing.unchanged)
    }

    @Test func anIgnoredTitleChangeCannotProveAFeedIconPlain() {
        let tab = Tab()
        defer { tab.close() }
        tab.restore(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Inbox (20) - Gmail")
        tab.kept = true
        tab.countIconLoaded()
        // Without a page the same selected-count path uses its feed only.
        tab.observedCountIcon(title: "Inbox (20) - Gmail", icon: "static")
        tab.sourced(20)
        tab.observedCountIcon(title: "Spam (100) - Gmail", icon: "static")
        #expect(!tab.showsOwnCount) // first known feed value is not a change
        tab.observedCountIcon(title: "Spam (200) - Gmail", icon: "static")
        #expect(!tab.showsOwnCount && tab.count == 20)
        tab.sourced(21)
        tab.observedCountIcon(title: "Spam (200) - Gmail", icon: "static")
        #expect(tab.showsOwnCount && tab.count == 21)
    }

    @Test func zeroToUnreadAlsoCountsButAReloadDoesNotInheritEvidence() {
        var proof = CountIconProof()
        proof.observe(count: 0, icon: "static")
        proof.observe(count: 1, icon: "static")
        #expect(proof.unchanged)
        proof = CountIconProof()
        proof.observe(count: 2, icon: "static")
        #expect(!proof.unchanged)
    }

    @Test(arguments: [true, false])
    func pinsAndKeptRowsShareThePolicyAndNavigationResetsTheApiException(pinned: Bool) {
        let tab = Tab()
        defer { tab.close() }
        tab.restore(url: URL(string: "https://discord.com/channels/test")!, title: "(20) Fixture")
        if pinned { tab.pin = "F" } else { tab.kept = true }
        tab.sourced(20)
        #expect(tab.unadornedCountCorner?.words == "20")
        #expect(tab.countCorner == nil)
        tab.observedCountIcon(title: "(20) Fixture", icon: "static")
        #expect(tab.countCorner == nil)
        tab.sourced(21)
        tab.observedCountIcon(title: "(21) Fixture", icon: "static")
        #expect(tab.countCorner == nil) // old cached icon is not the page's evidence
        tab.countIconLoaded()
        #expect(tab.countCorner?.words == "21")
        tab.countIconFetchStarted()
        #expect(tab.countCorner == nil)
        tab.countIconLoaded()
        #expect(tab.countCorner?.words == "21")
        tab.observedCountIcon(title: "(21) Fixture", icon: "number-21")
        #expect(tab.countCorner == nil)
        tab.badged(7)
        #expect(tab.showsOwnCount && tab.appBadgeCount == 7)
        tab.observedCountIcon(title: "(22) Fixture", icon: "number-22")
        #expect(tab.showsOwnCount) // explicit API exception
        tab.badged(0)
        #expect(tab.appBadgeCount == 0 && tab.showsOwnCount)
        tab.sourced(0)
        #expect(tab.countCorner == nil)
        #expect(!tab.rowLabel.contains("(20)")) // API zero must not revive a stale title count
        tab.prepareDocumentMetadata(for: URL(string: "https://discord.com/next")!)
        #expect(!tab.showsOwnCount && tab.appBadgeCount == nil)
        tab.observedCountIcon(title: "(23) Stale document", icon: "number-22")
        #expect(!tab.showsOwnCount)
        tab.documentMetadataCommitted()
        tab.observedCountIcon(title: "(23) Fixture", icon: "number-22")
        #expect(!tab.showsOwnCount)
    }
}
