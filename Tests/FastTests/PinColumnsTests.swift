import CoreGraphics
import Testing
@testable import Fast

// The pins' grid goes across as Arc's Favorites do (feedback #341,
// evals/pins-per-row/arc_grid.py): four at most however wide the column,
// three below a 240 pt column, and the rows kept even.
@MainActor
@Suite
struct PinColumnsTests {
    /// Arc's twelve favorites, measured from a 180 to a 500 pt sidebar,
    /// and two across at its narrowest, 164 (evals/side-width/arc_min.py).
    @Test func twelveGoAcrossAsArcs() {
        let arc: [(CGFloat, Int)] = [(164, 2), (189, 3), (200, 3), (220, 3), (240, 4), (260, 4), (300, 4), (360, 4), (400, 4), (475, 4)]
        for (width, columns) in arc {
            #expect(SideBar.pinColumns(12, width: width) == columns, "width \(width)")
        }
    }

    /// Six pins are two rows of three, never one row of six; in a column
    /// near Arc's narrowest, three rows of two, as Arc has them there.
    @Test func sixAreTwoRowsOfThree() {
        for width in stride(from: Metrics.sideMin, through: Metrics.sideMax, by: 1) {
            #expect(SideBar.pinColumns(6, width: width) == (width < 173 ? 2 : 3), "width \(width)")
        }
    }

    @Test func neverMoreThanFourAcross() {
        for count in 1...20 {
            for width in stride(from: Metrics.sideMin, through: Metrics.sideMax, by: 5) {
                let columns = SideBar.pinColumns(count, width: width)
                #expect(columns >= 1 && columns <= 4)
                #expect(columns <= count)
                let rows = (count + columns - 1) / columns
                // Even rows: the last one is short by less than a row.
                #expect(rows * columns - count < rows, "\(count) at \(width)")
            }
        }
    }

    /// A few pins share the row between them, as before.
    @Test func fewPinsFillOneRow() {
        #expect(SideBar.pinColumns(2, width: 300) == 2)
        #expect(SideBar.pinColumns(3, width: 475) == 3)
        #expect(SideBar.pinColumns(4, width: 475) == 4)
        #expect(SideBar.pinColumns(5, width: 475) == 3)
    }
}
