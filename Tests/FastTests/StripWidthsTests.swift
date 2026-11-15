import CoreGraphics
import Testing
@testable import Fast

struct StripWidthsTests {
    private func solve(_ room: CGFloat, outer: Int = 3, inner: Int = 2,
                       active: Bool = false) -> StripWidths {
        StripWidths.solve(room: room, outer: outer, inner: inner, fixed: 50,
                          activeInside: active)
    }

    @Test func givesFolderRoomFirst() {
        let full = solve(50 + 5 * 186)
        #expect(full.inner == 186 && full.outer == 186)
        let first = solve(50 + 3 * 186 + 2 * 100)
        #expect(first.inner == 100 && first.outer == 186)
        let second = solve(50 + 3 * 120 + 2 * 80)
        #expect(second.inner == 80 && second.outer == 120)
    }

    @Test func givesUpTitlesInOrder() {
        let inner = solve(50 + 3 * 80 + 2 * 50)
        #expect(inner.inner == 50 && inner.outer == 80)
        let outer = solve(50 + 3 * 50 + 2 * 36)
        #expect(outer.inner == 36 && outer.outer == 50)
        let scrolling = solve(1)
        #expect(scrolling.inner == 36 && scrolling.outer == 36)
        #expect(scrolling.content > 1)
    }

    @Test func activeInsideKeepsTitle() {
        let widths = solve(50 + 3 * 36 + 80 + 36, active: true)
        #expect(widths.activeInner == 80)
        #expect(widths.inner == 36)
        #expect(widths.outer == 36)
    }

    @Test func activeOutsideKeepsTitle() {
        let widths = StripWidths.solve(room: 50 + 80 + 2 * 36 + 2 * 36,
                                       outer: 3, inner: 2, fixed: 50, activeOutside: true)
        #expect(widths.activeOuter == 80)
        #expect(widths.outer == 36)
        #expect(widths.inner == 36)
    }

    @Test func openingOnlyChangesFolderWhenThereIsRoom() {
        let shut = StripWidths.solve(room: 800, outer: 3, inner: 0, fixed: 50)
        let open = StripWidths.solve(room: 800, outer: 2, inner: 2, fixed: 80)
        #expect(shut.outer == 186 && open.outer == 186)
        #expect(open.inner < 186)
        #expect(open.content <= 800)
    }

    @Test func severalFoldersShareInnerWidth() {
        let widths = solve(50 + 3 * 186 + 4 * 100, inner: 4)
        #expect(widths.inner == 100)
        #expect(widths.outer == 186)
    }
}
