import AppKit
import Testing
@testable import Fast

/// A tip goes on its own side while there is room there, on the other side
/// when there isn't, and never over the view it names.
struct KeyTipPlaceTests {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let size = NSSize(width: 70, height: 24)

    @Test @MainActor func belowWhereThereIsRoom() {
        let dot = NSRect(x: 200, y: 400, width: 20, height: 28)
        let (at, side) = KeyTip.place(size, by: dot, side: .below, on: screen)
        #expect(side == .below)
        #expect(at.y + size.height <= dot.minY)
    }

    /// The column's foot at the screen's bottom: the space dots' tip went
    /// up over the dots themselves.
    @Test @MainActor func aboveAtTheScreensBottom() {
        let dot = NSRect(x: 200, y: 8, width: 20, height: 28)
        let (at, side) = KeyTip.place(size, by: dot, side: .below, on: screen)
        #expect(side == .above)
        #expect(at.y >= dot.maxY)
    }

    @Test @MainActor func belowAtTheScreensTop() {
        let door = NSRect(x: 200, y: screen.maxY - 30, width: 28, height: 28)
        let (at, side) = KeyTip.place(size, by: door, side: .above, on: screen)
        #expect(side == .below)
        #expect(at.y + size.height <= door.minY)
    }

    @Test @MainActor func rightWhenTheLeftIsOffTheScreen() {
        let door = NSRect(x: 4, y: 400, width: 28, height: 28)
        let (at, side) = KeyTip.place(size, by: door, side: .left, on: screen)
        #expect(side == .right)
        #expect(at.x >= door.maxX)
    }

    /// No room on either side: it stays on its own, kept on the screen.
    @Test @MainActor func keptOnTheScreenWhenNeitherFits() {
        let tall = NSRect(x: 200, y: 10, width: 28, height: screen.height - 20)
        let (at, side) = KeyTip.place(size, by: tall, side: .below, on: screen)
        #expect(side == .below)
        #expect(at.y >= screen.minY)
    }
}
