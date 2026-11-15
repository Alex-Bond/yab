import Foundation

/// A small stop at the default width. Leaving it takes a little more travel
/// than entering it, so a resting finger does not keep firing the haptic.
struct SidebarWidthDetent {
    private var previous: CGFloat
    private var held: Bool

    init(width: CGFloat) {
        previous = width
        held = width == Metrics.side
    }

    mutating func update(wanted: CGFloat, maximum: CGFloat) -> (width: CGFloat, aligned: Bool) {
        defer { previous = wanted }
        let clamped = min(maximum, max(Metrics.sideMin, wanted))
        guard maximum >= Metrics.side else {
            held = false
            return (clamped, false)
        }

        let distance = abs(wanted - Metrics.side)
        if held {
            held = distance <= 8
            return (held ? Metrics.side : clamped, false)
        }

        let crossed = (previous < Metrics.side && wanted >= Metrics.side)
            || (previous > Metrics.side && wanted <= Metrics.side)
        held = distance <= 4
        // Fast drags can cross the stop between events. Still tick once,
        // without pulling the sidebar back against the pointer's movement.
        return (held ? Metrics.side : clamped, held || crossed)
    }
}
