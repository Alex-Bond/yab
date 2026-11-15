import AppKit
import Testing
@testable import Fast

// Another browser's look as Yab wears it: a place's color and grain become
// a SpacePaint, a preset when the color is one, your own otherwise.
@MainActor
struct PlaceLookTests {
    static func place(_ color: String?, grain: Double? = nil) -> TabImport.Place {
        TabImport.Place(id: "Arc:1", name: "Work", color: color, grain: grain, profile: "Default", shared: true, pinned: [], open: [])
    }

    @Test func noColorNoPaint() {
        #expect(Self.place(nil).paint(Preferences()) == nil)
    }

    @Test func farColorIsYourOwn() {
        let paint = Self.place("12E4A0", grain: 0.9).paint(Preferences())
        #expect(paint?.picked == .custom)
        #expect(paint?.color == "12E4A0")
        #expect(paint?.grain == 0.9)
    }

    @Test func presetColorIsThePreset() throws {
        let sage = try #require(Swatch.sage.color(dark: false, custom: .gray).usingColorSpace(.sRGB))
        let paint = Self.place(sage.hex, grain: 0).paint(Preferences())
        #expect(paint?.picked == .sage)
        #expect(paint?.grain == 0)
    }

    @Test func wornByTheWindow() throws {
        let prefs = Preferences()
        let paint = try #require(Self.place("12E4A0", grain: 0.9).paint(prefs))
        paint.wear(prefs)
        #expect(prefs.swatch == .custom)
        #expect(prefs.backdropColor.hex == "12E4A0")
        #expect(prefs.grain == 0.9)
    }
}
