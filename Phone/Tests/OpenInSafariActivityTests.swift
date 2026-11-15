import UIKit
import XCTest
@testable import YabPhone

/// Share › Open in Safari names Safari itself, never the default browser (#2035).
@MainActor
final class OpenInSafariActivityTests: XCTestCase {
    func testWebAddressesGoToSafariByItsOwnScheme() {
        XCTAssertEqual(OpenInSafariActivity.safari(URL(string: "https://example.com/a?b=1#c"))?.absoluteString,
                       "x-safari-https://example.com/a?b=1#c")
        XCTAssertEqual(OpenInSafariActivity.safari(URL(string: "http://example.com"))?.absoluteString,
                       "x-safari-http://example.com")
    }

    func testOnlyWebAddressesAreOffered() {
        XCTAssertNil(OpenInSafariActivity.safari(URL(string: "mailto:anna@example.com")))
        XCTAssertNil(OpenInSafariActivity.safari(URL(fileURLWithPath: "/tmp/a.pdf")))
        let activity = OpenInSafariActivity()
        XCTAssertTrue(activity.canPerform(withActivityItems: [URL(string: "https://example.com")!]))
        XCTAssertFalse(activity.canPerform(withActivityItems: ["text", URL(string: "tel:+1555")!]))
    }
}
