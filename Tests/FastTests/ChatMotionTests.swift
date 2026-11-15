import Foundation
import Testing
@testable import Fast

// The words that move as a message is sent and answered (ChatMotion.swift):
// which state words change in place, and how an answer's newest words
// soak in a step at a time.
struct ChatMotionTests {
    @Test func aStateChangesInPlaceOnlyWhenItsFirstWordDoes() {
        // The letters the two begin with stand still.
        #expect(MorphWords.shared("Working for 58s", "Worked for 58s") == "Work")
        #expect(MorphWords.shared("Thinking", "Reading bhphotovideo.com") == "")
        #expect(MorphWords.shared("Waiting for you · 4s", "Working for 9s") == "W")
        // A clock's seconds just change, and so do the same words.
        #expect(MorphWords.shared("Working for 3s", "Working for 4s") == nil)
        #expect(MorphWords.shared("Thinking", "Thinking") == nil)
    }

    @Test func theNewestWordsSoakInAStepAtATime() {
        let seen = FreshText.Seen()
        // A paragraph begun: all of it the newest stretch.
        #expect(seen.advance(to: 10))
        #expect(seen.newer == 0 && seen.newest == 0)
        // More came: what was there a step darker, the new words lightest.
        #expect(seen.advance(to: 25))
        #expect(seen.newer == 0 && seen.newest == 10)
        #expect(seen.advance(to: 40))
        #expect(seen.newer == 10 && seen.newest == 25)
        // Nothing new: nothing moves.
        #expect(!seen.advance(to: 40))
        #expect(seen.newer == 10 && seen.newest == 25)
        // Words held back (a bold mark not closed): nothing fresh past them.
        #expect(seen.advance(to: 20))
        #expect(seen.newer == 10 && seen.newest == 20)
        // The words stopped: all in full.
        seen.settle()
        #expect(seen.newer == 20 && seen.newest == 20)
    }
}
