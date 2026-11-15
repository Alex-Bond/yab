import XCTest
@testable import YabPhone

@MainActor
final class PlateAddressTests: XCTestCase {
    func testFoldedAddressTargetContainsTheVisibleCapsuleAndBothTouchMargins() {
        for hasNow in [false, true] {
            let geometry = ChromeGeometry(size: Metrics.screen, folded: true, hasNow: hasNow)
            XCTAssertEqual(geometry.plate.height, Metrics.Chrome.minHeight)
            XCTAssertEqual(geometry.plateTouch.height, 44)
            XCTAssertEqual(geometry.plateTouch.midY, geometry.plate.midY)
            XCTAssertEqual(geometry.plateTouch.width, geometry.plate.width)
            XCTAssertTrue(geometry.plateTouch.contains(geometry.plate))
            XCTAssertTrue(geometry.plateTouch.contains(CGPoint(x: geometry.plate.midX, y: geometry.plate.minY - 4)))
            XCTAssertTrue(geometry.plateTouch.contains(CGPoint(x: geometry.plate.midX, y: geometry.plate.maxY + 4)))
        }
        let expanded = ChromeGeometry(size: Metrics.screen, folded: false, hasNow: false)
        XCTAssertEqual(expanded.plateTouch, expanded.plate)
    }

    func testPillHostDoesNotRewriteCanonicalAddress() throws {
        let url = "http://www.docs.example:8080/Path?q=a%2Bb#part"
        let tab = Tab(id: "plate-address", title: "Document", site: "Docs", icon: "docs", url: url)
        XCTAssertEqual(PlateLabel.address(tab), "docs.example:8080")
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(try XCTUnwrap(tab.navigationURL).absoluteString, url)
    }

    func testPrivatePillUsesItsActualPageHost() {
        let tab = Tab(id: "private-address", title: "Private document", site: "Old site", icon: "private",
                      url: "https://private.example/secret?query=words", host: "old.example", isPrivate: true)
        XCTAssertEqual(PlateLabel.address(tab), "private.example")
        XCTAssertTrue(tab.isPrivate)
        XCTAssertEqual(tab.url, "https://private.example/secret?query=words")
    }
}
