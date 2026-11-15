import SwiftUI

/// What a turn did on the Mac, as the iPhone's chat says it: the Mac's
/// ChatTranscript sizes, each a step up for the iPhone's 15.5 words.
extension Metrics {
    enum Work {
        /// A step's mark, its drawing a tenth over its box (the Mac's StepMark).
        static let mark: CGFloat = 16
        static let markOver: CGFloat = 1.1
        /// A mark and its verb, as the Mac's 8.
        static let markGap: CGFloat = 8
        /// A step's row: its verb 15, rows 30 apart, a reason under it 13.
        static let stepFont: CGFloat = 15
        static let stepRow: CGFloat = 30
        static let stepSmall: CGFloat = 13
        /// The line of what it did, and the actions' time: 13.
        static let lineFont: CGFloat = 13
        static let lineHeight: CGFloat = 20
        /// Sites over one another: 16 each, the next 15 along, each cut by a
        /// 1.5 ring of the next (the Mac's SiteStack, 14 and 13).
        static let site: CGFloat = 16
        static let siteStep: CGFloat = 15
        static let siteRing: CGFloat = 1.5
        static let siteRadius: CGFloat = 4
        /// A thought's line 30 tall; a row's touch 36.
        static let actionRow: CGFloat = 30
        static let actionTouch: CGFloat = 36
        /// The steps under their line: past the mark and its gap.
        static let stepsInset: CGFloat = 24
        /// A subagent's plate (the Mac's ChatSubagentCard): its face 20, 12
        /// in all round, a bubble's 18 round, ink at 0.07.
        static let face: CGFloat = 20
        static let plateInset: CGFloat = 12
        static let plateRadius: CGFloat = 18
        static let plateInk: Double = 0.07
        static let nameFont: CGFloat = 14
        /// A report or a command's output, folded: its first 6 lines.
        static let reportLines = 6
        static let outputLines = 8
        /// A failure: its title 15.5 medium, its detail 13.5.
        static let failureTitle: CGFloat = 15.5
        static let failureDetail: CGFloat = 13.5
        /// A thought's line, and its words opened: 14 and 13.5.
        static let thoughtFont: CGFloat = 14
        static let chevron: CGFloat = 12
        /// The steps' tray: its sides, its first line under the grabber,
        /// and corners as the system's sheets.
        static let trayInset: CGFloat = 20
        static let trayTop: CGFloat = 28
        static let trayRadius: CGFloat = 32
    }
}

extension Motion {
    /// A turn's steps open and close under its line (the Mac's chatQuick).
    static let workFold = spring("workFold", response: 0.28)
}
