import SwiftUI

extension Metrics.Settings {
    /// The App Icon page, as the review of R49 draws it (s-appicon), under
    /// the sheet's head: its line, Cover Flow, the name and its theme note,
    /// dots, the Light/Dark preview, and the button 50 over the bottom.
    enum AppIcon {
        // Cover Flow's Mac geometry (AppIcons.swift's AppIconPage).
        static let artworkSide: CGFloat = 180
        static let artworkRadius: CGFloat = 0.225
        static let turnDegrees: Double = 50
        static let perspective: CGFloat = 0.45
        static let neighborShrink: CGFloat = 0.34
        static let neighborOffset: CGFloat = 0.62
        static let farOffset: CGFloat = 0.24
        static let visibleNeighbors: CGFloat = 3
        static let fadeEdge: CGFloat = 0.14
        static let dragStride: CGFloat = 0.4
        static let edgeShift: CGFloat = 0.5
        static let dragMinimum: CGFloat = 7
        /// The Dock's shadow under each icon: 0 14 18 at .22.
        static let shadowOpacity: Double = 0.22
        static let shadowRadius: CGFloat = 9
        static let shadowY: CGFloat = 14
        /// The flow's room: 250 high, the icon 20 under its top.
        static let flowHeight: CGFloat = 250
        static let artworkTop: CGFloat = 20
        // Down the page, from the head.
        static let lineTop: CGFloat = 10
        static let lineSide: CGFloat = 40
        static let flowTop: CGFloat = 16
        static let nameTop: CGFloat = 6
        static let noteTop: CGFloat = 5
        static let dotsTop: CGFloat = 18
        /// The preview's 36-point capsule sits in a 44-point row.
        static let themeTop: CGFloat = 23
        static let dot: CGFloat = 7
        static let dotGap: CGFloat = 8
        static let dotOff: Double = 0.35
        static let themeWidth: CGFloat = 170
        static let themeHeight: CGFloat = 36
        static let themeInset: CGFloat = 2
        static let knobShadow: Double = 0.15
        static let bottomRoom: CGFloat = 24
        /// The button: 54 high, 24 from the sides, 50 over the bottom.
        static let button: CGFloat = 54
        static let buttonSide: CGFloat = 24
        static let buttonBottom: CGFloat = 50
        static let errorGap: CGFloat = 10
        static let check: CGFloat = 20
        static let checkGap: CGFloat = 8
    }
}

extension Motion {
    static let appIconTurn = spring("appIconTurn", response: 0.42, damping: 0.86)
    /// The Light/Dark knob and the pictures changing with it.
    static let appIconTheme = spring("appIconTheme", response: 0.3)
}
