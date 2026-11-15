import AppKit
import Testing
@testable import Fast

struct ColumnDragScrollTests {
    let room = CGRect(x: 8, y: 240, width: 220, height: 500)

    @Test func onlyTheVisibleRowsHaveScrollingEdges() {
        #expect(ColumnDragScroll.velocity(at: CGPoint(x: 110, y: 248), in: room) < -200)
        #expect(ColumnDragScroll.velocity(at: CGPoint(x: 110, y: 732), in: room) > 200)
        for point in [CGPoint(x: 110, y: 239), CGPoint(x: 110, y: 741), CGPoint(x: 229, y: 248), CGPoint(x: 110, y: 490)] {
            #expect(ColumnDragScroll.velocity(at: point, in: room) == 0)
        }
    }

    @Test func travelKeepsTheHeldRowUnderTheHandAsTheListMoves() {
        #expect(ColumnDragScroll.travel(hand: -400, offset: 1100, beganAt: 1350) == -650)
        #expect(ColumnDragScroll.travel(hand: 400, offset: 1600, beganAt: 1350) == 650)
        #expect(ColumnDragScroll.travel(hand: -400, offset: 1350, beganAt: 1350) == -400)
    }
}

@MainActor
struct ColumnDragScrollPhysicalTests {
    @Test(arguments: [false, true], [false, true])
    func productionScrollKeepsOwnerAndCleansUp(_ folder: Bool, _ cancelled: Bool) throws {
        try ColumnDragScrollOwnershipTests().exerciseLargeScroll(folder: folder, cancelled: cancelled) { page, offset in
            let before = page.offset
            let moved = page.scrollHeldRows(by: offset - before)
            #expect(abs(moved - (offset - before)) < 1)
            #expect(abs(page.offset - offset) < 1)
        }
    }
}
