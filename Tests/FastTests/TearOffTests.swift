import Foundation
import Testing
@testable import Fast

// A tab dragged out of its window (TearOff): when it comes away, where it
// goes in when let go over another window's tabs, and where a new window
// opens when let go over nothing.
struct TearOffTests {
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func comesAwayPastTheEdgeAndBackAtIt() {
        // Inside, and within Chrome's 15 points of the edge: still in.
        #expect(!TearRules.outside(CGPoint(x: 500, y: 400), of: frame, torn: false))
        #expect(!TearRules.outside(CGPoint(x: 90, y: 400), of: frame, torn: false))
        #expect(!TearRules.outside(CGPoint(x: 500, y: 714), of: frame, torn: false))
        // Past them, on any side: out.
        #expect(TearRules.outside(CGPoint(x: 84, y: 400), of: frame, torn: false))
        #expect(TearRules.outside(CGPoint(x: 500, y: 716), of: frame, torn: false))
        #expect(TearRules.outside(CGPoint(x: 916, y: 400), of: frame, torn: false))
        // Out, it stays out until the hand is back inside the window itself.
        #expect(TearRules.outside(CGPoint(x: 90, y: 400), of: frame, torn: true))
        #expect(!TearRules.outside(CGPoint(x: 101, y: 400), of: frame, torn: true))
    }

    /// Five rows down a column, 32 high with 2 between, from y 100.
    func column(from first: Int = 0) -> [TearRules.Row] {
        (0..<5).map { i in
            TearRules.Row(id: UUID(), frame: CGRect(x: 8, y: 100 + CGFloat(i) * 34, width: 220, height: 32),
                          index: first + i, through: first + i)
        }
    }

    @Test func columnGoesInBeforeTheRowItIsOverTheTopHalfOf() {
        let rows = column(from: 2)
        // Over the first row's top half: before it, the line just above it.
        var landing = TearRules.landing(at: CGPoint(x: 50, y: 105), rows: rows, axis: .column, count: 7, floor: 2, ceiling: 7)
        #expect(landing.index == 2)
        #expect(landing.like == rows[0].id)
        #expect(landing.line == CGRect(x: 8, y: 98, width: 220, height: 2))
        // Over the third's bottom half: before the fourth, the line in the
        // gap between the two.
        landing = TearRules.landing(at: CGPoint(x: 50, y: 100 + 2 * 34 + 20), rows: rows, axis: .column, count: 7, floor: 2, ceiling: 7)
        #expect(landing.index == 5)
        #expect(landing.like == rows[3].id)
        #expect(landing.line == CGRect(x: 8, y: 100 + 3 * 34 - 2, width: 220, height: 2))
        // Below them all: at the end, after the last.
        landing = TearRules.landing(at: CGPoint(x: 50, y: 900), rows: rows, axis: .column, count: 7, floor: 2, ceiling: 7)
        #expect(landing.index == 7)
        #expect(landing.like == rows[4].id)
        #expect(landing.line?.minY == CGFloat(100 + 4 * 34 + 32))
    }

    @Test func rowsComeInAnyOrderAndAPairIsOneRow() {
        var rows = column()
        // The second row stands for a split's two tabs, 1 and 2.
        rows[1] = TearRules.Row(id: rows[1].id, frame: rows[1].frame, index: 1, through: 2)
        rows[2].index = 3; rows[2].through = 3
        rows[3].index = 4; rows[3].through = 4
        rows[4].index = 5; rows[4].through = 5
        // After the pair: past both its tabs, never between them.
        let below = TearRules.landing(at: CGPoint(x: 50, y: 100 + 34 + 30), rows: rows.reversed(), axis: .column, count: 6, floor: 0, ceiling: 6)
        #expect(below.index == 3)
        let last = TearRules.landing(at: CGPoint(x: 50, y: 900), rows: [rows[1]], axis: .column, count: 6, floor: 0, ceiling: 6)
        #expect(last.index == 3)
    }

    @Test func stripGoesInByTheMiddleOfEachPill() {
        let rows = (0..<3).map { i in
            TearRules.Row(id: UUID(), frame: CGRect(x: 80 + CGFloat(i) * 150, y: 8, width: 146, height: 28), index: i, through: i)
        }
        var landing = TearRules.landing(at: CGPoint(x: 80 + 150 + 100, y: 20), rows: rows, axis: .strip, count: 3, floor: 0, ceiling: 3)
        #expect(landing.index == 2)
        #expect(landing.line == CGRect(x: 80 + 300 - 3, y: 8, width: 2, height: 28))
        landing = TearRules.landing(at: CGPoint(x: 10, y: 20), rows: rows, axis: .strip, count: 3, floor: 0, ceiling: 3)
        #expect(landing.index == 0)
        #expect(landing.line?.minX == 78)
    }

    @Test func aWindowWithNoTabsTakesItAtTheEnd() {
        let landing = TearRules.landing(at: CGPoint(x: 50, y: 50), rows: [], axis: .column, count: 0, floor: 0, ceiling: 0)
        #expect(landing == TearRules.Landing(index: 0, like: nil, line: nil))
    }

    @Test func aTabStaysOutOfThePinsAndAPinInThem() {
        let rows = column()
        // Three pins: a tab let go above every row still lands after them.
        let tab = TearRules.landing(at: CGPoint(x: 50, y: 0), rows: rows, axis: .column, count: 5, floor: 3, ceiling: 5)
        #expect(tab.index == 3)
        #expect(tab.line == nil)
        // A pin among two pins, past them: after the last one, no further.
        let pins = Array(rows.prefix(2))
        let pin = TearRules.landing(at: CGPoint(x: 50, y: 900), rows: pins, axis: .column, count: 5, floor: 0, ceiling: 2)
        #expect(pin.index == 2)
    }

    @Test func aTabThatCantBeKeptLandsAmongTodays() {
        let rows = column()
        // Two kept rows: a private page let go over the first isn't kept.
        let landing = TearRules.landing(at: CGPoint(x: 50, y: 105), rows: rows, axis: .column, count: 5, floor: 0, ceiling: 5,
                                        keepable: false, keptEnd: 2)
        #expect(landing.index == 2)
        #expect(landing.like == nil)
        // Over today's, it goes where it was let go.
        let today = TearRules.landing(at: CGPoint(x: 50, y: 100 + 3 * 34 + 4), rows: rows, axis: .column, count: 5, floor: 0, ceiling: 5,
                                      keepable: false, keptEnd: 2)
        #expect(today.index == 3)
        #expect(today.like == rows[3].id)
    }

    @Test func newWindowKeepsTheGrabbedPointUnderThePointer() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        // Taken 120 in and 200 down from the old window's top-left.
        let frame = TearRules.newWindow(pointer: CGPoint(x: 600, y: 700), grab: CGPoint(x: 120, y: 200),
                                        size: CGSize(width: 800, height: 600), visible: visible)
        #expect(frame == CGRect(x: 480, y: 300, width: 800, height: 600))
        #expect(frame.minX + 120 == 600 && frame.maxY - 200 == 700)
    }

    @Test func newWindowStaysOnTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        // Let go near the top-right corner: pushed back in whole.
        let corner = TearRules.newWindow(pointer: CGPoint(x: 1500, y: 940), grab: CGPoint(x: 20, y: 10),
                                         size: CGSize(width: 800, height: 600), visible: visible)
        #expect(corner == CGRect(x: 712, y: 344, width: 800, height: 600))
        // Bigger than the screen: as big as it.
        let big = TearRules.newWindow(pointer: CGPoint(x: 100, y: 100), grab: .zero,
                                      size: CGSize(width: 3000, height: 2000), visible: visible)
        #expect(big == visible)
    }

    /// A laptop's screen, and a 4K one over it, wider, its left edge
    /// 276 further left: the Mac a window over the whole top screen gave
    /// no drag out of (Oct 9).
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let top = CGRect(x: -276, y: 982, width: 1920, height: 1080)
    /// That window: the top screen's room under its menu bar, all of it.
    let whole = CGRect(x: -276, y: 982, width: 1920, height: 1050)

    @Test func theWallsAreEdgesWithNoScreenPastThem() {
        let screens = [laptop, top]
        // The top screen's right edge, its top, and its left edge.
        #expect(TearRules.walls(at: CGPoint(x: 1643, y: 1500), screens: screens) == TearRules.Walls(right: true))
        #expect(TearRules.walls(at: CGPoint(x: 600, y: 2061), screens: screens) == TearRules.Walls(top: true))
        #expect(TearRules.walls(at: CGPoint(x: -276, y: 1500), screens: screens) == TearRules.Walls(left: true))
        // Its bottom, out past the laptop's sides, and the laptop's bottom.
        #expect(TearRules.walls(at: CGPoint(x: -100, y: 982), screens: screens) == TearRules.Walls(bottom: true))
        #expect(TearRules.walls(at: CGPoint(x: 600, y: 0), screens: screens) == TearRules.Walls(bottom: true))
        // Over the laptop the pointer goes on down: no wall.
        #expect(TearRules.walls(at: CGPoint(x: 600, y: 982), screens: screens) == TearRules.Walls())
        #expect(TearRules.walls(at: CGPoint(x: 600, y: 1500), screens: screens) == TearRules.Walls())
    }

    /// A drag along `moves` (the hand's, y up) from `start`, the pointer
    /// held on the screens as a pointer is: the hand where it ends.
    func drag(from start: CGPoint, _ moves: [CGVector], screens: [CGRect], window: CGRect) -> (hand: CGPoint, torn: Bool) {
        var pointer = start
        var push = CGVector.zero
        var torn = false
        for move in moves {
            var next = CGPoint(x: pointer.x + move.dx, y: pointer.y + move.dy)
            // Kept on a screen, a point inside a far edge.
            if !screens.contains(where: { $0.contains(next) }) {
                let screen = screens.first { $0.insetBy(dx: -1, dy: -1).contains(pointer) } ?? screens[0]
                next.x = min(max(next.x, screen.minX), screen.maxX - 1)
                next.y = min(max(next.y, screen.minY), screen.maxY - 1)
            }
            push = TearRules.push(push, from: pointer, to: next, delta: move, screens: screens, torn: torn)
            pointer = next
            let hand = CGPoint(x: pointer.x + push.dx, y: pointer.y + push.dy)
            torn = TearRules.outside(hand, of: window, torn: torn)
        }
        return (CGPoint(x: pointer.x + push.dx, y: pointer.y + push.dy), torn)
    }

    @Test func aWindowFillingItsScreenLetsATabOutAtTheScreensEdge() {
        let screens = [laptop, top]
        // From the column across the page to the right edge: held there.
        let start = CGPoint(x: -200, y: 1700)
        let across = Array(repeating: CGVector(dx: 40, dy: 0), count: 46)
        var drag = self.drag(from: start, across, screens: screens, window: whole)
        #expect(!drag.torn)
        // The hand on 10 more against it: still in, Chrome's 15 not reached.
        drag = self.drag(from: start, across + [CGVector(dx: 10, dy: 0)], screens: screens, window: whole)
        #expect(!drag.torn)
        // 20 more: out, the hand 20 past where the pointer stands.
        drag = self.drag(from: start, across + [CGVector(dx: 10, dy: 0), CGVector(dx: 10, dy: 0)], screens: screens, window: whole)
        #expect(drag.torn)
        #expect(drag.hand.x >= whole.maxX + TearRules.reach)
        // Along the wall it stays out; 10 back in it is still out; all the
        // way back, in.
        let pushed = across + [CGVector(dx: 20, dy: 0)]
        drag = self.drag(from: start, pushed + [CGVector(dx: 0, dy: -60)], screens: screens, window: whole)
        #expect(drag.torn)
        drag = self.drag(from: start, pushed + [CGVector(dx: -10, dy: 0)], screens: screens, window: whole)
        #expect(drag.torn)
        drag = self.drag(from: start, pushed + [CGVector(dx: -10, dy: 0), CGVector(dx: -30, dy: 0)], screens: screens, window: whole)
        #expect(!drag.torn)
    }

    @Test func aHandAtTheWallThatComesBackStartsOver() {
        let screens = [laptop, top]
        let start = CGPoint(x: 1600, y: 1700)
        // 12 into the wall, a step back off it, 12 in again: never 15.
        let moves = [CGVector(dx: 55, dy: 0), CGVector(dx: -10, dy: 0), CGVector(dx: 22, dy: 0)]
        #expect(!drag(from: start, moves, screens: screens, window: whole).torn)
    }

    @Test func aWindowWithRoomBesideItIsLeftAsBefore() {
        // Half the top screen: past its edge the pointer goes on, and
        // nothing is pushed.
        let half = CGRect(x: -276, y: 982, width: 900, height: 1050)
        let drag = self.drag(from: CGPoint(x: -200, y: 1700), Array(repeating: CGVector(dx: 40, dy: 0), count: 21),
                             screens: [laptop, top], window: half)
        #expect(drag.torn)
        #expect(drag.hand == CGPoint(x: 640, y: 1700))
    }

    @Test func aTabOutOfAWindowFillingItsScreenOpensAWindowOfANewOnesSize() {
        let visible = whole
        let fresh = CGSize(width: 1080, height: 730)
        #expect(TearRules.size(leaving: whole.size, visible: visible, fresh: fresh) == fresh)
        // A window short of filling it keeps its own size.
        #expect(TearRules.size(leaving: CGSize(width: 1400, height: 900), visible: visible, fresh: fresh)
                == CGSize(width: 1400, height: 900))
        // On a screen smaller than a new window, as big as the screen.
        let small = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(TearRules.size(leaving: small.size, visible: small, fresh: fresh) == small.size)
    }

    @Test func thePictureIsAThirdWithinBounds() {
        #expect(abs(TearRules.scale(for: CGSize(width: 1000, height: 700)) - 0.3) < 0.0001)
        #expect(abs(TearRules.scale(for: CGSize(width: 600, height: 400)) * 600 - 240) < 0.001)
        #expect(abs(TearRules.scale(for: CGSize(width: 2000, height: 1200)) * 2000 - 360) < 0.001)
    }

    // The Dock's window over a whole screen takes no tab; its row, and any
    // other app's window, still do.
    @Test func theDocksWholeScreenWindowIsSeeThrough() {
        let screens = [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: 2560, y: 0, width: 2560, height: 1440)]
        #expect(TearRules.seeThrough(bundle: "com.apple.dock", frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440), screens: screens))
        #expect(!TearRules.seeThrough(bundle: "com.apple.dock", frame: CGRect(x: 800, y: 1360, width: 900, height: 80), screens: screens))
        #expect(!TearRules.seeThrough(bundle: "com.example.app", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), screens: screens))
    }
}
