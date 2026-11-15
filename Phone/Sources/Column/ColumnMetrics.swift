import CoreGraphics
import SwiftUI

/// The column's numbers that Metrics.Column doesn't carry, from the
/// prototype's CSS (.a-line, .a-clear, .sp-bar, .tab-ctx), still drawn by
/// the spaces (Field/NewTabSpaces) and folder marks. Kept here so the
/// shared Metrics file stays the skeleton's.
extension Metrics.Column {
    /// A folder's mark, where a row's icon starts.
    static let folderIcon: CGFloat = 22

    // The today line and Clear (.a-line, .a-clear).
    static let clearFont: CGFloat = 13.5
    static let clearGap: CGFloat = 12
    /// Clear is small to see and 6 x 12 bigger to hit.
    static let clearOutset = CGSize(width: 12, height: 6)
    static let lineAlpha: Double = 0.12

    // The capsule's names (.sp-bar; CapsuleModel has its own numbers).
    static let nameHeight: CGFloat = 44
    static let nameTracking: CGFloat = -0.01

    /// Ask About Page waits for the spaces to go down before the field grows.
    static let askDelay: TimeInterval = 0.38
}

extension Haptics.Reason {
    // The prototype's own words for a tab's actions (light).
    static let closed = "close"
    static let kept = "keep"
    static let unkept = "unkeep"
    static let pinned = "pin"
    static let unpinned = "unpin"
    static let moved = "moved"
}
