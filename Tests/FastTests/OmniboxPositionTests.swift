import SwiftUI
import Testing
@testable import Fast

@MainActor
struct OmniboxPositionTests {
    @Test func compactCentersItsFixedExpandedHeight() {
        for height in [CGFloat(600), 1000, 2160] {
            for chrome in [CGFloat(0), 38, 72] {
                let room = Omnibox.compactRoom(in: height, pageTop: chrome, pageBottom: 8)
                let top = Omnibox.compactTop(in: height, pageTop: chrome, pageBottom: 8)
                #expect(room == Omnibox.compactBodyHeight)
                #expect(room + Omnibox.compactFieldHeight == 264)
                #expect(top - chrome == height - 8 - top - Omnibox.compactFieldHeight - room)
            }
        }
    }

    @Test func compactFitsShortPages() {
        let height: CGFloat = 200
        let room = Omnibox.compactRoom(in: height, pageTop: 40, pageBottom: 8)
        let top = Omnibox.compactTop(in: height, pageTop: 40, pageBottom: 8)
        #expect(top == 40 + Omnibox.margin)
        #expect(top + Omnibox.compactFieldHeight + room == height - 8 - Omnibox.margin)
    }

    @Test(arguments: [
        (700.0, 113.0), (1050, 189), (1380, 354), (1640, 484), (2160, 744)
    ])
    func approvedTop(height: Double, expected: Double) {
        // Keep both operands CGFloat: Testing's heterogeneous equality path
        // can report equal CGFloat/Double values as unequal.
        #expect(Omnibox.top(in: height) == CGFloat(expected))
    }

    @Test func shortWindowsKeepTheirFallback() {
        for height in stride(from: 100.0, through: 1050, by: 1) {
            let previous = max(16, min(((height - 58 - 417) / 2).rounded(), (height * 0.18).rounded()))
            #expect(Omnibox.top(in: height) == CGFloat(previous))
        }
    }

    @Test func tallWindowRuleIsContinuousAndNeverPassesCenter() {
        #expect(Omnibox.top(in: 1050.5) == 189.25)
        for height in stride(from: 1051.0, through: 5000, by: 1) {
            #expect(Omnibox.top(in: height) <= (height - Omnibox.fieldHeight - Omnibox.bodyHeight) / 2)
            #expect(Omnibox.placeRoom(in: height) == Omnibox.bodyHeight)
        }
    }

    @Test func addressFieldGrowsFromTheSamePosition() {
        for height in [700.0, 1050, 1380, 1640, 2160] {
            let size = CGSize(width: 1400, height: height)
            let origin = Omnibox.middle(in: size, inset: 0)
            #expect(origin.x == 0.5)
            #expect(origin.y == (Omnibox.top(in: height) + Omnibox.fieldHeight / 2) / CGFloat(height))
        }
        #expect(Omnibox.middle(in: .zero, inset: 0) == .center)
    }
}
