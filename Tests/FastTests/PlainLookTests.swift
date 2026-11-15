import AppKit
import Testing
@testable import Fast

/// No Color (Swatch.plain, request #418): white in a light window, Arc's
/// black in a dark one, kept through saving, and read by an older build as
/// gray and by an iPhone as white.
struct PlainLookTests {
    @Test func followsLightAndDark() {
        var paint = SpacePaint(swatch: .sky, color: NSColor(hex: "8DB6E6")!, grain: 0.3, colors: ["B6A6E6"], transparency: 0.4)
        paint.wearPlain()
        #expect(paint.picked == .plain)
        #expect(paint.color(dark: false).hex == "FFFFFF")
        #expect(paint.color(dark: true).hex == "0F0F0F")
        // Nothing tints it, and its grain and transparency stay.
        #expect(paint.colors.isEmpty && paint.gradient(dark: true).isEmpty)
        #expect(paint.grain == 0.3 && paint.transparency == 0.4)
    }

    @Test func savedAndReadBack() throws {
        var paint = SpacePaint(swatch: .custom, color: .red, grain: 0)
        paint.wearPlain()
        let data = try JSONEncoder().encode(paint)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["swatch"] as? String == "plain" && object?["color"] as? String == "FFFFFF")
        #expect(try JSONDecoder().decode(SpacePaint.self, from: data) == paint)
    }

    /// A space saved before No Color keeps its look, and No Color isn't
    /// among the swatches a color is matched to.
    @Test func existingLooksStay() throws {
        let old = Data(#"{"swatch":"gray","color":"FFFFFF","grain":false,"grainAmount":0,"transparency":0}"#.utf8)
        let decoded = try JSONDecoder().decode(SpacePaint.self, from: old)
        #expect(decoded.picked == .gray && decoded.color(dark: true).hex == "202022")
        #expect(!Swatch.presets.contains(.plain))
        #expect(Swatch.nearest(.white) != .plain)
    }

    /// Its dot takes white's place, the Grays page's first, as Arc's sits
    /// on its grayscale page.
    @Test func dotSitsOnTheGraysPage() {
        let white = LookPresets.all[LookPresets.plainAt]
        #expect(white.name == "Grays 1" && white.preset.main == Swatch.plainSeed && white.preset.links.isEmpty)
    }
}
