import AppKit
import Testing
@testable import Fast

// The floating window taken to another display: carried there by a drag
// and let go of over the edge the displays share, or flicked on from a
// corner at that edge. It only ever rests in a corner. A 14-inch MacBook Pro's screen, its menu bar (37 under the
// notch) and Dock off the visible part, and a 1920×1080 display beside it
// on the right with the tops level, on the left with the bottoms level,
// or above it. With separate Spaces, the default, the other display has a
// menu bar of its own; spanning one Space, only the laptop has one.
struct FloatAcrossTests {
    static let laptop = FloatPark.Screen(
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visible: NSRect(x: 0, y: 75, width: 1512, height: 870)
    )
    static let right = FloatPark.Screen(
        frame: NSRect(x: 1512, y: -98, width: 1920, height: 1080),
        visible: NSRect(x: 1512, y: -98, width: 1920, height: 1055)
    )
    static let left = FloatPark.Screen(
        frame: NSRect(x: -1920, y: 0, width: 1920, height: 1080),
        visible: NSRect(x: -1920, y: 0, width: 1920, height: 1055)
    )
    static let above = FloatPark.Screen(
        frame: NSRect(x: -204, y: 982, width: 1920, height: 1080),
        visible: NSRect(x: -204, y: 982, width: 1920, height: 1055)
    )
    static let below = FloatPark.Screen(
        frame: NSRect(x: -204, y: -1080, width: 1920, height: 1080),
        visible: NSRect(x: -204, y: -1080, width: 1920, height: 1055)
    )
    static let spanning = FloatPark.Screen(
        frame: NSRect(x: 1512, y: -98, width: 1920, height: 1080),
        visible: NSRect(x: 1512, y: -98, width: 1920, height: 1080)
    )
    // Beside it on the right, its top 202 under the laptop's, or its
    // bottom 200 over the laptop's.
    static let lowRight = FloatPark.Screen(
        frame: NSRect(x: 1512, y: -300, width: 1920, height: 1080),
        visible: NSRect(x: 1512, y: -300, width: 1920, height: 1055)
    )
    static let highRight = FloatPark.Screen(
        frame: NSRect(x: 1512, y: 200, width: 1920, height: 1080),
        visible: NSRect(x: 1512, y: 200, width: 1920, height: 1055)
    )
    // Above, over the laptop's right end by only 512.
    static let aside = FloatPark.Screen(
        frame: NSRect(x: 1000, y: 982, width: 1920, height: 1080),
        visible: NSRect(x: 1000, y: 982, width: 1920, height: 1055)
    )
    static func window(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x, y: y, width: 440, height: 247) }
    @Test func letGoOverASharedEdgeGoesToACornerOfOneDisplay() {
        // Separate Spaces show a window on one display only, so the rest of
        // one let go of across the edge would be cut off. It goes to the
        // nearest corner of the display showing most of it.
        let screens = [Self.laptop, Self.right]
        #expect(FloatPark.settle(Self.window(1512 - 140, 300), in: screens) == .inside(NSPoint(x: 1528, y: -82)))
        #expect(FloatPark.settle(Self.window(1512 - 300, 300), in: screens) == .inside(NSPoint(x: 1056, y: 91)))
        #expect(FloatPark.settle(Self.window(-300, 300), in: [Self.laptop, Self.left]) == .inside(NSPoint(x: -456, y: 16)))
        // Up: under the laptop's menu bar is no place to stay either.
        #expect(FloatPark.settle(Self.window(900, 900), in: [Self.laptop, Self.above]) == .inside(NSPoint(x: 1260, y: 998)))
        #expect(FloatPark.settle(Self.window(900, 760), in: [Self.laptop, Self.above]) == .inside(NSPoint(x: 1056, y: 682)))
        // In a corner already, it stays.
        #expect(FloatPark.settle(Self.window(1528, -82), in: screens) == .stay)
    }

    @Test func letGoWithThePointerAcrossGoesToThePointersDisplay() {
        // Carried slowly, 140 of it over: separate Spaces show it cut off
        // at the edge. The pointer across says it was being taken there.
        let screens = [Self.laptop, Self.right]
        #expect(FloatPark.settle(Self.window(1512 - 300, 300), pointer: NSPoint(x: 1530, y: 400), in: screens)
            == .inside(NSPoint(x: 1528, y: -82)))
        #expect(FloatPark.settle(Self.window(1512 - 300, 300), pointer: NSPoint(x: 1400, y: 400), in: screens)
            == .inside(NSPoint(x: 1056, y: 91)))
        // Back the other way, and up.
        #expect(FloatPark.settle(Self.window(1512 - 150, -82), pointer: NSPoint(x: 1500, y: 0), in: screens)
            == .inside(NSPoint(x: 1056, y: 91)))
        #expect(FloatPark.settle(Self.window(900, 760), pointer: NSPoint(x: 1000, y: 990), in: [Self.laptop, Self.above])
            == .inside(NSPoint(x: 1260, y: 998)))
    }

    @Test func twoFingersCarryingItOverASharedSideGoOnSlowOrQuick() {
        let screens = [Self.laptop, Self.right]
        func land(_ to: NSRect, _ velocity: CGVector = .zero, from start: NSRect = Self.window(16, 91)) -> FloatHand.Aim? {
            FloatHand.landing(to, from: start, swipe: CGVector(dx: to.minX - start.minX, dy: to.minY - start.minY),
                              velocity: velocity, screens: screens)
        }
        // Slowly, 60 of it over: on to the next display, where it went to
        // this one's corner at that side before.
        #expect(land(Self.window(1512 - 380, 91)) == .glide(NSPoint(x: 1528, y: -82)))
        // 10 over is not over: this display's corner on that side.
        #expect(land(Self.window(1512 - 430, 91)) == .glide(NSPoint(x: 1056, y: 91)))
        // Speed alone cannot skip the starting display's corner.
        #expect(land(Self.window(900, 91), CGVector(dx: 2000, dy: 0)) == .glide(NSPoint(x: 1056, y: 91)))
        // Over, but the fingers were bringing it back.
        #expect(land(Self.window(1512 - 400, 91), CGVector(dx: -6000, dy: 0), from: Self.window(600, 91))
            == .glide(NSPoint(x: 16, y: 91)))
    }

    @Test func fastThrowFromBottomStopsAtThisDisplaysTopCorner() {
        let start = Self.window(1056, 91)
        let moved = Self.window(1058, 343)
        #expect(FloatHand.landing(moved, from: start, swipe: CGVector(dx: 2, dy: 252),
                                  velocity: CGVector(dx: 26, dy: 3244), screens: [Self.laptop, Self.above])
            == .glide(NSPoint(x: 1056, y: 682)))
    }

    @Test func aFlickOnFromASharedSidePassesToTheNextDisplaysCorner() {
        let beside = [Self.laptop, Self.right]
        let right = CGVector(dx: 120, dy: 0), left = CGVector(dx: -120, dy: 0)
        // From the corner at the shared side, or past it: to the nearest
        // corner on the near side across.
        #expect(FloatPark.passed(Self.window(1056, 91), toward: right, in: beside) == NSPoint(x: 1528, y: -82))
        #expect(FloatPark.passed(Self.window(1200, 91), toward: right, in: beside) == NSPoint(x: 1528, y: -82))
        // And back.
        #expect(FloatPark.passed(Self.window(1528, -82), toward: left, in: beside) == NSPoint(x: 1056, y: 91))
        // From elsewhere, a flick reaches a corner first; at an outer side
        // it tucks.
        #expect(FloatPark.passed(Self.window(600, 91), toward: right, in: beside) == nil)
        #expect(FloatPark.passed(Self.window(1056, 91), toward: CGVector(dx: 120, dy: 100), in: beside) == nil)
        #expect(FloatPark.passed(Self.window(2976, -82), toward: right, in: beside) == nil)
        #expect(FloatPark.passed(Self.window(1056, 91), toward: right, in: [Self.laptop]) == nil)
        #expect(FloatPark.passed(Self.window(16, 91), toward: left, in: [Self.laptop, Self.left]) == NSPoint(x: -456, y: 16))
        let lower = FloatPark.Screen(frame: NSRect(x: 1512, y: -500, width: 1920, height: 1080),
                                     visible: NSRect(x: 1512, y: -500, width: 1920, height: 1055))
        #expect(FloatPark.passed(Self.window(1056, 91), toward: right, in: [Self.laptop, lower]) == NSPoint(x: 1528, y: 555 - 16 - 247))
        // Up and down from a corner, to the nearest corner there.
        let stacked = [Self.laptop, Self.above]
        #expect(FloatPark.passed(Self.window(1056, 682), toward: CGVector(dx: 0, dy: 120), in: stacked) == NSPoint(x: 1260, y: 998))
        #expect(FloatPark.passed(Self.window(1260, 998), toward: CGVector(dx: 0, dy: -120), in: stacked) == NSPoint(x: 1056, y: 682))
    }

    @Test func aDiagonalAtASharedSideMeansACornerAsAtAnOuterOne() {
        // 27 degrees off level is a diagonal to corner(): the top right
        // corner, not the next display. The same up and down.
        let beside = [Self.laptop, Self.right], stacked = [Self.laptop, Self.above]
        #expect(FloatPark.passed(Self.window(1056, 91), toward: CGVector(dx: 120, dy: 60), in: beside) == nil)
        #expect(FloatPark.passed(Self.window(900, 682), toward: CGVector(dx: 60, dy: 120), in: stacked) == nil)
        #expect(FloatHand.aim(CGVector(dx: 120, dy: 60), from: Self.window(1056, 91), settled: Self.window(1056, 91),
                              screens: beside) == .glide(NSPoint(x: 1056, y: 682)))
        // Already in that corner, it goes on over, as an outer side tucks.
        #expect(FloatPark.passed(Self.window(1056, 682), toward: CGVector(dx: 120, dy: 60), in: beside) == NSPoint(x: 1528, y: 694))
        #expect(FloatHand.aim(CGVector(dx: 120, dy: 60), from: Self.window(2976, 694), settled: Self.window(2976, 694),
                              screens: beside) == .tuck(.right))
    }

    @Test func aSecondFlickDuringTheFirstGlideGoesOnFromWhereItWasGoing() {
        // The first flick glides it toward the laptop's bottom right, 1056;
        // the second lands at 1040, 16 short, which stops the glide, and
        // the window leans after the fingers before they lift.
        let beside = [Self.laptop, Self.right], way = CGVector(dx: 250, dy: 0)
        let dock = Self.window(1056, 91), stopped = Self.window(1040, 91)
        for leaned in [Self.window(1068, 91), Self.window(1084, 91)] {
            #expect(FloatHand.aim(way, from: dock, settled: leaned, screens: beside) == .glide(NSPoint(x: 1528, y: -82)))
            // Judged from where the glide stopped, it goes to the corner.
            #expect(FloatHand.aim(way, from: stopped, settled: leaned, screens: beside) == .glide(NSPoint(x: 1056, y: 91)))
        }
        // At an outer side the same quick second flick tucks.
        let far = Self.window(2976, -82)
        #expect(FloatHand.aim(way, from: far, settled: far, screens: beside) == .tuck(.right))
    }
}
