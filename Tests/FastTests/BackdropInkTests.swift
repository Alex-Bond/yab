import XCTest
@testable import Fast

/// The words on a backdrop stand off it: the swatches keep the shades they
/// were drawn with, a mid gray site color has its words pushed off it, and
/// a see-through backdrop's frost is held on its color's side.
@MainActor
final class BackdropInkTests: XCTestCase {
    private func shades(_ color: NSColor) -> Shades {
        Shades(on: color, dark: Tone(color).scheme == .dark)
    }

    func testTheSwatchesKeepTheirShades() {
        for swatch in Swatch.presets {
            for dark in [false, true] {
                let color = swatch.color(dark: dark, custom: .white)
                let (_, c, h) = color.oklch
                let made = shades(color)
                let isDark = Tone(color).scheme == .dark
                let muted = NSColor(oklch: (isDark ? 0.8 : 0.38, min(0.13, c * (isDark ? 0.45 : 0.95)), h))
                let faint = NSColor(oklch: (isDark ? 0.62 : 0.56, min(0.13, c * (isDark ? 0.45 : 0.75)), h))
                XCTAssertEqual(made.mutedNS.hex, muted.hex, "\(swatch) dark \(dark)")
                XCTAssertEqual(made.faintNS.hex, faint.hex, "\(swatch) dark \(dark)")
            }
        }
    }

    /// The faintest words are white or black let through, not a gray of
    /// their own (Nate Parrott, 2026-10-24: back and forward and New tab
    /// read gray on a purple space): as far off the color as the shade,
    /// and no further than a step past it.
    func testFaintWordsAreLetThroughAsFarAsTheShade() {
        let colors = Swatch.presets.flatMap { swatch in [false, true].map { swatch.color(dark: $0, custom: .white) } }
            + [NSColor(srgbRed: 0x6B / 255, green: 0x4F / 255, blue: 0xE0 / 255, alpha: 1)]
        for color in colors {
            let made = shades(color)
            let end: NSColor = Tone(color).scheme == .dark ? .white : .black
            let drawn = end.mixed(over: color, made.faintLift)
            let goal = made.faintNS.contrast(with: color)
            XCTAssertGreaterThanOrEqual(drawn.contrast(with: color), goal - 0.01, color.hex)
            XCTAssertLessThan(end.mixed(over: color, made.faintLift - 0.01).contrast(with: color), goal, color.hex)
        }
    }

    /// New tab's row on a color stands further off it than the faint
    /// words and no further than the muted (owner, 2026-10-24: still gray).
    func testQuietRowIsBetweenFaintAndMuted() {
        let colors = Swatch.presets.flatMap { swatch in [false, true].map { swatch.color(dark: $0, custom: .white) } }
            + [NSColor(srgbRed: 0x6B / 255, green: 0x4B / 255, blue: 0xC8 / 255, alpha: 1),
               NSColor(srgbRed: 0xF7 / 255, green: 0xEB / 255, blue: 0xA6 / 255, alpha: 1)]
        for color in colors {
            let made = shades(color)
            let end: NSColor = Tone(color).scheme == .dark ? .white : .black
            XCTAssertGreaterThanOrEqual(made.quietLift, made.faintLift, color.hex)
            XCTAssertLessThanOrEqual(end.mixed(over: color, made.quietLift - 0.01).contrast(with: color), made.mutedNS.contrast(with: color), color.hex)
        }
    }

    func testAMidGrayPushesItsWordsOff() {
        for v in stride(from: 0x60, through: 0xB0, by: 8) {
            let gray = NSColor(srgbRed: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v) / 255, alpha: 1)
            let made = shades(gray)
            // As far as white or black goes on a gray this deep.
            let end: NSColor = Tone(gray).scheme == .dark ? .white : .black
            let most = end.contrast(with: gray)
            let name = String(format: "#%02X", v)
            XCTAssertGreaterThanOrEqual(made.mutedNS.contrast(with: gray), min(Shades.least.muted, most) - 0.01, name)
            XCTAssertGreaterThanOrEqual(made.faintNS.contrast(with: gray), min(Shades.least.faint, most) - 0.01, name)
        }
        let youtube = NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
        XCTAssertGreaterThan(shades(youtube).faintNS.contrast(with: youtube), 5)
    }

    func testTheFrostTakesTheColorsSide() {
        let youtube = NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
        XCTAssertEqual(BackdropVeil.appearance(for: youtube)?.name, .darkAqua)
        XCTAssertEqual(BackdropVeil.veil(for: youtube).usingColorSpace(.sRGB)?.redComponent ?? -1, 0, accuracy: 0.01)
        let pale = NSColor(srgbRed: 0xCF / 255, green: 0xF0 / 255, blue: 1, alpha: 1)
        XCTAssertEqual(BackdropVeil.appearance(for: pale)?.name, .aqua)
    }

    /// The card's ground over the worst page for its side, as it composites.
    private func cardGround(_ end: NSColor, color: NSColor, colors: [NSColor], transparency: Double) -> NSColor {
        let dark = BackdropVeil.dark(color)
        let veil = BackdropVeil.cardVeil(color, colors: colors, transparency: transparency)
        let under = (dark ? NSColor.black : .white).mixed(over: dark ? .white : .black, veil)
        return end.mixed(over: under, CGFloat(BackdropTransparency.opacity(transparency)))
    }

    /// A see-through card's words hold over any page: a light color's over
    /// black, a dark one's over white, at every end of its gradient. The
    /// 2026-10-08 case: #93A9F9 to #2AC8BB at 0.51 over X's black page, its
    /// words at 2.5 and 1.1 to 1 with the veil at 0.2.
    func testACardsWordsHoldOverAnyPage() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        let own = NSColor(srgbRed: 0x93 / 255, green: 0xA9 / 255, blue: 0xF9 / 255, alpha: 1)
        let teal = NSColor(srgbRed: 0x2A / 255, green: 0xC8 / 255, blue: 0xBB / 255, alpha: 1)
        let cases: [(NSColor, [NSColor])] = [(own, [teal]), (own.deepened, [teal.deepened])]
            + Swatch.presets.flatMap { swatch in [false, true].map { (swatch.color(dark: $0, custom: .white), [NSColor]()) } }
        for (color, colors) in cases {
            let words = Shades.deep(on: color, dark: BackdropVeil.dark(color))
            for t in [0.1, 0.25, 0.51325, 0.75, 1] {
                for end in [color] + colors {
                    let ground = cardGround(end, color: color, colors: colors, transparency: t)
                    let name = "\(color.hex) at \(t)"
                    XCTAssertGreaterThanOrEqual(words.mutedNS.contrast(with: ground), BackdropVeil.cardLeast.muted, name)
                    XCTAssertGreaterThanOrEqual(words.faintNS.contrast(with: ground), BackdropVeil.cardLeast.faint, name)
                }
            }
        }
        // Still see-through: the lab's pick kept the veil near half at 0.51.
        XCTAssertLessThanOrEqual(BackdropVeil.cardVeil(own, colors: [teal], transparency: 0.51325), 0.5)
    }

    func testAnOpaqueCardKeepsTheSwatchsWords() {
        let peach = Swatch.peach.color(dark: false, custom: .white)
        XCTAssertEqual(BackdropVeil.cardVeil(peach, transparency: 0), BackdropVeil.cardOpacity, accuracy: 0.001)
        let opaque = Tone(peach, lifted: true).card(SpaceWash.Paint(color: peach, grain: 0))
        XCTAssertFalse(opaque.seeThrough)
        XCTAssertEqual(Palette.shades(opaque).mutedNS.hex, shades(peach).mutedNS.hex)
        let clear = Tone(peach, lifted: true).card(SpaceWash.Paint(color: peach, grain: 0, transparency: 0.5))
        XCTAssertEqual(clear.seeThrough, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        // A card on a glass look is a frosted card like any other: the
        // page's frost and the card's veil, not the glass's whites.
        let glass = Tone(peach, lifted: true, glass: true).card(SpaceWash.Paint(color: peach, grain: 0, transparency: 0.5, glass: true))
        XCTAssertFalse(glass.glass)
        XCTAssertEqual(glass.seeThrough, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    /// New tab's words on a site's color stand off the site's own ground,
    /// not only off the darker gray the column's words stand in with
    /// (Tone.columnInk): on a mid gray page they were lost (request 1008).
    func testNewTabRowStandsOffTheSitesOwnColor() {
        for v in stride(from: 0x70, through: 0x98, by: 4) {
            let site = NSColor(srgbRed: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v) / 255, alpha: 1)
            guard let stand = Tone.columnInk(Tone(site, lifted: true)), stand.ink else { continue }
            let end: NSColor = stand.scheme == .dark ? .white : .black
            let tone = Quiet.inkTone(stand, site: site)!
            let drawn = end.mixed(over: site, Palette.shades(tone).quietLift)
            let name = String(format: "#%02X", v)
            XCTAssertGreaterThanOrEqual(drawn.contrast(with: site), min(2.3, end.contrast(with: site)) - 0.05, name)
        }
        // On the light side the stand-in is the lighter gray, which asks
        // for the deeper words: it is kept.
        let pale = NSColor(srgbRed: 0xA0 / 255, green: 0xA0 / 255, blue: 0xA0 / 255, alpha: 1)
        if let stand = Tone.columnInk(Tone(pale, lifted: true)), stand.ink, stand.scheme == .light {
            XCTAssertEqual(Quiet.inkTone(stand, site: pale), stand)
        }
        // Not on a site's color: the column's own tone, as before.
        let gray = Tone(NSColor(white: 0.5, alpha: 1))
        XCTAssertEqual(Quiet.inkTone(gray, site: .red), gray)
    }
}
