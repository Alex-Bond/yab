import CoreGraphics
import Testing
@testable import Fast

/// The rows moving for a row held in the column (ColumnHand.shift), drawn on
/// every frame of a drag from the drag's indices into the list as it is now.
@Suite struct ColumnHandShiftTests {
    @Test func rowsMakeRoomForTheHeldOne() {
        // Held from 1 to 3: rows 2 and 3 go up a step, 0 and 4 stay.
        #expect([0, 1, 2, 3, 4].map { ColumnHand.shift($0, from: 1, to: 3, rows: nil, step: 10) } == [0, 0, -10, -10, 0])
        // A pair counted as one row: tabs 1 and 2 are row 1.
        let rows = [0, 1, 1, 2, 3]
        #expect([0, 1, 2, 3, 4].map { ColumnHand.shift($0, from: 0, to: 3, rows: rows, step: 10) } == [0, -10, -10, -10, 0])
    }

    /// Crash #45 (0.35.0): a list gone shorter than the drag's indices, a tab
    /// closed or put away while one is held, trapped reading past its end.
    @Test func aListShorterThanTheDragIsReadToItsEnd() {
        #expect(ColumnHand.shift(0, from: 4, to: 0, rows: [0, 1], step: 10) == 10)
        #expect(ColumnHand.shift(5, from: 4, to: 6, rows: [0, 1], step: 10) == 0)
        #expect(ColumnHand.shift(0, from: 2, to: 3, rows: [], step: 10) == 0)
    }
}
