import QuartzCore
import Testing
@testable import Fast

/// Register row 991: picking Glass knocked the trackpad twice. A pull to
/// the wave's end knocks there, and going on into the glass past it knocked
/// again a moment later.
@MainActor
@Suite(.serialized)
struct GlassKnockTests {
    @Test func theWavesEndAndTheGlassPastItKnockOnce() {
        // Clear of any knock before.
        let wait = Date().addingTimeInterval(Knock.apart + 0.05)
        while Date() < wait { RunLoop.current.run(until: wait) }
        let before = Knock.played
        // The pill dragged to the wave's end: its knock.
        Detents.feel(0.9, 1, every: 0.2)
        // On into the bead in the same pull: LookSlider.enter's knock.
        Knock.play()
        #expect(Knock.played == before + 1)

        // Knocks far enough apart are each felt.
        let now = CACurrentMediaTime() + 1
        #expect(Knock.due(at: now))
        #expect(!Knock.due(at: now + Knock.apart / 2))
        #expect(Knock.due(at: now + Knock.apart))
    }
}
