import AppKit
import Testing
@testable import Fast

struct WheelGlideTests {
    @Test func oneNotchEasesOverChromesTwoHundredMilliseconds() {
        let curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: -40), at: 10)
        #expect(abs(curve.end - 10.2) < 1e-9)
        #expect(curve.value(at: 10) == .zero)
        #expect(curve.value(at: 10.2).y == -40)
        // ease-in-out: slow start, half way at half time, slow end
        #expect(abs(curve.value(at: 10.1).y + 20) < 0.01)
        #expect(abs(curve.value(at: 10 + 1.0 / 60).y) < 1)
        let frames = (1...12).map { curve.value(at: 10 + Double($0) / 60).y }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1 <= $0 })
    }

    @Test func durationFollowsChromesInverseDelta() {
        #expect(abs(WheelCurve.duration(40) - 0.2) < 1e-9)
        #expect(abs(WheelCurve.duration(120) - 0.2) < 1e-9)
        #expect(abs(WheelCurve.duration(300) - 9.0 / 60) < 1e-9)
        #expect(abs(WheelCurve.duration(-480) - 0.1) < 1e-9)
        #expect(abs(WheelCurve.duration(2000) - 0.1) < 1e-9)
    }

    @Test func aSecondNotchKeepsTheSpeedAndReachesTheSum() {
        var curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 0)
        let before = curve.velocity(at: 0.1)
        let here = curve.value(at: 0.1)
        curve.retarget(to: CGPoint(x: 0, y: 80), at: 0.1)
        #expect(curve.value(at: 0.1) == here)
        #expect(abs(curve.velocity(at: 0.1) - before) < 1)
        #expect(curve.end <= 0.1 + 0.2 + 1e-9)
        #expect(curve.value(at: curve.end).y == 80)
    }

    @Test func anOlderNotchConsumesItsDelayRatherThanRestartingTheFullTail() {
        // Chromium's CurveWithLargeDelay: an update older than the current
        // segment keeps its start, and shortens the remaining duration.
        var curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 10)
        curve.retarget(to: CGPoint(x: 0, y: 80), at: 9.95)
        #expect(curve.start == 10)
        #expect(abs(curve.end - 10.15) < 1e-9)
        #expect(abs(curve.value(at: 10.075).y - 40) < 0.01)
        #expect(curve.value(at: 10.15).y == 80)
    }

    @Test func inputOlderThanTheAnimationSettlesWithoutAnotherTail() {
        var curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 10)
        curve.retarget(to: CGPoint(x: 0, y: 80), at: 9.7)
        #expect(curve.end == curve.start)
        #expect(curve.value(at: 10).y == 80)
    }

    @Test func aSpinNeverRunsBackwardsAndEndsOnTheSum() {
        var curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 0)
        var last = 0.0, time = 0.0
        for notch in 1..<12 {
            time = Double(notch) * 0.045
            curve.retarget(to: CGPoint(x: 0, y: Double(notch + 1) * 40), at: time)
        }
        var t = 0.0
        while t < curve.end + 0.05 {
            let y = Double(curve.value(at: t).y)
            #expect(y >= last - 0.01)
            last = y
            t += 1.0 / 120
        }
        #expect(last == 480)
    }

    @Test @MainActor func eachFrameIsAPreciseEventForTheNotchesWindowAndPlace() throws {
        let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -1, wheel2: 0, wheel3: 0))
        // CGEvent's default source inherits the console's held modifiers.
        // This fixture represents an unmodified notch, independent of that state.
        notch.flags = []
        notch.location = CGPoint(x: 300, y: 200)
        let line = try #require(NSEvent(cgEvent: notch))
        #expect(WheelGlide.glides(line))
        let event = try #require(WheelGlide.event(like: notch, by: CGPoint(x: 0, y: -7)))
        #expect(event.hasPreciseScrollingDeltas)
        #expect(event.scrollingDeltaY == -7)
        #expect(event.scrollingDeltaX == 0)
        #expect(event.phase == [])
        #expect(event.momentumPhase == [])
        #expect(event.locationInWindow == line.locationInWindow)
        #expect(!WheelGlide.glides(event))
    }

    @Test @MainActor func zoomAndTrackpadsAreNotNotches() throws {
        let notch = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        notch.flags = .maskCommand
        #expect(!WheelGlide.glides(try #require(NSEvent(cgEvent: notch))))
        let finger = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        finger.flags = []
        finger.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        finger.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        #expect(!WheelGlide.glides(try #require(NSEvent(cgEvent: finger))))
    }
}
