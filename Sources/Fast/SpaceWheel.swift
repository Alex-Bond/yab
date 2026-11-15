import AppKit

// A mouse's wheel sideways over the column goes to the next space or back,
// as Arc's and Dia's sidebars do (feedback #282). Two fingers on a trackpad
// carry the row of spaces under them (SpaceSwipe, SpacePager); a wheel has
// no fingers to follow and no lift, so it turns the space as a key does,
// on the same slide.
//
// What a move says is judged here, apart from AppKit, so the tests can
// play a wheel's events through it: notches of a clicking wheel, the
// same with shift held on the up-and-down wheel, and the stream of small
// moves a smooth mouse sends with no phase. A move more up or down than
// sideways is the rows' own scroll and is left alone (Arc's sidebar turns
// its space on a quick vertical flick too, where its rows end; Yab's
// doesn't).

struct SpaceWheel {
    /// One scroll event, as AppKit has it.
    struct Move: Equatable {
        /// scrollingDeltaX and scrollingDeltaY: lines for a clicking
        /// wheel, points for a precise one.
        var dx: Double
        var dy: Double
        /// hasPreciseScrollingDeltas: a trackpad, a Magic Mouse, a smooth
        /// mouse; false for a wheel that clicks.
        var precise: Bool
        /// Shift held.
        var shift = false
        var time: TimeInterval
    }

    /// The numbers, measured on Arc 1.167 (docs/space-switching.md, "A
    /// mouse's wheel"): one notch alone turned nothing there, two within
    /// 50 ms did, 80 ms apart they didn't; a smooth mouse's 10 points did.
    enum Rule {
        /// A clicking wheel's notches, in lines, a push adds up to before
        /// the space turns: a stray notch, or a tilt bumped, doesn't.
        static let notches: Double = 2
        /// A smooth mouse's points a push adds up to before it turns.
        static let points: Double = 10
        /// Moves further apart than this are pushes of their own: until
        /// then, once the space has turned, the rest of the push turns
        /// nothing more (Arc: five notches 30 ms apart went one space).
        static let quiet: TimeInterval = 0.065
    }

    /// The sideways part of a move, negative toward the next space, or nil
    /// when it is the rows' scroll: more up or down than across, or none.
    /// Shift on a clicking wheel scrolls sideways; most mice already have
    /// the system turn it, and where it comes still up or down it is
    /// turned here.
    static func across(_ move: Move) -> Double? {
        var dx = move.dx, dy = move.dy
        if move.shift, !move.precise, dx == 0 { (dx, dy) = (dy, 0) }
        guard dx != 0, abs(dx) > abs(dy) else { return nil }
        return dx
    }

    /// What the push has added up to, the way it has gone.
    private var sum: Double = 0
    /// When the last move of the push came.
    private var last: TimeInterval = -.infinity
    /// The push has turned the space already.
    private var turned = false

    /// What a move does: 1 the next space, -1 the one before, 0 nothing.
    /// Nil when it isn't the wheel's to take (the rows' scroll); a 0 is
    /// still taken, so the rows under it don't drift sideways.
    mutating func take(_ move: Move) -> Int? {
        guard let dx = Self.across(move) else {
            // Up or down: the rows' scroll, and the end of any push, so a
            // smooth mouse's sideways wobble while scrolling never adds up.
            if move.dx != 0 || move.dy != 0 { reset() }
            return nil
        }
        // A new push after a pause, or one the other way.
        if move.time - last > Rule.quiet || (sum != 0 && (dx < 0) != (sum < 0)) {
            sum = 0
            turned = false
        }
        last = move.time
        guard !turned else { return 0 }
        sum += dx
        guard abs(sum) >= (move.precise ? Rule.points : Rule.notches) else { return 0 }
        turned = true
        return sum < 0 ? 1 : -1
    }

    /// Forget the push: the pointer went elsewhere, or fingers took over.
    mutating func reset() {
        sum = 0
        last = -.infinity
        turned = false
    }
}

extension SpaceWheel.Move {
    /// A scroll event's move.
    init(_ event: NSEvent) {
        self.init(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                  precise: event.hasPreciseScrollingDeltas,
                  shift: event.modifierFlags.contains(.shift), time: event.timestamp)
    }
}
