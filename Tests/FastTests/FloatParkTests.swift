import AppKit
import Testing
@testable import Fast

// The floating video let go of near a side of the screen: tucked behind it,
// back inside, or left be. One 1440×900 screen with the menu bar and Dock
// taken off its visible part, and a second display beside or above it.
struct FloatParkTests {
    static let main = FloatPark.Screen(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visible: NSRect(x: 0, y: 70, width: 1440, height: 800)
    )
    static let beside = FloatPark.Screen(
        frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        visible: NSRect(x: 1440, y: 0, width: 1920, height: 1055)
    )
    static let above = FloatPark.Screen(
        frame: NSRect(x: 0, y: 900, width: 1440, height: 900),
        visible: NSRect(x: 0, y: 900, width: 1440, height: 875)
    )
    static func window(_ x: CGFloat, _ y: CGFloat = 200) -> NSRect { NSRect(x: x, y: y, width: 440, height: 247) }

    @Test func anywhereGoesToTheNearestCorner() {
        #expect(FloatPark.settle(Self.window(400), in: [Self.main]) == .inside(NSPoint(x: 16, y: 86)))
        #expect(FloatPark.settle(Self.window(900, 500), in: [Self.main]) == .inside(NSPoint(x: 984, y: 607)))
        #expect(FloatPark.settle(Self.window(984, 607), in: [Self.main]) == .stay)
    }

    @Test func freePlacementStaysWhereReleasedEvenNearEdges() {
        for frame in [Self.window(400), Self.window(20), Self.window(1000, 623)] {
            #expect(FloatPark.settle(frame, in: [Self.main], snapToEdges: false) == .stay)
            #expect(FloatPark.magnetic(frame, in: [Self.main], snapToEdges: false) == frame.origin)
        }
    }

    @Test func freePlacementBringsOnlyTheClippedAxisInside() {
        #expect(FloatPark.settle(Self.window(1100, 350), in: [Self.main], snapToEdges: false)
                == .inside(NSPoint(x: 1000, y: 350)))
        #expect(FloatPark.settle(Self.window(400, 0), in: [Self.main], snapToEdges: false)
                == .inside(NSPoint(x: 400, y: 70)))
        #expect(FloatPark.settle(Self.window(400, 700), in: [Self.main], snapToEdges: false)
                == .inside(NSPoint(x: 400, y: 623)))
    }

    @Test func freePlacementFollowsThePointerAcrossDisplays() {
        #expect(FloatPark.settle(Self.window(1200, 350), pointer: NSPoint(x: 1500, y: 400),
                                 in: [Self.main, Self.beside], snapToEdges: false)
                == .inside(NSPoint(x: 1440, y: 350)))
        #expect(FloatPark.settle(Self.window(900, 800), pointer: NSPoint(x: 1000, y: 950),
                                 in: [Self.main, Self.above], snapToEdges: false)
                == .inside(NSPoint(x: 900, y: 900)))
    }

    @Test func freePlacementStillAllowsDeliberateTucking() {
        #expect(FloatPark.settle(Self.window(1200, 350), in: [Self.main], snapToEdges: false)
                == .park(.right, NSPoint(x: 1424, y: 350)))
        #expect(FloatPark.settle(Self.window(-200, 350), in: [Self.main], snapToEdges: false)
                == .park(.left, NSPoint(x: -424, y: 350)))
        #expect(FloatPark.unparked(Self.window(1424, 350), .right, in: Self.main.visible, snapToEdges: false)
                == NSPoint(x: 984, y: 350))
    }

    @Test func aFreelyPlacedWindowAtTheEdgeHasNoTuckPresentation() {
        for x in [CGFloat(0), 8, 992, 1000] {
            #expect(FloatPark.tuckProgress(Self.window(x), in: [Self.main], snapToEdges: false) == nil)
        }
        #expect(FloatPark.tuckProgress(Self.window(1010), in: [Self.main], snapToEdges: false) != nil)
    }

    @Test func freePlacementKeepsThePositionWhenFingersLift() {
        let start = Self.window(16, 86), released = Self.window(400, 350)
        #expect(FloatHand.landing(released, from: start, swipe: CGVector(dx: 384, dy: 264),
                                  velocity: CGVector(dx: 1500, dy: 1200), screens: [Self.main], snapToEdges: false) == nil)
        #expect(FloatHand.landing(Self.window(400, 0), from: released, swipe: CGVector(dx: 0, dy: -350),
                                  velocity: .zero, screens: [Self.main], snapToEdges: false)
                == .glide(NSPoint(x: 400, y: 70)))
        #expect(FloatHand.landing(Self.window(1200, 350), from: released, swipe: CGVector(dx: 800, dy: 0),
                                  velocity: .zero, screens: [Self.main], snapToEdges: false) == .tuck(.right))
    }

    @Test func freePlacementRefitsAfterADisplayDisappearsWithoutChoosingACorner() {
        #expect(FloatPark.bounded(Self.window(1800, 350), in: Self.main.visible) == NSPoint(x: 1000, y: 350))
        #expect(FloatPark.bounded(Self.window(400, 350), in: Self.main.visible) == NSPoint(x: 400, y: 350))
    }

    @Test func heldPastAThirdGoesBehindBeforeLettingGo() {
        let screens = [Self.main]
        // 200 of 440 over the right edge or the left: behind it now.
        #expect(FloatPark.held(Self.window(1440 - 240), tucking: nil, in: screens) == .right)
        #expect(FloatPark.held(Self.window(-200), tucking: nil, in: screens) == .left)
        // 100 over is under a third: carried as ever.
        #expect(FloatPark.held(Self.window(1440 - 340), tucking: nil, in: screens) == nil)
        // Going behind, it stays until the hand draws it 40 back from a
        // third (146.7): 130 over still behind, 100 out again.
        #expect(FloatPark.held(Self.window(1440 - 310), tucking: .right, in: screens) == .right)
        #expect(FloatPark.held(Self.window(1440 - 340), tucking: .right, in: screens) == nil)
        // A side another display shares hides nothing.
        #expect(FloatPark.held(Self.window(1440 - 240), tucking: nil, in: [Self.main, Self.beside]) == nil)
    }

    @Test func aHandPushingAtAnOuterSideCarriesTheWindowOn() {
        let screens = [Self.main], frame = Self.window(1100)
        let edge = NSPoint(x: 1439.5, y: 400)
        #expect(FloatPark.pushed(0, by: 6, pointer: edge, frame: frame, in: screens) == 6)
        #expect(FloatPark.pushed(10, by: 6, pointer: edge, frame: frame, in: screens) == 16)
        #expect(FloatPark.pushed(0, by: -5, pointer: NSPoint(x: 0, y: 400), frame: Self.window(0), in: screens) == -5)
        // Away from the edge the pointer itself moves; back inward is the
        // pointer's too.
        #expect(FloatPark.pushed(0, by: 6, pointer: NSPoint(x: 1000, y: 400), frame: frame, in: screens) == 0)
        #expect(FloatPark.pushed(10, by: -4, pointer: edge, frame: frame, in: screens) == 10)
        // With a display beside, the pointer goes on over: nothing to push.
        #expect(FloatPark.pushed(0, by: 6, pointer: edge, frame: frame, in: [Self.main, Self.beside]) == 0)
    }

    @Test func aLittleOverComesBack() {
        // 100 of 440 over the right edge, under a third.
        let outcome = FloatPark.settle(Self.window(1440 - 340), in: [Self.main])
        #expect(outcome == .inside(NSPoint(x: 1440 - 16 - 440, y: 86)))
        let left = FloatPark.settle(Self.window(-100), in: [Self.main])
        #expect(left == .inside(NSPoint(x: 16, y: 86)))
    }

    @Test func arrivingQuicklyAtTheEdgeDoesNotCountPointerMovementTwice() {
        let edge = NSPoint(x: 1439.5, y: 400), frame = Self.window(1100)
        #expect(FloatPark.pushed(0, by: 116, moved: 19.4, pointer: edge, frame: frame, in: [Self.main]) == 96.6)
        #expect(FloatPark.pushed(0, by: 20, moved: 20, pointer: edge, frame: frame, in: [Self.main]) == 0)
        #expect(FloatPark.pushed(0, by: -116, moved: -19.4, pointer: NSPoint(x: 0, y: 400),
                                 frame: Self.window(0), in: [Self.main]) == -96.6)
    }

    @Test func aFastHeldThrowStopsAtTheLipAndReversesImmediately() {
        let edge = NSPoint(x: 1439.5, y: 400)
        let raw = Self.window(1600)
        let held = FloatPark.carried(raw, pointer: edge, in: [Self.main])
        #expect(held.minX == 1420)
        #expect(held.maxX > Self.main.frame.maxX)
        #expect(FloatPark.settle(held, pointer: edge, in: [Self.main]) == .park(.right, NSPoint(x: 1424, y: 200)))
        // Discard the overshoot, then reversing 30 pt follows by 30 pt.
        let reversed = FloatPark.carried(held.offsetBy(dx: -30, dy: 0), pointer: edge, in: [Self.main])
        #expect(reversed.minX == 1390)
        #expect(FloatPark.carried(Self.window(-900), pointer: NSPoint(x: 0, y: 400), in: [Self.main]).minX == -420)
        // An adjoining display remains a passable side.
        #expect(FloatPark.carried(Self.window(1600), pointer: edge, in: [Self.main, Self.beside]) == raw)
    }

    @Test func moreThanAThirdTucks() {
        let right = FloatPark.settle(Self.window(1440 - 240), in: [Self.main])
        #expect(right == .park(.right, NSPoint(x: 1440 - 16, y: 200)))
        let left = FloatPark.settle(Self.window(-200), in: [Self.main])
        #expect(left == .park(.left, NSPoint(x: -440 + 16, y: 200)))
    }


    @Test func anotherDisplayIsNoEdge() {
        let screens = [Self.main, Self.beside]
        // Mostly over into the display on the right: never tucked there,
        // but wholly onto it, as separate Spaces show it on one display.
        #expect(FloatPark.settle(Self.window(1440 - 120), in: screens) == .inside(NSPoint(x: 1456, y: 16)))
        #expect(FloatPark.settle(Self.window(16, 86), in: screens) == .stay)
        // The left side is still an edge.
        #expect(FloatPark.settle(Self.window(-200), in: screens) == .park(.left, NSPoint(x: -424, y: 200)))
    }

    @Test func aDisplayBesideButLowerLeavesTheEdge() {
        // Only where the window is counts: a short display beside the lower
        // half leaves the upper half's side an edge.
        let short = FloatPark.Screen(frame: NSRect(x: 1440, y: 0, width: 800, height: 300),
                                     visible: NSRect(x: 1440, y: 0, width: 800, height: 300))
        let high = FloatPark.settle(Self.window(1440 - 200, 600), in: [Self.main, short])
        #expect(high == .park(.right, NSPoint(x: 1424, y: 600)))
    }

    @Test func topAndBottomNeverTuck() {
        // Under the Dock: back up into the corner, 16 over it.
        #expect(FloatPark.settle(Self.window(400, 0), in: [Self.main]) == .inside(NSPoint(x: 16, y: 86)))
        // Behind the menu bar: back down.
        #expect(FloatPark.settle(Self.window(400, 700), in: [Self.main]) == .inside(NSPoint(x: 16, y: 870 - 16 - 247)))
        // A display above: over the top is a way up, but let go of there it
        // goes to a corner of the display showing most of it.
        #expect(FloatPark.settle(Self.window(400, 700), in: [Self.main, Self.above]) == .inside(NSPoint(x: 16, y: 607)))
        #expect(FloatPark.settle(Self.window(400, 800), in: [Self.main, Self.above]) == .inside(NSPoint(x: 16, y: 916)))
    }

    @Test func tuckedKeepsItsHeightInside() {
        let spot = FloatPark.parked(Self.window(1300, 800), .right, in: Self.main.visible)
        #expect(spot == NSPoint(x: 1424, y: 870 - 247))
        #expect(FloatPark.peeked(Self.window(1300, 300), .right, in: Self.main.visible) == NSPoint(x: 1424 - 28, y: 300))
        #expect(FloatPark.peeked(Self.window(-424, 300), .left, in: Self.main.visible) == NSPoint(x: -424 + 28, y: 300))
    }

    @Test func releaseNearAnEdgeGoesToACornerWithoutHiding() {
        #expect(FloatPark.settle(Self.window(20), in: [Self.main]) == .inside(NSPoint(x: 16, y: 86)))
        #expect(FloatPark.settle(Self.window(970, 620), in: [Self.main]) == .inside(NSPoint(x: 984, y: 607)))
        #expect(FloatPark.settle(Self.window(600, 90), in: [Self.main]) == .inside(NSPoint(x: 984, y: 86)))
    }

    @Test func dragFeelsTheEdgeBeforeReleaseButCanCrossIt() {
        let pulled = FloatPark.magnetic(Self.window(30), in: [Self.main])
        #expect(pulled.x > 16 && pulled.x < 30)
        #expect(FloatPark.magnetic(Self.window(-20), in: [Self.main]).x == -20)
    }

    @Test func swipeDirectionsKeepTheirMeaning() {
        let frame = Self.window(500, 250)
        let area = Self.main.visible
        #expect(FloatHand.corner(for: frame, in: area, toward: CGVector(dx: 80, dy: 0)) == NSPoint(x: 984, y: 86))
        #expect(FloatHand.corner(for: frame, in: area, toward: CGVector(dx: 0, dy: 80)) == NSPoint(x: 16, y: 607))
        #expect(FloatHand.corner(for: Self.window(984, 86), in: area, toward: CGVector(dx: 0, dy: 80)) == NSPoint(x: 984, y: 607))
        #expect(FloatHand.corner(for: frame, in: area, toward: CGVector(dx: 80, dy: 80)) == NSPoint(x: 984, y: 607))
        #expect(FloatHand.corner(for: Self.window(984, 250), in: area, toward: CGVector(dx: 80, dy: 0)) == NSPoint(x: 984, y: 86))
        #expect(FloatHand.corner(for: Self.window(984, 600), in: area, toward: CGVector(dx: -80, dy: 0)) == NSPoint(x: 16, y: 607))
    }

    @Test func onlyASecondOutwardSwipeTucks() {
        let area = Self.main.visible
        #expect(FloatHand.outwardSide(for: Self.window(500, 250), in: area, toward: CGVector(dx: 80, dy: 0)) == nil)
        #expect(FloatHand.outwardSide(for: Self.window(984, 86), in: area, toward: CGVector(dx: 80, dy: 0)) == .right)
        #expect(FloatHand.outwardSide(for: Self.window(16, 607), in: area, toward: CGVector(dx: -80, dy: 0)) == .left)
        #expect(FloatHand.outwardSide(for: Self.window(984, 86), in: area, toward: CGVector(dx: -80, dy: 0)) == nil)
        #expect(FloatHand.outwardSide(for: Self.window(984, 86), in: area, toward: CGVector(dx: 80, dy: 70)) == nil)
        #expect(FloatHand.outwardSide(for: Self.window(984, 86), in: area, toward: CGVector(dx: 0, dy: 80)) == nil)
    }

    @Test func twoFingersLandWhereTheWindowWasHeading() {
        let screens = [Self.main]
        func land(_ from: NSRect, _ to: NSRect, _ velocity: CGVector = .zero) -> FloatHand.Aim? {
            FloatHand.landing(to, from: from, swipe: CGVector(dx: to.minX - from.minX, dy: to.minY - from.minY),
                              velocity: velocity, screens: screens)
        }
        let bottomRight = Self.window(984, 86), topRight = Self.window(984, 607)
        // Up from the bottom right, slow or flicked: the top right.
        #expect(land(bottomRight, Self.window(984, 300)) == .glide(NSPoint(x: 984, y: 607)))
        #expect(land(bottomRight, Self.window(984, 200), CGVector(dx: 0, dy: 2000)) == .glide(NSPoint(x: 984, y: 607)))
        // Down from the top right, slowly: the bottom right.
        #expect(land(topRight, Self.window(984, 500)) == .glide(NSPoint(x: 984, y: 86)))
        // Hardly moved: back where it was.
        #expect(land(bottomRight, Self.window(984, 100)) == .glide(NSPoint(x: 984, y: 86)))
        #expect(land(bottomRight, bottomRight) == nil)
        // Across from the bottom left: the bottom right.
        #expect(land(Self.window(16, 86), Self.window(300, 86)) == .glide(NSPoint(x: 984, y: 86)))
        // A third past the outer side, or flicked out from the side it was
        // docked at: behind it.
        #expect(land(bottomRight, Self.window(1200, 86)) == .tuck(.right))
        #expect(land(bottomRight, Self.window(1000, 86), CGVector(dx: 800, dy: 0)) == .tuck(.right))
    }

    @Test func untuckingComesOutToACorner() {
        let area = Self.main.visible
        #expect(FloatPark.unparked(Self.window(1424, 500), .right, in: area) == NSPoint(x: 984, y: 607))
        #expect(FloatPark.unparked(Self.window(-424, 120), .left, in: area) == NSPoint(x: 16, y: 86))
    }

    @Test func pinchKeepsTheWholeWindowVisible() {
        let original = Self.window(984, 86)
        let grown = FloatHand.resized(original, to: 700, minWidth: 260, in: Self.main.visible,
                                      around: NSPoint(x: 1200, y: 200))
        #expect(grown.width == 700)
        #expect(grown.maxX <= Self.main.visible.maxX)
        #expect(grown.minY >= Self.main.visible.minY)
        #expect(abs(grown.width / grown.height - original.width / original.height) < 0.001)
        let shrunk = FloatHand.resized(original, to: 100, minWidth: 260, in: Self.main.visible)
        #expect(shrunk.width == 260)
    }

    @Test func screenIsTheOneShowingMost() {
        let screens = [Self.main, Self.beside]
        #expect(FloatPark.screen(for: Self.window(1100), in: screens) == Self.main)
        #expect(FloatPark.screen(for: Self.window(1300), in: screens) == Self.beside)
        // Wholly past every edge: the nearest.
        #expect(FloatPark.screen(for: Self.window(-1000), in: screens) == Self.main)
    }
}
