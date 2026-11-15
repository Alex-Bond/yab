import XCTest

/// Spaces open by the same upward plate gesture used by the person.
/// New Tab occupies the right circle, so tests must not tap it for spaces.
enum SpacesGesture {
    static func open(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let plate = app.descendants(matching: .any)["chrome.plate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 10), "no plate to swipe", file: file, line: line)
        let window = app.windows.firstMatch
        let frame = plate.frame
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)),
                    withVelocity: .fast, thenHoldForDuration: 0.05)
    }
}
