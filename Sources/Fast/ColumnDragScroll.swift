import AppKit

/// A row held near an edge takes its list along, even while the hand rests.
/// The pins and foot keep their own drops; only the clear rows scroll.
enum ColumnDragScroll {
    static func velocity(at point: CGPoint, in room: CGRect) -> CGFloat {
        guard room.height > 0, room.contains(point) else { return 0 }
        let band = min(40, room.height / 4)
        let above = max(0, 1 - (point.y - room.minY) / band)
        let below = max(0, 1 - (room.maxY - point.y) / band)
        return (below * below - above * above) * 360
    }

    /// The list moves under a held row: add its actual travel to the hand's
    /// so the row stays under the pointer and its destination follows suit.
    static func travel(hand: CGFloat, offset: CGFloat, beganAt: CGFloat) -> CGFloat {
        hand + offset - beganAt
    }
}
