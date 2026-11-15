import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
struct TransparencyTests {
    @Test func olderSpacesStayOpaqueAndNewValuesRoundTrip() throws {
        let legacy = Data(#"{"swatch":"custom","color":"8DB6E6","grain":true}"#.utf8)
        var paint = try JSONDecoder().decode(SpacePaint.self, from: legacy)
        #expect(paint.transparency == 0)
        paint.transparency = 0.75
        let restored = try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(paint))
        #expect(restored == paint)
        #expect(restored.color == "8DB6E6")
        let outside = Data(#"{"swatch":"custom","color":"8DB6E6","grain":false,"transparency":3}"#.utf8)
        #expect(try JSONDecoder().decode(SpacePaint.self, from: outside).transparency == 1)
    }

    @Test func accessibilityAndInvalidValuesHaveAnOpaqueFallback() {
        #expect(BackdropTransparency.opacity(.nan) == 1)
        #expect(BackdropTransparency.opacity(.infinity) == 1)
        #expect(BackdropTransparency.opacity(-1) == 1)
        #expect(abs(BackdropTransparency.opacity(1) - 0.16) < 0.00001)
        #expect(BackdropTransparency.opacity(1, reduced: true) == 1)
    }

    @MainActor @Test func changingTransparencyPreservesColorGradientAndNativeBlur() throws {
        _ = NSApplication.shared
        let color = try #require(NSColor(hex: "8DB6E6"))
        let extra = try #require(NSColor(hex: "EEA2C4"))
        let backdrop = WindowBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let solid = SpaceWash.Paint(color: color, grain: 0.4, colors: [extra], transparency: 0)
        backdrop.wear(solid)
        let stops = try #require(backdrop.coating.gradient.colors as? [CGColor])
        var glass = solid
        glass.transparency = 1
        backdrop.wear(glass)
        #expect(backdrop.coating.gradient.colors as? [CGColor] == stops)
        #expect(backdrop.glass.material == .hudWindow)
        #expect(backdrop.glass.blendingMode == .behindWindow)
        #expect(backdrop.glass.state == .active)
        #expect(backdrop.glass.alphaValue == 1)
        #expect(backdrop.subviews[0] === backdrop.glass)
        #expect(backdrop.subviews[1] === backdrop.veiled)
        #expect(backdrop.subviews[2] === backdrop.coating)
        let expected = BackdropTransparency.opacity(1, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        #expect(abs(Double(backdrop.coating.layer!.opacity) - expected) < 0.00001)
        #expect(backdrop.coating.layer?.backgroundColor == nil)
        #expect(backdrop.hitTest(.zero) == nil)
    }

    @MainActor @Test func resizingKeepsTheGlassAndGradientAcrossTheWholeWindow() {
        _ = NSApplication.shared
        let view = WindowBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.glass.frame == view.bounds)
        #expect(view.coating.frame == view.bounds)
        view.setFrameSize(NSSize(width: 800, height: 500))
        #expect(view.glass.frame == view.bounds)
        #expect(view.coating.frame == view.bounds)
        #expect(view.coating.gradient.frame == view.coating.bounds)
        #expect(view.coating.grain.frame == view.coating.bounds)
    }

    @MainActor @Test func spacePreviewReplacesThePreviousOpaqueCoating() throws {
        _ = NSApplication.shared
        let backdrop = WindowBackdropView(frame: .zero)
        backdrop.wear(SpaceWash.Paint(color: .red, grain: 0))
        #expect(backdrop.coating.layer?.opacity == 1)
        backdrop.setCover(1)
        #expect(backdrop.coating.layer?.opacity == 0)
        var next = SpaceWash.Paint(color: .blue, grain: 0, transparency: 1)
        backdrop.wear(next)
        #expect(backdrop.coating.layer?.opacity == 0)
        backdrop.setCover(0)
        let expected = BackdropTransparency.opacity(1, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        #expect(abs(Double(backdrop.coating.layer!.opacity) - expected) < 0.00001)
        next.transparency = 0
        backdrop.wear(next)
        #expect(backdrop.coating.layer?.opacity == 1)
    }
}
