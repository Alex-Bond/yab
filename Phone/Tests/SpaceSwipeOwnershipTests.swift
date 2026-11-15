import XCTest
import UIKit
@testable import YabPhone

@MainActor
final class SpaceSwipeOwnershipTests: XCTestCase {
    func testSearchResultsPageHorizontallyAndKeepVerticalScrolling() {
        let pages = ["Chats", "Personal", "Work"]
        XCTAssertEqual(SpaceSearchPaging.destination(from: "Personal", pages: pages, translation: CGSize(width: -150, height: 10)), "Work")
        XCTAssertEqual(SpaceSearchPaging.destination(from: "Personal", pages: pages, translation: CGSize(width: 150, height: 10)), "Chats")
        XCTAssertNil(SpaceSearchPaging.destination(from: "Personal", pages: pages, translation: CGSize(width: 30, height: 0)))
        XCTAssertNil(SpaceSearchPaging.destination(from: "Personal", pages: pages, translation: CGSize(width: 80, height: 150)))
        XCTAssertNil(SpaceSearchPaging.destination(from: "Work", pages: pages, translation: CGSize(width: -150, height: 0)))
        XCTAssertNil(SpaceSearchPaging.destination(from: "Chats", pages: pages, translation: CGSize(width: 150, height: 0)))
        XCTAssertNil(SpaceSearchPaging.destination(from: nil, pages: [], translation: CGSize(width: 150, height: 0)))
    }

    func testSwipeableRowsReserveTheirMiddleAtEveryPhoneWidth() {
        for width: CGFloat in [320, 390, 402, 440] {
            XCTAssertEqual(SpaceSwipeOwner.at(14, width: width, overSwipeRow: true), .page)
            XCTAssertEqual(SpaceSwipeOwner.at(width - 14, width: width, overSwipeRow: true), .page)
            XCTAssertEqual(SpaceSwipeOwner.at(width / 2, width: width, overSwipeRow: true), .row)
            XCTAssertEqual(SpaceSwipeOwner.at(Metrics.SpaceSwipe.edge + 1, width: width, overSwipeRow: true), .row)
            XCTAssertEqual(SpaceSwipeOwner.at(width - Metrics.SpaceSwipe.edge - 1, width: width, overSwipeRow: true), .row)
        }
    }

    func testEverythingOutsideSwipeableRowsPagesAcrossTheWholeWidth() {
        for width: CGFloat in [320, 390, 402, 440] {
            for x in [0, 14, width / 2, width - 14, width] {
                XCTAssertEqual(SpaceSwipeOwner.at(x, width: width, overSwipeRow: false), .page)
            }
            XCTAssertEqual(SpaceSwipeOwner.at(28, width: width, overSwipeRow: true), .page)
            XCTAssertEqual(SpaceSwipeOwner.at(width - 28, width: width, overSwipeRow: true), .page)
        }
    }

    func testRegionsFollowScrollingAndExcludeHeadersEmptySpaceAndHiddenRows() {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let list = UIScrollView(frame: page.bounds)
        page.addSubview(list)
        let row = SpaceSwipeRowRegionView(frame: CGRect(x: 16, y: 100, width: 370, height: 50))
        list.addSubview(row)
        func overRow(_ y: CGFloat) -> Bool {
            SpaceSwipeRowRegionView.contains(CGPoint(x: 201, y: y), in: page)
        }
        XCTAssertFalse(overRow(75))
        XCTAssertTrue(overRow(125))
        XCTAssertFalse(overRow(175))
        list.bounds.origin.y = 50
        XCTAssertTrue(overRow(75))
        XCTAssertFalse(overRow(125))
        row.isHidden = true
        XCTAssertFalse(overRow(75))
        row.isHidden = false
        row.alpha = 0
        XCTAssertFalse(overRow(75))
        row.alpha = 1
        list.bounds.origin.y = 200
        XCTAssertFalse(overRow(-75))
        row.removeFromSuperview()
        XCTAssertFalse(overRow(75))
    }
}
