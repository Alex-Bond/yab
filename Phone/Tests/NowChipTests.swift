import XCTest
@testable import YabPhone

/// The Mac hint is a small chip over the plate: it names the site, hugs its
/// words and sits where the Now line sat.
@MainActor
final class NowChipTests: XCTestCase {
    private let screen = CGSize(width: 402, height: 874)

    private func macTab() -> Tab {
        PageFixtures.liveTab(for: URL(string: "https://www.figma.com/file/x")!, id: "mac-tab", title: "Onboarding v3")
    }

    func testTheHandoffChipNamesTheSiteAndTheMac() {
        let item = NowItem.handoff(macTab())
        XCTAssertEqual(item.kind, .handoff)
        XCTAssertEqual(item.chip?.words, "figma.com · On your Mac")
        XCTAssertEqual(item.chip?.icon, "www.figma.com")
    }

    func testOnlyTheHandoffIsAChip() {
        let plain = NowItem(id: "t", kind: .plain, title: "Task", subtitle: "Step", action: nil, short: "Task", icon: .mark, more: nil)
        XCTAssertNil(plain.chip)
        XCTAssertNil(plain.chipWidth(screen: screen.width))
    }

    func testTheChipHugsItsWordsAndSitsWhereTheLineSat() throws {
        let width = try XCTUnwrap(NowItem.handoff(macTab()).chipWidth(screen: screen.width))
        XCTAssertLessThan(width, Metrics.Now.width(screen: screen.width))
        XCTAssertGreaterThan(width, Metrics.Now.chipFixed)
        let line = ChromeGeometry(size: screen, folded: false, hasNow: true)
        let chip = ChromeGeometry(size: screen, folded: false, hasNow: true, chipWidth: width)
        XCTAssertEqual(chip.now.midX, screen.width / 2, accuracy: 0.5)
        XCTAssertEqual(chip.now.maxY, line.now.maxY, accuracy: 0.01, "10 over the plate, like the line")
        XCTAssertEqual(chip.now.height, Metrics.Now.chipHeight)
    }

    func testFoldedTheChipIsTheSameWordBesideThePlate() throws {
        let width = try XCTUnwrap(NowItem.handoff(macTab()).chipWidth(screen: screen.width))
        let folded = ChromeGeometry(size: screen, folded: true, hasNow: true, chipWidth: width).now
        XCTAssertEqual(folded, ChromeGeometry(size: screen, folded: true, hasNow: true).now)
    }
}
