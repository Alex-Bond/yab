import Testing
@testable import Fast

/// What the bar over a page taking its time says, step by step through a
/// slow load (feedback register #408), and when it comes.
@MainActor
@Suite struct LoadBarTests {
    typealias P = LoadBar.Phase

    /// The tab's state as WebKit and the page tell it, in order, and the
    /// phase the bar takes at each step.
    private func walk(_ steps: [(loading: Bool, drawn: Bool, answered: Bool, want: P)]) {
        for (index, step) in steps.enumerated() {
            #expect(LoadBar.phase(loading: step.loading, drawn: step.drawn, answered: step.answered) == step.want,
                    "step \(index)")
        }
    }

    @Test func headersLate() {
        // A link: the server says nothing for seconds, then the page comes
        // and paints. Something is said all the way to the paint.
        walk([
            (false, true, true, .idle),     // the page left, painted, done
            (true, false, false, .waiting), // the link taken: no answer yet
            (true, false, false, .waiting), // ... 4 s of it
            (true, false, true, .coming),   // committed
            (true, true, true, .idle),      // painted
        ])
    }

    @Test func firstByteLateAndSlowStylesheet() {
        // Headers but no byte: not committed, still waiting. Then the
        // document, and a stylesheet holding its paint: coming until the
        // load is over, when the page has painted whether it said so or not.
        walk([
            (true, false, false, .waiting),
            (true, false, true, .coming),
            (true, false, true, .coming),
            (false, false, true, .idle),
        ])
    }

    @Test func linkTakenWhileThePageLeftWasStillLoading() {
        // A page painted but still loading (pictures, an ad) never takes
        // `loading` down to up again: the new navigation's start clears
        // `drawn` and `answered` (Tab.navigationStarted), and that is what
        // the bar hears.
        walk([
            (true, true, true, .idle),
            (true, false, false, .waiting),
            (true, false, true, .coming),
            (true, true, true, .idle),
        ])
    }

    @Test func stoppedOrFailedBeforeTheCommit() {
        walk([
            (true, false, false, .waiting),
            (false, false, true, .idle),
        ])
    }

    @Test func comesWithTheRingNotAfter() {
        // The clear bar (#408) comes when the tab's ring does, not after
        // Arc's 0.4 s; a load already that old shows at once.
        #expect(LoadBar.clear)
        #expect(LoadBar.patience == Tab.ringAfter)
        #expect(LoadBar.showIn(waited: 0) == LoadBar.patience)
        #expect(abs(LoadBar.showIn(waited: 0.1) - (LoadBar.patience - 0.1)) < 1e-9)
        #expect(LoadBar.showIn(waited: LoadBar.patience) == 0)
        #expect(LoadBar.showIn(waited: 5) == 0)
        // A clock gone backwards counts as no wait at all.
        #expect(LoadBar.showIn(waited: -3) == LoadBar.patience)
    }

    @Test func darkerFillThanArcs() {
        #expect(LoadBar.fillInk > 0.75)
    }
}
