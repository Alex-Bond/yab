import XCTest
@testable import YabPhone

/// Louder: every moment lands as a soft impact at its tone's strength.
@MainActor
final class HapticsFeelTests: XCTestCase {
    func testEveryImpactIsSoftAndLoudEnough() {
        let reasons = [Haptics.Reason.columnOpened, Haptics.Reason.menu, Haptics.Reason.clear, Haptics.Reason.tabHeld,
                       Haptics.Reason.copyLink, Haptics.Reason.lensPress, Haptics.Reason.notFound, Haptics.Reason.zoomLimit,
                       Haptics.Reason.tabCross, "something new"]
        for reason in reasons {
            for kind in [Haptics.Kind.soft, .selection, .light, .medium, .rigid] {
                let value = Haptics.Feel.intensity(kind, reason)
                XCTAssertGreaterThanOrEqual(value, 0.55, reason)
                XCTAssertLessThanOrEqual(value, 1, reason)
            }
        }
    }

    func testEachMomentHasItsTone() {
        XCTAssertEqual(Haptics.tone(.selection, Haptics.Reason.tabCross), .tick)
        XCTAssertEqual(Haptics.tone(.selection, Haptics.Reason.permission), .tick)
        XCTAssertEqual(Haptics.tone(.selection, Haptics.Reason.nowDismissed), .tick)
        XCTAssertEqual(Haptics.tone(.selection, Haptics.Reason.sheetBack), .tick)
        XCTAssertEqual(Haptics.tone(.light, Haptics.Reason.edited), .tap)
        XCTAssertEqual(Haptics.tone(.rigid, Haptics.Reason.spaceDeleted), .thud)
        XCTAssertEqual(Haptics.tone(.error, Haptics.Reason.unlockFailed), .error)
        XCTAssertEqual(Haptics.tone(.selection, Haptics.Reason.zoomStep), .tick)
        XCTAssertEqual(Haptics.tone(.light, "keep"), .tap)
        XCTAssertEqual(Haptics.tone(.medium, Haptics.Reason.menu), .tap)
        XCTAssertEqual(Haptics.tone(.light, "open on mac"), .tap)
        XCTAssertEqual(Haptics.tone(.rigid, Haptics.Reason.clear), .thud)
        XCTAssertEqual(Haptics.tone(.soft, Haptics.Reason.privateUnlocked), .thud)
        XCTAssertEqual(Haptics.tone(.soft, Haptics.Reason.cardThrown), .thud)
        XCTAssertEqual(Haptics.tone(.soft, Haptics.Reason.zoomLimit), .wall)
        XCTAssertEqual(Haptics.tone(.soft, "reader none"), .wallTwice)
        XCTAssertEqual(Haptics.tone(.success, "joined"), .success)
    }

    func testTheTonesAreTheLouderOnesPicked() {
        XCTAssertEqual(Haptics.Feel.intensity(.tick), 0.7)
        XCTAssertEqual(Haptics.Feel.intensity(.tap), 0.9)
        XCTAssertEqual(Haptics.Feel.intensity(.thud), 1)
        XCTAssertEqual(Haptics.Feel.intensity(.wall), 0.55)
    }

    func testTheNewPlacesPlay() {
        let before = Haptics.played.count
        Haptics.play(.selection, reason: Haptics.Reason.tabCross)
        Haptics.play(.soft, reason: Haptics.Reason.refresh)
        XCTAssertEqual(Haptics.played.dropFirst(before).map(\.reason), [Haptics.Reason.tabCross, Haptics.Reason.refresh])
    }
}
