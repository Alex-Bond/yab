import SwiftUI

extension Metrics {
    enum SpaceTray {
        static let inset: CGFloat = 8
        static let top: CGFloat = 60
        static let radius: CGFloat = 38
        static let header: CGFloat = 64
        static let side: CGFloat = 16
        static let row: CGFloat = 52
        static let rootHeight: CGFloat = 252
        static let editHeight: CGFloat = 456
        static let colorHeight: CGFloat = 560
        static let emojiHeight: CGFloat = 600
        static let preview: CGFloat = 56
        static let fieldHeight: CGFloat = 196
        static let dot: CGFloat = 36
        static let linkedDot: CGFloat = 24
        static let dotColumns = 18
        static let dotRows = 9
        static let printedDot: CGFloat = 10
        static let sliderHeight: CGFloat = 44
        static let sectionGap: CGFloat = 12
    }
}

extension Motion {
    static let spaceLookDot = spring("spaceLookDot", response: 0.34, damping: 0.72)
}
