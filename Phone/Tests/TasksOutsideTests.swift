import XCTest
@testable import YabPhone

/// The pictures of outside Yab follow the device: the status bar's items
/// where the system puts them for its width, and no Island where there is none.
@MainActor
final class TasksOutsideTests: XCTestCase {
    func testTheStatusBarBesideAnIslandFollowsTheWidth() {
        // iPhone 17 Pro, measured on the simulator's own status bar.
        let pro = StatusBarLayout(width: 402, top: .island, beside: true)
        XCTAssertEqual(pro.time.x, 62, accuracy: 0.5)
        XCTAssertEqual(pro.wifi.x, 329.7, accuracy: 0.5)
        XCTAssertEqual(pro.battery.x, 357.5, accuracy: 0.5)
        XCTAssertNil(pro.signal, "beside a compact activity the signal bars make room")
        // iPhone 17 Pro Max: the same places in its wider ears.
        let max = StatusBarLayout(width: 440, top: .island, beside: true)
        XCTAssertGreaterThan(max.battery.x, pro.battery.x + 20)
        XCTAssertLessThan(max.battery.x + OutsideLook.battery / 2, 440 - 30)
        XCTAssertGreaterThan(max.wifi.x - 10, 220 + 63, "Wi-Fi stays clear of the Island")
    }

    func testANotchedIPhoneKeepsItsSignalBars() {
        let notch = StatusBarLayout(width: 390, top: .notch, beside: true)
        XCTAssertNotNil(notch.signal)
        XCTAssertLessThan(notch.signal!.x, notch.wifi.x)
        XCTAssertLessThan(notch.wifi.x, notch.battery.x)
    }
}
