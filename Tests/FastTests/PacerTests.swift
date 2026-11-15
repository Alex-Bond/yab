import Foundation
import Testing
@testable import Fast

struct PacerTests {
    @Test func pauseAfterLastCallbackIsStillVisible() {
        // The old metric sees only 16 ms gaps, then the end timer beats the
        // next callback after main wakes. The missing tail is the real delay.
        let window = Pacer.callbackWindow(start: 10, end: 11.2, delivered: [10.202, 10.218, 10.234, 10.25])
        #expect(abs(window.trailing - 0.95) < 0.000001)
        #expect(abs(window.worst - 0.95) < 0.000001)
    }
    @Test func noCallbacksIsNotZeroDelay() {
        let window = Pacer.callbackWindow(start: 10, end: 11, delivered: [])
        #expect(window.worst == 1)
        #expect(window.duration == 1)
    }
    @Test func leadingAndInteriorPausesAreRetained() {
        let leading = Pacer.callbackWindow(start: 0, end: 1, delivered: [0.8, 0.9])
        #expect(leading.worst == 0.8)
        let interior = Pacer.callbackWindow(start: 0, end: 1, delivered: [0.1, 0.9])
        #expect(interior.worst == 0.8)
    }
}
