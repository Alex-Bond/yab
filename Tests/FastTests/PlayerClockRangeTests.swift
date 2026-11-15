import Testing
@testable import Fast

/// Exercise the production formatter without constructing a player or view.
@MainActor
struct PlayerClockRangeTests {
    @Test(arguments: [
        (0.0, "0:00"),
        (0.01, "0:00"),
        (0.999, "0:00"),
        (59.9, "0:59"),
        (60.0, "1:00"),
        (125.9, "2:05"),
    ])
    func ordinarySecondsKeepTheirFloorAndMinuteFormat(_ value: (Double, String)) {
        #expect(BandView.clock(value.0) == value.1)
    }

    @Test(arguments: [
        -1.0,
        -0.01,
        Double.nan,
        Double.infinity,
        -Double.infinity,
        Double.greatestFiniteMagnitude,
        Double(Int.max),
    ])
    func invalidOrUnrepresentableSecondsUseTheNeutralClock(_ seconds: Double) {
        #expect(BandView.clock(seconds) == "0:00")
    }

    @Test func largestRepresentableDoubleBelowTheIntegerBoundaryStillFormats() {
        // On the supported 64-bit Macs Double(Int.max) rounds up to 2^63.
        // The preceding Double is 9_223_372_036_854_774_784, still an Int.
        #expect(BandView.clock(Double(Int.max).nextDown) == "153722867280912913:04")
    }

    @Test func negativeZeroKeepsTheOrdinaryZeroClock() {
        #expect(BandView.clock(-0.0) == "0:00")
    }
}
