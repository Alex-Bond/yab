import AppKit
import Testing
@testable import Fast

struct CaptureSwipeTests {
    @Test(arguments: [-1.0, 1.0])
    func deliberateSwipeDismissesInEitherDirection(direction: Double) {
        var swipe = CaptureSwipe()
        swipe.begin()
        for _ in 0..<10 { swipe.move(x: direction * 8, y: 1) }
        #expect(swipe.dismisses(width: 300))
    }

    @Test func shortSwipeReturns() {
        var swipe = CaptureSwipe()
        swipe.begin()
        swipe.move(x: 35, y: 2)
        #expect(swipe.axis == .horizontal)
        #expect(!swipe.dismisses(width: 300))
    }

    @Test func verticalScrollStaysVerticalEvenIfItTurnsSideways() {
        var swipe = CaptureSwipe()
        swipe.begin()
        swipe.move(x: 1, y: 12)
        swipe.move(x: 200, y: 0)
        #expect(swipe.axis == .vertical)
        #expect(!swipe.dismisses(width: 300))
    }

    @Test func returningToTheStartDoesNotDismiss() {
        var swipe = CaptureSwipe()
        swipe.begin()
        swipe.move(x: 100, y: 0)
        swipe.move(x: -95, y: 0)
        #expect(!swipe.dismisses(width: 300))
    }

    @Test func freshGestureDoesNotInheritPreviousTravel() {
        var swipe = CaptureSwipe()
        swipe.begin()
        swipe.move(x: 100, y: 0)
        swipe.begin()
        swipe.move(x: 10, y: 0)
        #expect(!swipe.dismisses(width: 300))
    }

    @Test func unownedOrAmbiguousMovementDoesNotDismiss() {
        var swipe = CaptureSwipe()
        swipe.move(x: 100, y: 0)
        #expect(!swipe.dismisses(width: 300))
        swipe.begin()
        swipe.move(x: 100, y: 100)
        #expect(!swipe.dismisses(width: 300))
    }
}
