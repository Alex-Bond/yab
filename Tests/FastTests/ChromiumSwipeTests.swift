import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumSwipeTests {
    @Test func appKitPhasesBecomeCoreGraphicsFields() {
        #expect(ChromiumWheelPhase.gesture([]) == 0)
        #expect(ChromiumWheelPhase.gesture(.mayBegin) == 128)
        #expect(ChromiumWheelPhase.gesture(.began) == 1)
        #expect(ChromiumWheelPhase.gesture(.changed) == 2)
        #expect(ChromiumWheelPhase.gesture(.ended) == 4)
        #expect(ChromiumWheelPhase.gesture(.cancelled) == 8)
        #expect(ChromiumWheelPhase.momentum(.began) == 1)
        #expect(ChromiumWheelPhase.momentum(.changed) == 2)
        #expect(ChromiumWheelPhase.momentum(.ended) == 3)
    }

    @Test func nativeWheelRoundTripPreservesGestureAndMomentum() throws {
        for (gesture, momentum) in [(128, 0), (1, 0), (2, 0), (4, 0), (8, 0), (0, 1), (0, 2), (0, 3)] {
            let input = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
            input.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(gesture))
            input.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
            let event = try #require(NSEvent(cgEvent: input))
            let output = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
            output.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(ChromiumWheelPhase.gesture(event.phase)))
            output.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(ChromiumWheelPhase.momentum(event.momentumPhase)))
            let forwarded = try #require(NSEvent(cgEvent: output))
            #expect(forwarded.phase == event.phase)
            #expect(forwarded.momentumPhase == event.momentumPhase)
        }
    }
}
