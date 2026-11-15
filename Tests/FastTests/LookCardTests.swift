import AppKit
import SwiftUI
import Testing
@testable import Fast

struct LookCardTests {
    /// A space saved before the look card reads as it always did, and what
    /// the card adds is written only when it isn't the default.
    @MainActor @Test func oldPaintsReadPlainAndNewFieldsRoundTrip() throws {
        let old = Data(#"{"swatch":"custom","color":"8DB6E6","grain":true,"grainAmount":0.3,"colors":["B6A6E6"]}"#.utf8)
        let decoded = try JSONDecoder().decode(SpacePaint.self, from: old)
        #expect(!decoded.shift && !decoded.site && decoded.drawings.isEmpty)
        #expect(decoded.drawingsStrength == LookDrawings.standard)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(plain?["shift"] == nil && plain?["site"] == nil && plain?["drawings"] == nil && plain?["drawingsStrength"] == nil)

        let full = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0.3, colors: ["B6A6E6", "EEA2C4"],
                              shift: true, site: true, drawings: "life", drawingsStrength: 0.7)
        let restored = try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(full))
        #expect(restored == full)
        #expect(restored.drawings == "life" && restored.drawingsStrength == 0.7)

        // A set this build doesn't know, from a newer one, is no drawings.
        let strange = SpacePaint(swatch: .custom, color: .red, grain: 0, drawings: "space", drawingsStrength: 3)
        #expect(strange.drawings.isEmpty && strange.drawingsStrength == 1)
    }

    /// The presets are Arc's five pages of nine, every color a real one, and
    /// the grays reach black and white, which the field's lightness used to
    /// stop short of (0.30 to 0.95).
    @Test func presetsReachBlackAndWhite() throws {
        #expect(LookPresets.pages.count == 5)
        #expect(LookPresets.pages.allSatisfy { $0.presets.count == 9 })
        for page in LookPresets.pages {
            for preset in page.presets {
                #expect(NSColor(hex: preset.main) != nil)
                #expect(preset.links.allSatisfy { NSColor(hex: $0) != nil })
                #expect(preset.links.count <= 2)
            }
        }
        let grays = try #require(LookPresets.pages.last)
        let black = LookColor(try #require(NSColor(hex: grays.presets[8].main)))
        let white = LookColor(try #require(NSColor(hex: grays.presets[0].main)))
        #expect(black.lightness < 0.01 && white.lightness > 0.99)
        #expect(black.color.hex == "000000" && white.color.hex == "FFFFFF")
        // A gray sits in the middle of the wheel: no color, only lightness.
        #expect(abs(LookColor(NSColor(hex: "808080")!).point.x - 0.5) < 0.02)
        // The row opens on the preset a look came from, on its page.
        let from = LookPresets.index(of: NSColor(hex: "F37C5A")!, colors: ["F23B97", "EDF349"])
        #expect(from == 12 && LookPresets.all[from].page == 1 && LookPresets.starts[1] == 9)
        #expect(LookPresets.index(of: NSColor(hex: "123456")!, colors: []) == 0)
    }

    /// The presets' row: a page of nine where nine fit, as Arc's; narrower,
    /// as many as fit with a zone of at least 12 at each end for the next
    /// dots to peek into, fading (New Space's tray, 192 to 220 inside).
    @MainActor @Test func presetRowFadesWhereNineDoNotFit() {
        let card = LookPresetRow.layout(track: 266 - 48)
        #expect(card.paged && card.shown == 9 && card.fade == 3)
        for inside: CGFloat in [192, 200, 220] {
            let row = LookPresetRow.layout(track: inside - 48)
            #expect(!row.paged && row.shown >= 4 && row.fade >= 12)
            // The dots and their gaps, with both ends, fill the track.
            #expect(abs(CGFloat(row.shown) * 24 - 4 + row.fade * 2 - (inside - 48)) < 0.001)
        }
    }

    /// A space's own light or dark is kept with its look, and written only
    /// when it has one.
    @MainActor @Test func modeRoundTripsAndStaysOutWhenAuto() throws {
        let auto = SpacePaint(swatch: .custom, color: .red, grain: 0)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(auto)) as? [String: Any]
        #expect(plain?["mode"] == nil)
        let dark = SpacePaint(swatch: .custom, color: .red, grain: 0, mode: "dark")
        #expect(try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(dark)).mode == "dark")
        #expect(SpacePaint(swatch: .custom, color: .red, grain: 0, mode: "sepia").mode.isEmpty)
        #expect(LookMode(rawValue: "")?.appearance == nil)
        #expect(LookMode.dark.appearance?.name == .darkAqua)
    }

    /// Settings and the welcome set a look through the card's own controls.
    /// A look held whole (a space's in Settings) keeps the card's switches
    /// and drawings when its color moves, which 0.0.13's space page took
    /// off; the editor starts from a preset's own color, and a color moved is
    /// your own. The welcome's look carries all of it into the window's.
    @MainActor @Test func lookControlsKeepTheWholeLook() {
        final class Held { var paint: SpacePaint; init(_ paint: SpacePaint) { self.paint = paint } }
        let held = Held(SpacePaint(swatch: .sage, color: NSColor(hex: "8DB6E6")!, grain: 0.3, colors: ["B6A6E6"],
                                   shift: true, site: true, drawings: "browser", drawingsStrength: 0.6))
        let look = LookFields.paint(Binding(get: { held.paint }, set: { held.paint = $0 }))
        #expect(look.color.wrappedValue.hex == Swatch.sage.start(custom: held.paint.own).hex)
        look.color.wrappedValue = NSColor(hex: "EEA2C4")!
        #expect(held.paint.picked == .custom && held.paint.color == "EEA2C4")
        #expect(held.paint.shift && held.paint.site && held.paint.colors == ["B6A6E6"])
        #expect(held.paint.drawings == "browser" && held.paint.drawingsStrength == 0.6)
        look.drawings.wrappedValue = "life"
        look.strength.wrappedValue = 0.2
        look.shift.wrappedValue = false
        #expect(held.paint.drawings == "life" && held.paint.drawingsStrength == 0.2 && !held.paint.shift)

        var welcome = WelcomeHeldLook(backdrop: .color, swatch: .custom, color: NSColor(hex: "A8C3A0")!)
        welcome.colors = ["B6A6E6", "EEA2C4"]
        welcome.shift = true
        welcome.drawings = "life"
        welcome.strength = 0.3
        let prefs = Preferences()
        welcome.write(to: prefs)
        #expect(prefs.backdropColors == ["B6A6E6", "EEA2C4"] && prefs.lookShift)
        #expect(prefs.lookDrawings == "life" && prefs.lookDrawingsStrength == 0.3)
        let back = WelcomeHeldLook(prefs)
        #expect(back.colors == welcome.colors && back.shift && back.drawings == "life" && back.strength == 0.3)
    }

    /// Each set's drawings never touch, measured round the tile's edges as
    /// it repeats, and the tile is a real picture in both inks.
    @MainActor @Test func drawingsTileWithoutTouching() throws {
        for set in LookDrawings.Set.allCases {
            let items = LookDrawings.layout(set)
            #expect(items.count > 60)
            let side = LookDrawings.side
            for (i, a) in items.enumerated() {
                for b in items[(i + 1)...] {
                    var dx = abs(a.x - b.x), dy = abs(a.y - b.y)
                    dx = min(dx, side - dx)
                    dy = min(dy, side - dy)
                    #expect((dx * dx + dy * dy).squareRoot() >= (a.size + b.size) * 1.15 + 5 - 0.001)
                }
            }
            for white in [false, true] {
                let tile = LookDrawings.tile(set, white: white)
                #expect(tile.size == NSSize(width: side, height: side))
                let rep = try #require(tile.bitmapImageRepresentation())
                var inked = 0
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { inked += 1 }
                }
                #expect(inked > 200, "a \(set) tile in \(white ? "white" : "black") has hardly any lines")
            }
        }
        #expect(LookDrawings.light(on: NSColor(hex: "1D2132")!))
        #expect(!LookDrawings.light(on: NSColor(hex: "ECEAE4")!))
        #expect(LookDrawings.opacity(1, dark: false) > LookDrawings.opacity(0, dark: false))
    }

    /// The gradient turns a quarter at a time, the far end always opposite,
    /// and comes back round after four.
    @Test func gradientTurnsByQuarters() {
        for step in -4...8 {
            let ends = BackdropCoatingView.ends(step)
            #expect(abs(ends.start.x + ends.end.x - 1) < 0.001 && abs(ends.start.y + ends.end.y - 1) < 0.001)
            #expect(ends.start == BackdropCoatingView.ends(step + 4).start)
        }
        #expect(BackdropCoatingView.ends(0).start == CGPoint(x: 0, y: 1))
        #expect(BackdropCoatingView.ends(1).start == CGPoint(x: 1, y: 1))
    }

    /// The site's color tints the last of your colors, or makes a second one
    /// from the main color; off, or with no site color, nothing changes.
    @Test func siteColorTintsOneOfYours() throws {
        var paint = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0, colors: ["B6A6E6", "EEA2C4"])
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(LookCard.colors(paint, dark: false, site: red).map(\.hex) == ["B6A6E6", "EEA2C4"])
        paint.site = true
        #expect(LookCard.colors(paint, dark: false, site: nil).map(\.hex) == ["B6A6E6", "EEA2C4"])
        let tinted = LookCard.colors(paint, dark: false, site: red)
        #expect(tinted.count == 2 && tinted[0].hex == "B6A6E6" && tinted[1].hex != "EEA2C4")
        let last = try #require(tinted[1].usingColorSpace(.sRGB))
        #expect(last.redComponent > last.blueComponent)
        var single = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0)
        single.site = true
        #expect(LookCard.colors(single, dark: false, site: red).count == 1)
    }
}

private extension NSImage {
    func bitmapImageRepresentation() -> NSBitmapImageRep? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }
}
