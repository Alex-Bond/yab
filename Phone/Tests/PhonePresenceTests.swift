import SyncKit
import XCTest
@testable import YabPhone

/// This iPhone's page in front in its presence, for a Mac's From iPhone.
@MainActor
final class PhonePresenceTests: PhoneLinkTestCase {
    // MARK: - this iPhone's page, for the Mac's From iPhone

    func testThePresenceSaysThePageAndWhenItCameInFront() throws {
        let changed = Date(timeIntervalSince1970: 1_800_000_000)
        let presence = SyncPresence(device: "phone", name: "Test iPhone", at: changed.timeIntervalSince1970 + 30, url: "https://example.com/a",
                                    title: "A page", tab: "4F2B1C3A-4E5D-4A7B-9C8D-0E1F2A3B4C5D",
                                    space: "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10", changed: changed.timeIntervalSince1970)
        let page = try XCTUnwrap(PhoneFront.page(device: "phone", record: presence.record))
        XCTAssertEqual(page.changed, changed)
        XCTAssertEqual(page.space, "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10")
        XCTAssertTrue(PhoneFront.offered(page, now: changed.addingTimeInterval(20), front: nil, frontTab: nil))
        // No page in front (a private tab): nothing for a Mac.
        let none = SyncPresence(device: "phone", name: "Test iPhone", at: 1, changed: changed.timeIntervalSince1970)
        XCTAssertNil(none.record["changed"])
        XCTAssertNil(PhoneFront.page(device: "phone", record: none.record))
    }
}
