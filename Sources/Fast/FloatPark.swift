import AppKit

// Where the floating video goes when it is let go of with part of it past
// a side of the screen: tucked behind that side with a lip of itself left
// out, as the system's picture in picture and Dia's do, or back inside.
//
// The pointer stops at the screen's edge: a window is carried past it one
// to one as far as the pointer goes, and on as far as the hand pushes
// against it (`pushed`). More than a third over when released, it goes
// behind the side. While held, it continues to follow the hand.
// Only the sides: the menu bar is along
// the top and the Dock along the bottom. And only a side with no other
// display past it. Past a shared one the window goes on over, and is let
// go of wholly on one display: with separate Spaces, the default, a window
// is shown on one display only, and what is over the edge is cut off. The
// display it goes to is the pointer's (`settle`), or for two fingers the
// one it was carried over to (`onward`).
//
// Pure, so FloatParkTests can hold it to made-up screens.
enum FloatPark {
    enum Side: String { case left, right }

    /// What is left out of a tucked window.
    static let lip: CGFloat = 16
    /// How much more of it comes out while the pointer rests on the lip.
    static let peek: CGFloat = 28
    /// How far in from the edge a window let go of partly over comes back to.
    static let margin: CGFloat = 16
    /// Release near an edge lines the window up with that edge.
    static let snapRange: CGFloat = 40

    struct Screen: Equatable {
        var frame: NSRect
        var visible: NSRect
    }

    enum Outcome: Equatable {
        /// Where it is, it can stay.
        case stay
        /// Back inside, to here.
        case inside(NSPoint)
        /// Tucked behind a side, its origin here.
        case park(Side, NSPoint)
    }

    /// The screen the window is on: the one showing most of it, or, all of
    /// it being past every edge, the one nearest.
    static func screen(for frame: NSRect, in screens: [Screen]) -> Screen? {
        let shown = screens.map { ($0, area($0.frame.intersection(frame))) }
        if let best = shown.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return screens.min { distance($0.frame, frame) < distance($1.frame, frame) }
    }

    /// Whether `side` of `screen` is the edge of everything, for a window
    /// as tall as `frame` and where it is: no display past it at that height.
    static func outer(_ side: Side, of screen: Screen, for frame: NSRect, in screens: [Screen]) -> Bool {
        !screens.contains { other in
            guard other != screen, other.frame.minY < frame.maxY, other.frame.maxY > frame.minY else { return false }
            switch side {
            case .left: return abs(other.frame.maxX - screen.frame.minX) <= 1
            case .right: return abs(other.frame.minX - screen.frame.maxX) <= 1
            }
        }
    }

    /// The same for the top and bottom, which never tuck: a window over
    /// them comes back unless another display is there.
    private static func open(top: Bool, of screen: Screen, for frame: NSRect, in screens: [Screen]) -> Bool {
        screens.contains { other in
            guard other != screen, other.frame.minX < frame.maxX, other.frame.maxX > frame.minX else { return false }
            return top ? abs(other.frame.minY - screen.frame.maxY) <= 1 : abs(other.frame.maxY - screen.frame.minY) <= 1
        }
    }

    /// What letting go of the window at `frame` comes to, with the
    /// pointer at `pointer` when a mouse let go of it.
    static func settle(_ frame: NSRect, pointer: NSPoint? = nil, in screens: [Screen], snapToEdges: Bool = true) -> Outcome {
        guard let screen = screen(for: frame, in: screens) else { return .stay }
        let area = screen.visible
        let left = outer(.left, of: screen, for: frame, in: screens)
        let right = outer(.right, of: screen, for: frame, in: screens)

        let third = frame.width / 3
        if right, frame.maxX - area.maxX > third { return .park(.right, parked(frame, .right, in: area)) }
        if left, area.minX - frame.minX > third { return .park(.left, parked(frame, .left, in: area)) }

        // Settle on the display showing most of it, or the one the pointer
        // has crossed onto: a corner when snapping, otherwise kept inside. Carried
        // slowly over a shared edge, most of the window is still on this
        // one, and separate Spaces cut it off at the edge as if it had
        // stopped there; the pointer says where it was being taken.
        let target = pointer.flatMap { at in screens.first { $0.frame.contains(at) } } ?? screen
        let spot = snapToEdges ? nearest(frame, in: target.visible) : bounded(frame, in: target.visible)
        return spot == frame.origin ? .stay : .inside(spot)
    }

    /// Free placement keeps its exact position while remaining wholly visible.
    static func bounded(_ frame: NSRect, in area: NSRect) -> NSPoint {
        NSPoint(x: min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width)),
                y: min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height)))
    }

    /// How much further back in a hand that took a window behind a side
    /// draws it, the button still down, before it comes out again: going
    /// and coming back at one place would flicker under a trembling hand.
    static let letOut: CGFloat = 40

    /// The side a window the hand has carried to `frame`, the button still
    /// down, goes behind now: more than a third past an outer side, where
    /// letting go would tuck it. Already going behind `tucking`, it stays
    /// until the hand draws it back in `letOut` more. Nil: carried as ever.
    static func held(_ frame: NSRect, tucking: Side?, in screens: [Screen]) -> Side? {
        guard let screen = screen(for: frame, in: screens) else { return nil }
        guard let tucking else {
            if case .park(let side, _) = settle(frame, in: screens) { return side }
            return nil
        }
        let area = screen.visible
        let past = tucking == .right ? frame.maxX - area.maxX : area.minX - frame.minX
        let keeps = outer(tucking, of: screen, for: frame, in: screens) && past > frame.width / 3 - letOut
        return keeps ? tucking : nil
    }

    /// The pointer stops at the screen's edge, so a window held by its far
    /// half never got a third past: the hand pushing on against an outer
    /// side carries it on past, as far as the mouse moves (`delta`, its own
    /// movement, which goes on with the pointer standing). `push` is how
    /// far it has so far.
    static func pushed(_ push: CGFloat, by delta: CGFloat, moved: CGFloat = 0,
                       pointer: NSPoint, frame: NSRect, in screens: [Screen]) -> CGFloat {
        guard delta != 0, let screen = screens.first(where: { $0.frame.contains(pointer) }) else { return push }
        let side: Side = delta > 0 ? .right : .left
        let standing = side == .right ? pointer.x >= screen.frame.maxX - 1.5 : pointer.x <= screen.frame.minX + 1
        guard standing, outer(side, of: screen, for: frame, in: screens) else { return push }
        // Arrival at the edge already moved the pointer. Add only the
        // part clipped by the edge, not that same movement a second time.
        let clipped = delta > 0 ? max(0, delta - max(0, moved)) : min(0, delta - min(0, moved))
        return push + clipped
    }

    /// Keep a mouse-held picture reachable at an outer side. It cannot
    /// overshoot its tucked position and then jump back toward the screen
    /// when released; tuckProgress gives its look while it follows the hand.
    static func carried(_ frame: NSRect, pointer: NSPoint, in screens: [Screen], lipWidth: CGFloat = 20) -> NSRect {
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? screen(for: frame, in: screens)
        else { return frame }
        var result = frame
        if outer(.left, of: screen, for: frame, in: screens) {
            result.origin.x = max(result.minX, screen.visible.minX - frame.width + lipWidth)
        }
        if outer(.right, of: screen, for: frame, in: screens) {
            result.origin.x = min(result.minX, screen.visible.maxX - lipWidth)
        }
        return result
    }

    /// The same position along the dock-to-tab path means the same look,
    /// whether a hand, two fingers or the parking spring put it there.
    static func tuckProgress(_ frame: NSRect, in screens: [Screen], lipWidth: CGFloat = 20, snapToEdges: Bool = true)
        -> (side: Side, fraction: CGFloat)? {
        guard let screen = screen(for: frame, in: screens) else { return nil }
        let area = screen.visible
        for side in [Side.left, .right] where outer(side, of: screen, for: frame, in: screens) {
            let inset = snapToEdges ? margin : 0
            let shown = side == .right ? area.maxX - inset - frame.width : area.minX + inset
            let hidden = side == .right ? area.maxX - lipWidth : area.minX - frame.width + lipWidth
            let fraction = (frame.minX - shown) / (hidden - shown)
            if fraction > 0 { return (side, min(1, fraction)) }
        }
        return nil
    }

    /// Two fingers have carried the window, heading `way`, to `frame`, or
    /// where it is heading, over a side of `here` another display shares:
    /// on to that display's nearest corner, once `least` of it is over,
    /// slow or quick. Nil when it is over none.
    static func onward(_ frame: NSRect, from here: Screen, toward way: CGVector, least: CGFloat = 24,
                       in screens: [Screen]) -> NSPoint? {
        let edge = here.frame
        var best: (to: Screen, shown: CGFloat)?
        for other in screens where other != here {
            let shown = area(other.frame.intersection(frame))
            guard shown > 0 else { continue }
            let over: CGFloat
            if way.dx > 0, abs(other.frame.minX - edge.maxX) <= 1 { over = frame.maxX - edge.maxX }
            else if way.dx < 0, abs(other.frame.maxX - edge.minX) <= 1 { over = edge.minX - frame.minX }
            else if way.dy > 0, abs(other.frame.minY - edge.maxY) <= 1 { over = frame.maxY - edge.maxY }
            else if way.dy < 0, abs(other.frame.maxY - edge.minY) <= 1 { over = edge.minY - frame.minY }
            else { continue }
            guard over >= least, shown > (best?.shown ?? 0) else { continue }
            best = (other, shown)
        }
        return best.map { nearest(frame, in: $0.to.visible) }
    }

    /// The corner of `area` nearest the window's middle, 16 pt in.
    static func nearest(_ frame: NSRect, in area: NSRect, margin: CGFloat = FloatPark.margin) -> NSPoint {
        let left = area.minX + margin, right = max(left, area.maxX - margin - frame.width)
        let bottom = area.minY + margin, top = max(bottom, area.maxY - margin - frame.height)
        return NSPoint(x: frame.midX > area.midX ? right : left, y: frame.midY > area.midY ? top : bottom)
    }

    /// Over a side another display shares, the part past it is cut off:
    /// separate Spaces show a window on one display only. Wholly onto the
    /// one showing most of it, or nil when nothing is over a shared side.
    static func across(_ frame: NSRect, in screens: [Screen]) -> NSPoint? {
        guard let screen = screen(for: frame, in: screens) else { return nil }
        let area = screen.visible
        var spot = frame.origin
        if frame.minX < area.minX, !outer(.left, of: screen, for: frame, in: screens) { spot.x = area.minX + margin }
        if frame.maxX > area.maxX, !outer(.right, of: screen, for: frame, in: screens) { spot.x = area.maxX - margin - frame.width }
        if frame.minY < area.minY, open(top: false, of: screen, for: frame, in: screens) { spot.y = area.minY + margin }
        if frame.maxY > area.maxY, open(top: true, of: screen, for: frame, in: screens) { spot.y = area.maxY - margin - frame.height }
        return spot == frame.origin ? nil : spot
    }

    /// A horizontal swipe changes side and keeps the nearer of top and
    /// bottom; a vertical one changes height and keeps the nearer side; a
    /// diagonal chooses both. Always a corner.
    static func corner(for frame: NSRect, in area: NSRect, toward way: CGVector, margin: CGFloat = FloatPark.margin) -> NSPoint {
        let left = area.minX + margin, right = area.maxX - margin - frame.width
        let bottom = area.minY + margin, top = area.maxY - margin - frame.height
        let across = abs(way.dx), up = abs(way.dy)
        let x = way.dx > 0 ? right : left, y = way.dy > 0 ? top : bottom
        if min(across, up) >= 0.4 * max(across, up) { return NSPoint(x: x, y: y) }
        if across >= up { return NSPoint(x: x, y: frame.midY > area.midY ? top : bottom) }
        return NSPoint(x: frame.midX > area.midX ? right : left, y: y)
    }

    /// A flick on from where the last one sent the window, or past it, when
    /// another display shares that side: across to that display's nearest
    /// corner on the near side, or up and down to the nearest one along.
    /// Nil elsewhere: a flick goes to a side or corner first, and only from
    /// there on, as at an outer side it tucks. A diagonal means a corner.
    static func passed(_ frame: NSRect, toward way: CGVector, in screens: [Screen]) -> NSPoint? {
        guard let screen = screen(for: frame, in: screens) else { return nil }
        let area = screen.visible, edge = screen.frame
        let others = screens.filter { $0 != screen }
        let stop = corner(for: frame, in: area, toward: way)
        func within(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }
        if abs(way.dx) > 1.5 * abs(way.dy) {
            let right = way.dx > 0
            let at = (right ? frame.minX >= stop.x - 1 : frame.minX <= stop.x + 1) && abs(stop.y - frame.minY) < 1
            let next = others.filter {
                $0.frame.minY < frame.maxY && $0.frame.maxY > frame.minY
                    && abs(right ? $0.frame.minX - edge.maxX : $0.frame.maxX - edge.minX) <= 1
            }.max { shared($0.frame, frame, across: true) < shared($1.frame, frame, across: true) }
            guard at, let to = next?.visible else { return nil }
            let y = within(frame.minY, to.minY + margin, to.maxY - margin - frame.height)
            return NSPoint(x: right ? to.minX + margin : to.maxX - margin - frame.width,
                           y: nearest(NSRect(origin: NSPoint(x: frame.minX, y: y), size: frame.size), in: to).y)
        }
        if abs(way.dy) > 1.5 * abs(way.dx) {
            let up = way.dy > 0
            let at = (up ? frame.minY >= stop.y - 1 : frame.minY <= stop.y + 1) && abs(stop.x - frame.minX) < 1
            let next = others.filter {
                $0.frame.minX < frame.maxX && $0.frame.maxX > frame.minX
                    && abs(up ? $0.frame.minY - edge.maxY : $0.frame.maxY - edge.minY) <= 1
            }.max { shared($0.frame, frame, across: false) < shared($1.frame, frame, across: false) }
            guard at, let to = next?.visible else { return nil }
            let x = within(frame.minX, to.minX + margin, to.maxX - margin - frame.width)
            return NSPoint(x: nearest(NSRect(origin: NSPoint(x: x, y: frame.minY), size: frame.size), in: to).x,
                           y: up ? to.minY + margin : to.maxY - margin - frame.height)
        }
        return nil
    }

    /// How much of the window's height another display beside it has, or,
    /// above or below it, of its width.
    private static func shared(_ other: NSRect, _ frame: NSRect, across: Bool) -> CGFloat {
        across ? min(other.maxY, frame.maxY) - max(other.minY, frame.minY)
            : min(other.maxX, frame.maxX) - max(other.minX, frame.minX)
    }

    /// A light pull while dragging inside the screen shows where release
    /// will align. It fades in continuously across the final 40 points.
    static func magnetic(_ frame: NSRect, in screens: [Screen], snapToEdges: Bool = true) -> NSPoint {
        guard snapToEdges else { return frame.origin }
        guard let screen = screen(for: frame, in: screens) else { return frame.origin }
        let area = screen.visible
        var spot = frame.origin
        func pulled(_ value: CGFloat, toward stop: CGFloat, inward: Bool) -> CGFloat {
            let distance = value - stop
            guard abs(distance) < snapRange, inward else { return value }
            let fraction = abs(distance) / snapRange
            return stop + distance * fraction * fraction
        }
        if outer(.left, of: screen, for: frame, in: screens) {
            spot.x = pulled(spot.x, toward: area.minX + margin, inward: spot.x >= area.minX + margin)
        }
        if outer(.right, of: screen, for: frame, in: screens) {
            spot.x = pulled(spot.x, toward: area.maxX - margin - frame.width, inward: spot.x <= area.maxX - margin - frame.width)
        }
        if !open(top: false, of: screen, for: frame, in: screens) {
            spot.y = pulled(spot.y, toward: area.minY + margin, inward: spot.y >= area.minY + margin)
        }
        if !open(top: true, of: screen, for: frame, in: screens) {
            spot.y = pulled(spot.y, toward: area.maxY - margin - frame.height, inward: spot.y <= area.maxY - margin - frame.height)
        }
        return spot
    }

    /// Tucked behind `side` of `area`, at the height it was, kept inside
    /// the area up and down.
    static func parked(_ frame: NSRect, _ side: Side, in area: NSRect, lipWidth: CGFloat = lip) -> NSPoint {
        let x = side == .right ? area.maxX - lipWidth : area.minX - frame.width + lipWidth
        let y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return NSPoint(x: x, y: y)
    }

    /// Tucked, with a little more of it out while the pointer rests on it.
    static func peeked(_ frame: NSRect, _ side: Side, in area: NSRect, lipWidth: CGFloat = lip, by out: CGFloat = peek) -> NSPoint {
        var spot = parked(frame, side, in: area, lipWidth: lipWidth)
        spot.x += side == .right ? -out : out
        return spot
    }

    /// A window let out of hiding: in from the side it was behind, to the
    /// corner on that side nearest where it waited.
    static func unparked(_ frame: NSRect, _ side: Side, in area: NSRect, snapToEdges: Bool = true) -> NSPoint {
        let x = side == .right ? area.maxX - margin - frame.width : area.minX + margin
        let bottom = area.minY + margin, top = max(bottom, area.maxY - margin - frame.height)
        return NSPoint(x: x, y: snapToEdges ? (frame.midY > area.midY ? top : bottom) : bounded(frame, in: area).y)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
