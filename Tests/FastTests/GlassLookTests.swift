import AppKit
import Testing
@testable import Fast

/// Glass as the step past a look's transparency (LookSlider), kept with
/// each space's look, rather than one switch in Settings › Experimental.
struct GlassLookTests {
    @MainActor @Test func glassSearchLeadsToLook() throws {
        let glass = try #require(SettingsItem.all.first { $0.id == "glass" })
        #expect(glass.page == .appearance)
        #expect(glass.within == "color")
        for query in ["glass", "liquid", "transparent", "frosted"] {
            #expect(glass.score(query) != nil, "Settings row: \(query)")
        }
        #expect(!SettingsItem.all.contains { $0.id == "experimental-glass" })
        #expect(SettingsItem.all.filter { $0.id == "glass" }.count == 1)
    }

    @Test func aSpacesGlassRoundTripsAndOlderLooksHaveNone() throws {
        var paint = SpacePaint(swatch: .custom, color: .red, grain: 0, transparency: 0.4)
        #expect(!String(decoding: try JSONEncoder().encode(paint), as: UTF8.self).contains("glass"))
        paint.glass = true
        let back = try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(paint))
        #expect(back == paint)
        #expect(back.glass && back.transparency == 0.4)
        let legacy = Data(#"{"swatch":"custom","color":"8DB6E6","grain":true,"transparency":0.5}"#.utf8)
        #expect(try !JSONDecoder().decode(SpacePaint.self, from: legacy).glass)
    }

    @Test func glassWornKeepsTheTransparencyForTheWayBack() {
        var paint = SpacePaint(swatch: .custom, color: .red, grain: 0, transparency: 0.4)
        #expect(paint.wornTransparency(dark: false) == 0.4)
        paint.glass = true
        let expected = WindowGlassPolicy.supported ? WindowGlassPolicy.transparency(for: paint.color(dark: true)) : 0.4
        #expect(paint.wornTransparency(dark: true) == expected)
        #expect(paint.transparency == 0.4)
    }
}
