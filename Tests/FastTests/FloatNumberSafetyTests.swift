import Foundation
import Testing
@testable import Fast

@MainActor
struct FloatNumberSafetyTests {
    private func progress(error: Double) -> Floater.Playhead? {
        Floater.Playhead([0.5, true, 30.0, 60.0, 1.25, 1920.0, 1080.0,
                          true, false, false, -1.0, 0.0, false, 20.0, 45.0, error] as [Any])
    }

    @Test func outOfRangeMediaErrorsDoNotTrap() {
        for value in [Double(Int.max), Double(Int.min).nextDown,
                      Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                      Double.infinity, -Double.infinity, Double.nan, 1.5] {
            #expect(progress(error: value)?.error == 0)
        }
    }

    @Test func validMediaErrorsAndOtherProgressFieldsSurvive() throws {
        for code in 0...4 {
            let head = try #require(progress(error: Double(code)))
            #expect(head.error == code)
            #expect(head.through == 0.5 && head.playing && head.moving)
            #expect(head.time == 30 && head.length == 60 && head.rate == 1.25)
            #expect(head.width == 1920 && head.height == 1080)
            #expect(head.loaded?.from == 20 && head.loaded?.to == 45)
        }
        #expect(Floater.Playhead(nil) == nil)
    }

    @Test func veryLargeWholeRatesAreFormattedWithoutIntegerConversion() {
        #expect(Floater.said(1e19) == "10000000000000000000×")
        #expect(Floater.said(-1e19) == "-10000000000000000000×")
        #expect(Floater.said(1.0000001) == "1×")
        #expect(Floater.said(1.25) == "1.25×")
        #expect(Floater.said(1.5) == "1.5×")
        #expect(Floater.said(0) == "0×")
    }

    @Test func nonfiniteRatesAndScalingOverflowUseTheDefaultLabel() {
        for rate in [Double.nan, .infinity, -.infinity,
                     .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            #expect(Floater.said(rate) == "1×")
        }
    }
}
