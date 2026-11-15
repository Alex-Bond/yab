import CoreGraphics

/// Rounded rects whose corner is never more than half a side. macOS 15's
/// CoreGraphics asserts on one that is (CGPathAddRoundedRect, abort), and
/// later systems only clamp it, so a rect that can be small (a frame
/// before layout, a shape animated from nothing, a link's own box) goes
/// through here. 0.0.30 crashed at launch on 15.7.4 from the player
/// island's pause bars (BandDoor.pauseBarShapes, 2026-10-19).
extension CGRect {
    /// The largest corner up to `corner` that the rect can hold, and not
    /// below 0.
    func fitting(corner: CGFloat) -> CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, min(corner, width / 2, height / 2))
    }
}

extension CGPath {
    /// The rect rounded by `corner`, or as much of it as fits; nothing
    /// for a null rect (a small one inset past itself).
    static func rounded(_ rect: CGRect, corner: CGFloat) -> CGPath {
        guard !rect.isNull else { return CGMutablePath() }
        let corner = rect.fitting(corner: corner)
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}

extension CGMutablePath {
    /// Adds the rect rounded by `corner`, or as much of it as fits.
    func addRounded(_ rect: CGRect, corner: CGFloat) {
        guard !rect.isNull else { return }
        let corner = rect.fitting(corner: corner)
        addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
    }
}
