import CoreGraphics

extension Metrics {
    /// The site pill expands into its page controls at the same bottom edge.
    enum PageControls {
        static let morphSpacing: CGFloat = 0
        static let menuInset: CGFloat = Edge.bar
        static let menuRadius: CGFloat = 30
        static let menuPadding: CGFloat = 10
        static let headerHeight: CGFloat = 50
        static let headerFont: CGFloat = 16
        static let headerGap: CGFloat = 10
        static let headerTextGap: CGFloat = 2
        static let headerTextVerticalPadding: CGFloat = 12
        static let rowPadding: CGFloat = 12
        static let rowGap: CGFloat = 12
        static let rowHeight: CGFloat = 44
        static let separatorHeight: CGFloat = 0.5
        static let progressHeight: CGFloat = 3
        static let progressBottom: CGFloat = 3
    }
}
