import AppKit
import Testing
@testable import Fast

struct WheelGlideTimingTests {
    @Test func deliveryDelayShortensTheInitialCurveAsInChromium() {
        let curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 10, delayedBy: 0.02)
        #expect(abs(curve.end - 10.18) < 1e-9)
        #expect(abs(curve.value(at: 10.09).y - 20) < 0.01)
        #expect(curve.value(at: curve.end).y == 40)
    }

    @Test func aFullyDelayedNotchStillDeliversItsWholeDistance() {
        let curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 10, delayedBy: 0.3)
        #expect(curve.end == 10)
        #expect(curve.value(at: 10).y == 40)
        #expect(curve.velocity(at: 10) == 0)
    }

    @Test func negativeDelayDoesNotExtendTheAnimation() {
        #expect(abs(WheelCurve.duration(40, delayedBy: -0.1) - 0.2) < 1e-9)
    }

    @Test @MainActor func eventAgeUsesOnlyValidPastTimestamps() {
        #expect(abs(WheelGlide.delay(since: 10, at: 10.02) - 0.02) < 1e-9)
        #expect(WheelGlide.delay(since: 0, at: 10) == 0)
        #expect(WheelGlide.delay(since: -1, at: 10) == 0)
        #expect(WheelGlide.delay(since: 11, at: 10) == 0)
        #expect(WheelGlide.delay(since: .nan, at: 10) == 0)
        #expect(WheelGlide.delay(since: .infinity, at: 10) == 0)
        #expect(WheelGlide.delay(since: 10, at: .infinity) == 0)
    }

    @Test func aNewNotchRestartsAfterAZeroDurationSegment() {
        var curve = WheelCurve(from: .zero, to: CGPoint(x: 0, y: 40), at: 10, delayedBy: 0.3)
        curve.retarget(to: CGPoint(x: 0, y: 80), at: 10)
        #expect(curve.value(at: 10).y == 40)
        #expect(curve.value(at: curve.end).y == 80)
        #expect(abs(curve.end - 10.2) < 1e-9)
    }
}
