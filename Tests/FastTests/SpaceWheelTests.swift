import Foundation
import Testing
@testable import Fast

// A mouse's wheel sideways over the column (SpaceWheel, feedback #282),
// against what Arc was measured doing (docs/space-switching.md, "A mouse's
// wheel").
struct SpaceWheelTests {
    static func notch(_ dx: Double, _ dy: Double = 0, at time: TimeInterval, shift: Bool = false) -> SpaceWheel.Move {
        SpaceWheel.Move(dx: dx, dy: dy, precise: false, shift: shift, time: time)
    }

    static func smooth(_ dx: Double, _ dy: Double = 0, at time: TimeInterval) -> SpaceWheel.Move {
        SpaceWheel.Move(dx: dx, dy: dy, precise: true, time: time)
    }

    /// The steps a run of moves makes, nil for a move left to the rows.
    static func play(_ moves: [SpaceWheel.Move]) -> [Int?] {
        var wheel = SpaceWheel()
        return moves.map { wheel.take($0) }
    }

    @Test func oneNotchAloneTurnsNothing() {
        // Arc: a single notch either way, from any space, left it there;
        // taken all the same, so nothing under it moves sideways.
        #expect(Self.play([Self.notch(-1, at: 0)]) == [0])
        #expect(Self.play([Self.notch(1, at: 0)]) == [0])
    }

    @Test func twoQuickNotchesTurnOneSpace() {
        // Arc: two notches 16 ms apart went to the next space. scrollingDeltaX
        // negative is toward the next, as two fingers go.
        #expect(Self.play([Self.notch(-1, at: 0), Self.notch(-1, at: 0.016)]) == [0, 1])
        #expect(Self.play([Self.notch(1, at: 0), Self.notch(1, at: 0.016)]) == [0, -1])
        // An accelerated notch of three lines at once (Arc: next space).
        #expect(Self.play([Self.notch(-3, at: 0)]) == [1])
    }

    @Test func notchesTooFarApartDontAddUp() {
        // Arc: two notches 50 ms apart went on, 80 ms apart stayed.
        #expect(Self.play([Self.notch(-1, at: 0), Self.notch(-1, at: 0.05)]) == [0, 1])
        #expect(Self.play([Self.notch(-1, at: 0), Self.notch(-1, at: 0.08)]) == [0, 0])
    }

    @Test func aPushTurnsOneSpaceAtMost() {
        // Arc: five notches 30 ms apart went one space.
        let gap = 0.03
        #expect(Self.play((0..<5).map { Self.notch(-1, at: Double($0) * gap) }) == [0, 1, 0, 0, 0])
    }

    @Test func pushesApartTurnEach() {
        let gap = SpaceWheel.Rule.quiet * 1.5
        let moves = [Self.notch(-1, at: 0), Self.notch(-1, at: 0.016),
                     Self.notch(-1, at: gap), Self.notch(-1, at: gap + 0.016)]
        #expect(Self.play(moves) == [0, 1, 0, 1])
        // Single notches far apart never add up.
        #expect(Self.play((0..<3).map { Self.notch(-1, at: Double($0) * gap) }) == [0, 0, 0])
    }

    @Test func theOtherWayStartsAgain() {
        #expect(Self.play([Self.notch(-1, at: 0), Self.notch(1, at: 0.02), Self.notch(1, at: 0.04)]) == [0, 0, -1])
    }

    @Test func shiftTurnsTheUpAndDownWheel() {
        // Shift with a clicking wheel scrolls sideways: when the system
        // hasn't turned it already, it is turned here.
        #expect(Self.play([Self.notch(0, -1, at: 0, shift: true), Self.notch(0, -1, at: 0.02, shift: true)]) == [0, 1])
        // Turned by the system already: deltaX carries it.
        #expect(Self.play([Self.notch(1, 0, at: 0, shift: true), Self.notch(1, 0, at: 0.02, shift: true)]) == [0, -1])
        // Shift on a trackpad's move is nothing of the kind.
        #expect(SpaceWheel.across(SpaceWheel.Move(dx: 0, dy: -4, precise: true, shift: true, time: 0)) == nil)
    }

    @Test func upAndDownIsTheRowsScroll() {
        // Arc turned its space on a quick vertical flick where the rows
        // ended; Yab leaves every move more up or down to the rows.
        #expect(Self.play([Self.notch(0, -1, at: 0), Self.notch(0, -3, at: 0.02), Self.notch(-1, -3, at: 0.04),
                           Self.smooth(-3, -8, at: 0.06)]) == [nil, nil, nil, nil])
        // An even split is not sideways either, nor nothing at all.
        #expect(SpaceWheel.across(Self.notch(-2, -2, at: 0)) == nil)
        #expect(SpaceWheel.across(Self.notch(0, 0, at: 0)) == nil)
    }

    @Test func aVerticalScrollEndsThePush() {
        // A smooth mouse's sideways wobble between moves down never adds up.
        let moves = [Self.smooth(-6, at: 0), Self.smooth(-1, -9, at: 0.016), Self.smooth(-6, at: 0.032)]
        #expect(Self.play(moves) == [0, nil, 0])
    }

    @Test func smoothMovesAddUpFirst() {
        // Arc: five moves of 2 points, 10 in all, went to the next space.
        let moves = (0..<5).map { Self.smooth(-2, at: Double($0) / 60) }
        #expect(Self.play(moves) == [0, 0, 0, 0, 1])
        // Short of it nothing turns.
        #expect(Self.play((0..<4).map { Self.smooth(-2, at: Double($0) / 60) }) == [0, 0, 0, 0])
        // Ten moves of 4: one space, at the third.
        #expect(Self.play((0..<10).map { Self.smooth(-4, at: Double($0) / 60) }) == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func smoothPushThenPauseTurnsAgain() {
        let reach = SpaceWheel.Rule.points
        let moves = [Self.smooth(-reach, at: 0), Self.smooth(-reach, at: 0.05),
                     Self.smooth(-reach, at: 0.05 + SpaceWheel.Rule.quiet * 1.5)]
        #expect(Self.play(moves) == [1, 0, 1])
    }

    @Test func resetForgetsThePush() {
        var wheel = SpaceWheel()
        #expect(wheel.take(Self.notch(-3, at: 0)) == 1)
        wheel.reset()
        #expect(wheel.take(Self.notch(-3, at: 0.01)) == 1)
    }
}
