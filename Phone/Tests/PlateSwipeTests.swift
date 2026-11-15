import XCTest
@testable import YabPhone

/// The plate's up rule in numbers: let go as a quick, short, fast flick, it
/// is the sidebar; anything else stays with All Tabs, which took the finger.
final class PlateSwipeTests: XCTestCase {
    func testAQuickShortFastFlickIsTheSidebar() {
        XCTAssertTrue(PlateSwipe.isFlick(travel: 110, speed: 1800, elapsed: 0.14))
    }

    func testASlowOrLongOrLateFingerIsAllTabs() {
        XCTAssertFalse(PlateSwipe.isFlick(travel: 110, speed: 600, elapsed: 0.2), "too slow")
        XCTAssertFalse(PlateSwipe.isFlick(travel: 170, speed: 1800, elapsed: 0.1), "past the flick's travel")
        XCTAssertFalse(PlateSwipe.isFlick(travel: 90, speed: 1800, elapsed: 0.3), "longer than a flick")
    }
}
