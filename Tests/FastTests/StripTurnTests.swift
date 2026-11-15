import AppKit
import Foundation
import Testing
@testable import Fast

// A change of space with the tabs across the top, as Dia's strip does it
// (evals/dia-top-spaces, feedback #254): which space two fingers take the
// strip to, how far, when they bring it, and the keys going round the ends.
struct StripTurnTests {
    @Test func fingersTowardTheNextSpace() {
        let aim = StripTurn.aim(from: 0, count: 3, travel: -160)
        #expect(aim.to == 1)
        #expect(aim.way == 1)
        #expect(abs(aim.progress - 160 / StripTurn.reach) < 1e-9)
        // The other way, the one before.
        let back = StripTurn.aim(from: 1, count: 3, travel: 100)
        #expect(back.to == 0)
        #expect(back.way == -1)
        // Never more than one space a gesture.
        #expect(StripTurn.aim(from: 0, count: 3, travel: -5000).progress == 1)
        #expect(StripTurn.aim(from: 0, count: 3, travel: -5000).to == 1)
    }

    @Test func noWayRoundTheEnds() {
        // Past the last space and before the first: nothing there, the name
        // gives a little, never as much as `give` of a space.
        for (from, travel) in [(2, -200.0), (2, -100_000.0), (0, 300.0), (0, 100_000.0)] {
            let aim = StripTurn.aim(from: from, count: 3, travel: CGFloat(travel))
            #expect(aim.to == nil)
            #expect(aim.progress > 0 && aim.progress <= StripTurn.give)
            #expect(!StripTurn.commits(aim))
        }
        // More push gives more, less and less.
        let a = StripTurn.aim(from: 2, count: 3, travel: -60).progress
        let b = StripTurn.aim(from: 2, count: 3, travel: -120).progress
        let c = StripTurn.aim(from: 2, count: 3, travel: -240).progress
        #expect(a < b && b < c)
        // One space alone: nowhere to go either way.
        #expect(StripTurn.aim(from: 0, count: 1, travel: -200).to == nil)
    }

    @Test func anyWayTowardANeighborBringsIt() {
        // Dia brought the next profile after 40 points of 420.
        #expect(StripTurn.commits(StripTurn.aim(from: 0, count: 3, travel: -40)))
        #expect(StripTurn.commits(StripTurn.aim(from: 1, count: 3, travel: 40)))
        // A touch is not a swipe.
        #expect(!StripTurn.commits(StripTurn.aim(from: 0, count: 3, travel: -8)))
        #expect(!StripTurn.commits(StripTurn.aim(from: 0, count: 3, travel: 0)))
    }

    @Test func keysGoRoundTheEnds() {
        #expect(StripTurn.step(from: 2, count: 3, by: 1) == 0)
        #expect(StripTurn.step(from: 0, count: 3, by: -1) == 2)
        #expect(StripTurn.step(from: 0, count: 3, by: 2) == 2)
        #expect(StripTurn.step(from: 1, count: 3, by: -1) == 0)
        #expect(StripTurn.step(from: 0, count: 1, by: 1) == nil)
    }

    @MainActor @Test func oneCriticallyDampedSpring() {
        // ω 26 rad/s, mass 1: Dia's capsule edge, fitted over five takes.
        let spring = StripTurn.caSpring(keyPath: "opacity", from: 1, to: 0)
        #expect(spring.mass == 1)
        #expect(abs(spring.stiffness - 676) < 1e-6)
        #expect(abs(spring.damping - 52) < 1e-6)
        #expect(abs(StripTurn.response - 2 * .pi / 26) < 1e-9)
        // Critically damped: 99% at about 265 ms after it sets off, as Dia's
        // capsule was (263 to 278 ms over the takes).
        func x(_ t: Double) -> Double { 1 - (1 + 26 * t) * exp(-26 * t) }
        #expect(x(0.26) > 0.985 && x(0.26) < 0.995)
        #expect(x(0.067) > 0.45 && x(0.067) < 0.55)
    }

    @Test func newTabsArriveIn140ms() {
        #expect(StripTurn.arrived(0) == 0)
        #expect(abs(StripTurn.arrived(StripTurn.arrivalTime) - 1) < 1e-6)
        #expect(StripTurn.arrived(1) == 1)
        // Out quickly, landing soft: past half the way in the first third.
        #expect(StripTurn.arrived(StripTurn.arrivalTime / 3) > 0.5)
        var last: CGFloat = 0
        for i in 1...14 {
            let now = StripTurn.arrived(Double(i) / 100)
            #expect(now >= last)
            last = now
        }
        // The spring, as the layers sample it, is 99% there by the end of its span.
        #expect(StripTurn.way(0) == 0)
        #expect(StripTurn.way(StripTurn.span) > 0.99)
    }

    @Test func oneRowAtATimeUnderTheFingers() {
        for i in 0...100 {
            let p = CGFloat(i) / 100
            // Never two rows' titles over each other, at any way along.
            #expect(StripTurn.going(p) == 0 || StripTurn.coming(p) == 0)
            #expect(StripTurn.going(p) <= 1 && StripTurn.coming(p) <= 1)
        }
        #expect(StripTurn.going(0) == 1 && StripTurn.coming(0) == 0)
        #expect(StripTurn.going(1) == 0 && StripTurn.coming(1) == 1)
    }

    @MainActor @Test func layersTakeTheTurnFromSwiftUI() {
        let was = (StripTurn.hosted, StripTurn.cut)
        defer { StripTurn.hosted = was.0; StripTurn.cut = was.1 }
        StripTurn.hosted = false
        StripTurn.cut = []
        #expect(!StripTurn.layered && StripTurn.swiftUI("slide"))
        StripTurn.hosted = true
        #expect(StripTurn.layered && !StripTurn.swiftUI("slide") && !StripTurn.swiftUI("arrival"))
        // The bench's way back to SwiftUI's turn, part by part.
        StripTurn.cut = ["layers", "leaving"]
        #expect(!StripTurn.layered && StripTurn.swiftUI("slide") && !StripTurn.swiftUI("leaving"))
    }
}
