import Testing
@testable import Fast

// A looping video's place on the island (Tune.position): the media starts
// over at its end with no event the island hears, so its place goes round
// the length. Release QA, 2026-10-10: a `<video loop>` 30 seconds long, left
// past one loop, read 0:30, −0:00 with a full line while it played on.
struct TuneLoopTests {
    private func tune(loops: Bool, playing: Bool = true) -> Tune {
        Tune(title: "Clip", duration: 30, elapsed: 25, stamp: 100, playing: playing, loops: loops)
    }

    @Test func aLoopGoesRoundItsLength() {
        let clip = tune(loops: true)
        #expect(clip.position(at: 104) == 29)
        #expect(clip.position(at: 112) == 7)
        #expect(clip.position(at: 172) == 7)
        #expect(abs(clip.through(at: 112) - 7.0 / 30) < 1e-9)
    }

    @Test func withoutLoopItStopsAtTheEnd() {
        let clip = tune(loops: false)
        #expect(clip.position(at: 112) == 30)
        #expect(clip.through(at: 112) == 1)
    }

    @Test func pausedItStaysWhereItWas() {
        let clip = tune(loops: true, playing: false)
        #expect(clip.position(at: 500) == 25)
    }

    @Test func fifteenOnFromNearTheEndOfALoop() {
        // The island's 15 seconds on, from 0:29 of a loop that went round
        // once: from where it plays, never from the old reading.
        let clip = tune(loops: true)
        #expect(abs(clip.through(after: 15, at: 104 + 30) - 1) < 1e-9)
        #expect(abs(clip.through(after: 15, at: 107) - 17.0 / 30) < 1e-9)
    }
}
