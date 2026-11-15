import SwiftUI
import XCTest
@testable import YabPhone

/// The size system holds together the way the prototype's does.
final class MetricsTests: XCTestCase {
    func testTheBottomRow() {
        // Safari's bar (65619b17): 26 from the sides, 48 high, 7 between a
        // button and the plate, 28 over the screen's foot.
        XCTAssertEqual(Metrics.Chrome.plateInset, 81)
        XCTAssertEqual(Metrics.Chrome.plateWidth(screen: Metrics.screen.width), 240)
        XCTAssertEqual(Metrics.Chrome.height, 48)
        XCTAssertEqual(Metrics.Chrome.round, Metrics.Chrome.height)
        XCTAssertEqual(Metrics.Chrome.bottom, 28)
    }

    func testTheNowLineStandsTenOverThePlate() {
        XCTAssertEqual(Metrics.Now.bottom - (Metrics.Chrome.bottom + Metrics.Chrome.height), Metrics.Edge.stack)
        XCTAssertEqual(Metrics.Now.bottom, 86)
        XCTAssertEqual(Metrics.Now.height, 52)
        XCTAssertEqual(Metrics.Now.width(screen: Metrics.screen.width), 378)
    }

    func testFoldedThePairIsCentered() {
        let g = ChromeGeometry(size: Metrics.screen, folded: true, hasNow: true)
        XCTAssertEqual(g.plate.minX, 64)
        XCTAssertEqual(g.plate.maxX, 196)
        XCTAssertEqual(g.now.minX, 204)
        XCTAssertEqual(g.now.maxX, 338)
        XCTAssertEqual(g.plate.maxY, Metrics.screen.height - Metrics.Chrome.minBottom)
        let alone = ChromeGeometry(size: Metrics.screen, folded: true, hasNow: false)
        XCTAssertEqual(alone.plate.minX, 122)
        XCTAssertEqual(alone.plate.width, 158)
        // Safari's capsule hugs its words: 22 on each side, 158 at most.
        let short = ChromeGeometry(size: Metrics.screen, folded: true, hasNow: false, words: 62)
        XCTAssertEqual(short.plate.width, 106)
        XCTAssertEqual(short.plate.midX, Metrics.screen.width / 2)
        XCTAssertEqual(short.plate.height, 31)
        XCTAssertEqual(short.plate.maxY, Metrics.screen.height - 16)
        XCTAssertEqual(ChromeGeometry(size: Metrics.screen, folded: true, hasNow: false, words: 400).plate.width, 158)
    }

    func testUnfoldedFramesMatchTheRedlines() {
        let g = ChromeGeometry(size: Metrics.screen, folded: false, hasNow: true)
        XCTAssertEqual(g.back, CGRect(x: 26, y: 798, width: 48, height: 48))
        XCTAssertEqual(g.plate, CGRect(x: 81, y: 798, width: 240, height: 48))
        XCTAssertEqual(g.space, CGRect(x: 328, y: 798, width: 48, height: 48))
        XCTAssertEqual(g.now, CGRect(x: 12, y: 736, width: 378, height: 52))
    }

    func testTouchTargetsAreAtLeast44() {
        for size in [Metrics.Chrome.round, Metrics.Chrome.height, Metrics.Field.height, Metrics.Column.row, Metrics.touch] {
            XCTAssertGreaterThanOrEqual(size, 44)
        }
    }

    func testSheetsAndBarsKeepTheirEdges() {
        XCTAssertEqual(Metrics.Edge.sheet + Metrics.Edge.gutter, Metrics.Edge.content)
        XCTAssertEqual(Metrics.Column.contentWidth(screen: Metrics.screen.width), 386)
        XCTAssertEqual(Metrics.Column.halfTop(screenHeight: Metrics.screen.height), Metrics.Column.halfTop)
        XCTAssertEqual(Metrics.Radius.capsule(Metrics.Chrome.height), 24)
    }
}

/// Motions keep the prototype's numbers and run without moving when off.
@MainActor
final class MotionTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Motion.fieldOpen.duration, 0.3, accuracy: 0.001)
        XCTAssertEqual(Motion.fieldClose.duration, 0.24, accuracy: 0.001)
        XCTAssertEqual(Motion.answerGrow.duration, 0.34, accuracy: 0.001)
        XCTAssertEqual(Motion.space.duration, 0.2, accuracy: 0.001)
        // Eased in and out over 0.42 s, no jump in the first frames (a35ec29d).
        XCTAssertEqual(Motion.chromeFold.duration, 0.3, accuracy: 0.001)
    }

    func testDisabledRunsAtOnce() {
        Motion.disabled = true
        defer { Motion.disabled = false }
        var ran = false, finished = false
        Motion.chatGrow.run({ ran = true }) { finished = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(finished)
    }
}

/// Haptics keep a journal in test runs, in order.
@MainActor
final class HapticsTests: XCTestCase {
    func testTheJournalKeepsTheOrder() {
        let before = Haptics.played.count
        Haptics.play(.medium, reason: Haptics.Reason.menu)
        Haptics.play(.light, reason: Haptics.Reason.tabLifted)
        let last = Haptics.played.suffix(2)
        XCTAssertEqual(Haptics.played.count, before + 2)
        XCTAssertEqual(last.map { $0.kind }, [.medium, .light])
        XCTAssertEqual(last.map { $0.reason }, ["menu", "lift"])
    }
}

/// The folder's shades are the Mac's on Work's color.
final class FolderTests: XCTestCase {
    func testOKLCHRoundTrips() {
        let (l, c, h) = OKLCH.from(RGB(226, 233, 244))
        let (r, g, b) = OKLCH.rgb(l, c, h)
        XCTAssertEqual(r * 255, 226, accuracy: 0.6)
        XCTAssertEqual(g * 255, 233, accuracy: 0.6)
        XCTAssertEqual(b * 255, 244, accuracy: 0.6)
    }

    func testTheFolderOpensDownward() {
        // Open, the front's top edge comes down toward the viewer.
        let shut = FolderGrid.project(FolderGrid.front[0], front: true, pose: .shut)
        let open = FolderGrid.project(FolderGrid.front[0], front: true, pose: .open)
        XCTAssertGreaterThan(open.y, shut.y)
    }
}
