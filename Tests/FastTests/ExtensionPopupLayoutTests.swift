import AppKit
import Testing
@testable import Fast

@MainActor
struct ExtensionPopupLayoutTests {
    @Test func anUnmeasuredPopupUsesTheOriginalFallback() {
        #expect(!ExtensionPopup.waitsForSize(nil, elapsed: 0))
        #expect(!ExtensionPopup.waitsForSize(NSSize(width: 0, height: 240), elapsed: 0))
    }

    @Test func aMeasuredStripWaitsUntilThreeSecondsAfterOpening() {
        for width in [CGFloat(25), 99] {
            let size = NSSize(width: width, height: 240)
            // Elapsed time starts at the original 0.75-second fallback.
            #expect(ExtensionPopup.waitsForSize(size, elapsed: 0))
            #expect(ExtensionPopup.waitsForSize(size, elapsed: 2))
            #expect(!ExtensionPopup.waitsForSize(size, elapsed: 2.25))
            #expect(!ExtensionPopup.waitsForSize(size, elapsed: 3))
        }
    }

    @Test func aFullWidthPopupDoesNotWait() {
        for width in [CGFloat(100), 360] {
            #expect(!ExtensionPopup.waitsForSize(NSSize(width: width, height: 240), elapsed: 0))
        }
    }
}
