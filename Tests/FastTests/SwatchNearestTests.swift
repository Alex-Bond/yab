import AppKit
import Testing
@testable import Fast

struct SwatchNearestTests {
    @Test func aColorCloseToASwatchIsThatSwatch() {
        let sage = NSColor(hex: "A9C4A1")!
        #expect(Swatch.nearest(sage) == .sage)
    }

    @Test func aColorFarFromEveryOneIsYourOwn() {
        let orange = NSColor(hex: "FF6A00")!
        #expect(Swatch.nearest(orange) == .custom)
    }
}
