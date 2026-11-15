import AppKit
import Testing
@testable import Fast

// The floating windows' moving marks: which one shows, whatever the motion.
struct FloatMarksTests {
    @MainActor static func button() -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        button.wantsLayer = true
        return button
    }

    static func shown(_ button: NSButton) -> [Float] {
        button.layer?.sublayers?.map(\.opacity) ?? []
    }

    @MainActor @Test func playAndPause() {
        let button = Self.button()
        let mark = Turn(on: button, "pause.fill", "play.fill", size: 17)
        mark.set(false, now: true)
        #expect(Self.shown(button) == [1, 0])
        mark.set(true, now: false)
        #expect(Self.shown(button) == [0, 1])
        mark.set(false, now: false)
        #expect(Self.shown(button) == [1, 0])
    }

    /// Body, near wave, far wave, cross.
    @MainActor @Test func speaker() {
        let button = Self.button()
        let mark = SpeakerMark(on: button, size: 12)
        mark.set(muted: false, now: true)
        #expect(Self.shown(button) == [1, 1, 1, 0])
        mark.set(muted: true, now: false)
        #expect(Self.shown(button) == [1, 0, 0, 1])
        mark.set(muted: false, now: false)
        #expect(Self.shown(button) == [1, 1, 1, 0])
    }

    @MainActor @Test func partsDraw() {
        for name in ["gobackward.arrow", "goforward.arrow", "skip.15", "speaker.body.fill",
                     "speaker.wave.inner.fill", "speaker.wave.outer.fill", "speaker.xmark"] {
            #expect(Glyphs.art(name) != nil, "\(name)")
        }
    }

    @Test func playerReportsItsOwnMute() {
        let head = Floater.Playhead([0.5, true, 30, 60, 1, 1920, 1080, true, true])
        #expect(head?.muted == true)
        let heard = Floater.Playhead([0.5, true, 30, 60, 1, 1920, 1080, true, false])
        #expect(heard?.muted == false)
    }

    /// Under the pointer the circle lightens, and goes back as it leaves;
    /// the wash sits under a mark drawn in layers, not over it.
    @MainActor @Test func hover() throws {
        let button = FloatButton(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        let mark = Turn(on: button, "mic", "mic.slash", size: 15)
        mark.set(false, now: true)
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        #expect(!button.benchLit)
        button.mouseEntered(with: event)
        #expect(button.benchLit)
        button.mouseExited(with: event)
        #expect(!button.benchLit)
        #expect(button.layer?.sublayers?.count == 3)
        #expect(button.layer?.sublayers?.first?.opacity == 0)
    }
}
