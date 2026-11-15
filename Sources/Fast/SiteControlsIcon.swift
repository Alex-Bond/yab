import SwiftUI
import YabDesign

/// The round icon of a This site row (SiteControlsView.SettingRow), turning
/// on and off as picked (artifact MFf4zT9rJxTJtuHnwwcJiL, B): the ink fill
/// fades in and the glyph says what happened. The shield's tick draws
/// itself, or its cross; the moon swings in; the small window of Picture
/// in Picture flies out to its corner; the code brackets open. Turning off
/// the glyph only nods back inward, since it is the same glyph.
/// Other symbols keep the fill and stay still.
struct SiteControlsIcon: View {
    let symbol: String
    let on: Bool
    var live = false

    /// The shield's tick and cross, drawn as strokes so they can draw
    /// themselves. The one going fades out, and is put back undrawn after.
    @State private var tick: CGFloat
    @State private var tickShown: Double
    @State private var cross: CGFloat
    @State private var crossUp: CGFloat
    @State private var crossShown: Double
    @State private var turns = 0

    init(symbol: String, on: Bool, live: Bool = false) {
        self.symbol = symbol
        self.on = on
        self.live = live
        _tick = State(initialValue: on ? 1 : 0)
        _tickShown = State(initialValue: on ? 1 : 0)
        _cross = State(initialValue: on ? 0 : 1)
        _crossUp = State(initialValue: on ? 0 : 1)
        _crossShown = State(initialValue: on ? 0 : 1)
    }

    private static let side = (11 * Glyphs.scale).rounded()
    /// Fill and glyph color, both ways: short, the row is pressed often.
    private static let fade = Animation.easeInOut(duration: 0.18)
    /// The glyph's way out, with a little give: it happens once per press.
    private static let give = Spring(response: 0.29, dampingRatio: 0.62)
    /// Turning off, the glyph's nod inward and back, no give.
    private static let nod = Spring(response: 0.16, dampingRatio: 1)
    private static let lean: TimeInterval = 0.11
    /// On, the glyph waits where it sets off from for this long, so both
    /// ways have the same three keyframes: the builders take no if/else,
    /// which Xcode 27.1 refuses in a KeyframeTrack (no buildEither). The
    /// spring after it starts from rest: it would inherit a speed worked out
    /// over this one millisecond, and throw the part far out of its circle.
    private static let held: TimeInterval = 0.001

    private var glyph: SiteGlyph? {
        switch symbol {
        case "checkmark.shield", "xmark.shield": .shield
        case "moon": .moon
        case "pip": .pip
        case "chevron.left.forwardslash.chevron.right": .code
        default: nil
        }
    }

    private var color: Color { live ? .red : on ? Palette.ground : Palette.muted }

    var body: some View {
        ZStack {
            Circle().fill(live ? Color.red.opacity(0.14) : Palette.wash)
            Circle().fill(Palette.ink).opacity(on && !live ? 1 : 0)
            if let glyph {
                drawn(glyph).frame(width: Self.side, height: Self.side)
            } else {
                Symbol(symbol, size: 11, weight: .medium)
            }
        }
        .foregroundStyle(color)
        .frame(width: 28, height: 28)
        .animation(Self.fade, value: on)
        .onChange(of: on) { _, on in
            if glyph == .shield { turnShield(on) }
        }
    }

    private func turnShield(_ on: Bool) {
        turns += 1
        let turn = turns
        let out = Animation.easeOut(duration: 0.08)
        if on {
            tickShown = 1
            withAnimation(out) { crossShown = 0 } completion: {
                guard turns == turn else { return }
                cross = 0
                crossUp = 0
            }
            withAnimation(.easeOut(duration: 0.2).delay(0.07)) { tick = 1 }
        } else {
            crossShown = 1
            withAnimation(out) { tickShown = 0 } completion: {
                guard turns == turn else { return }
                tick = 0
            }
            withAnimation(.easeOut(duration: 0.11).delay(0.06)) { cross = 1 }
            withAnimation(.easeOut(duration: 0.11).delay(0.15)) { crossUp = 1 }
        }
    }

    private var line: StrokeStyle {
        StrokeStyle(lineWidth: Self.side / 12, lineCap: .round, lineJoin: .round)
    }

    @ViewBuilder
    private func drawn(_ glyph: SiteGlyph) -> some View {
        let unit = Self.side / 24
        switch glyph {
        case .shield:
            ZStack {
                SiteGlyphPart(part: .shield).stroke(style: line)
                SiteGlyphPart(part: .tick).trim(from: 0, to: tick).stroke(style: line)
                    .opacity(tickShown)
                Group {
                    SiteGlyphPart(part: .crossDown).trim(from: 0, to: cross).stroke(style: line)
                    SiteGlyphPart(part: .crossUp).trim(from: 0, to: crossUp).stroke(style: line)
                }
                .opacity(crossShown)
            }
        case .moon:
            SiteGlyphPart(part: .moon).stroke(style: line)
                .keyframeAnimator(initialValue: Swing(), trigger: on) { moon, swing in
                    moon.scaleEffect(swing.scale).rotationEffect(.degrees(swing.turn))
                } keyframes: { _ in
                    KeyframeTrack(\.turn) {
                        MoveKeyframe(on ? -60 : 0)
                        CubicKeyframe(on ? -60 : -16, duration: on ? Self.held : Self.lean)
                        SpringKeyframe(0, duration: on ? 0.44 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                    }
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(on ? 0.7 : 1)
                        CubicKeyframe(on ? 0.7 : 1, duration: on ? Self.held : Self.lean)
                        SpringKeyframe(1, duration: on ? 0.44 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                    }
                }
        case .pip:
            ZStack {
                SiteGlyphPart(part: .window).stroke(style: line)
                SiteGlyphPart(part: .smallWindow).stroke(style: line)
                    .keyframeAnimator(initialValue: Swing(), trigger: on) { small, swing in
                        small.scaleEffect(swing.scale, anchor: UnitPoint(x: 17 / 24, y: 17.5 / 24))
                            .offset(x: swing.shift * unit, y: swing.shift * unit)
                            .opacity(swing.shown)
                    } keyframes: { _ in
                        KeyframeTrack(\.shift) {
                            MoveKeyframe(on ? -6 : 0)
                            CubicKeyframe(on ? -6 : -1.8, duration: on ? Self.held : Self.lean)
                            SpringKeyframe(0, duration: on ? 0.4 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                        }
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(on ? 0.45 : 1)
                            CubicKeyframe(on ? 0.45 : 0.9, duration: on ? Self.held : Self.lean)
                            SpringKeyframe(1, duration: on ? 0.4 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                        }
                        KeyframeTrack(\.shown) {
                            MoveKeyframe(on ? 0 : 1)
                            LinearKeyframe(1, duration: 0.12)
                        }
                    }
            }
        case .code:
            ZStack {
                SiteGlyphPart(part: .bracketLeft).stroke(style: line)
                    .keyframeAnimator(initialValue: Swing(), trigger: on) { bracket, swing in
                        bracket.offset(x: -swing.shift * unit)
                    } keyframes: { _ in
                        KeyframeTrack(\.shift) {
                            MoveKeyframe(on ? -3.5 : 0)
                            CubicKeyframe(on ? -3.5 : -1.6, duration: on ? Self.held : Self.lean)
                            SpringKeyframe(0, duration: on ? 0.38 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                        }
                    }
                SiteGlyphPart(part: .bracketRight).stroke(style: line)
                    .keyframeAnimator(initialValue: Swing(), trigger: on) { bracket, swing in
                        bracket.offset(x: swing.shift * unit)
                    } keyframes: { _ in
                        KeyframeTrack(\.shift) {
                            MoveKeyframe(on ? -3.5 : 0)
                            CubicKeyframe(on ? -3.5 : -1.6, duration: on ? Self.held : Self.lean)
                            SpringKeyframe(0, duration: on ? 0.38 : Self.lean, spring: on ? Self.give : Self.nod, startVelocity: on ? 0 : nil)
                        }
                    }
            }
        }
    }
}

private enum SiteGlyph { case shield, moon, pip, code }

/// What a glyph's parts are doing; every way ends where it began.
private struct Swing {
    var turn: Double = 0
    var scale: CGFloat = 1
    var shift: CGFloat = 0
    var shown: Double = 1
}

/// Central's shield, moon, Picture in Picture and code glyphs (Glyphs.swift)
/// taken apart, on their 24-point grid.
private struct SiteGlyphPart: Shape {
    enum Part { case shield, tick, crossDown, crossUp, moon, window, smallWindow, bracketLeft, bracketRight }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        switch part {
        case .shield:
            path.move(to: p(20, 11.9123))
            path.addLine(to: p(20, 7.17737))
            path.addCurve(to: p(18.6502, 5.286), control1: p(20, 6.32338), control2: p(19.4578, 5.56361))
            path.addLine(to: p(12.6502, 3.2235))
            path.addCurve(to: p(11.3498, 3.22349), control1: p(12.2288, 3.07866), control2: p(11.7712, 3.07866))
            path.addLine(to: p(5.34984, 5.286))
            path.addCurve(to: p(4, 7.17737), control1: p(4.54224, 5.56361), control2: p(4, 6.32338))
            path.addLine(to: p(4, 11.9123))
            path.addCurve(to: p(12, 21.1579), control1: p(4, 16.8848), control2: p(8, 19))
            path.addCurve(to: p(20, 11.9123), control1: p(16, 19), control2: p(20, 16.8848))
            path.closeSubpath()
        case .tick:
            path.move(to: p(9.5, 11.75))
            path.addLine(to: p(11, 13.25))
            path.addLine(to: p(14.5, 9.75))
        case .crossDown:
            path.move(to: p(10, 9.5))
            path.addLine(to: p(14, 13.5))
        case .crossUp:
            path.move(to: p(14, 9.5))
            path.addLine(to: p(10, 13.5))
        case .moon:
            path.move(to: p(20.9638, 12.7674))
            path.addCurve(to: p(16.9961, 13.9998), control1: p(19.8361, 13.5447), control2: p(18.4693, 13.9998))
            path.addCurve(to: p(9.99609, 6.99975), control1: p(13.1301, 13.9998), control2: p(9.99609, 10.8657))
            path.addCurve(to: p(11.2283, 3.03223), control1: p(9.99609, 5.52667), control2: p(10.4511, 4.15987))
            path.addCurve(to: p(3, 11.9979), control1: p(6.61911, 3.42277), control2: p(3, 7.28768))
            path.addCurve(to: p(11.9981, 20.996), control1: p(3, 16.9674), control2: p(7.0286, 20.996))
            path.addCurve(to: p(20.9638, 12.7674), control1: p(16.7084, 20.996), control2: p(20.5734, 17.3767))
            path.closeSubpath()
        case .window:
            path.move(to: p(9, 17))
            path.addLine(to: p(5, 17))
            path.addCurve(to: p(3, 15), control1: p(3.89543, 17), control2: p(3, 16.1046))
            path.addLine(to: p(3, 7))
            path.addCurve(to: p(5, 5), control1: p(3, 5.89543), control2: p(3.89543, 5))
            path.addLine(to: p(17, 5))
            path.addCurve(to: p(19, 7), control1: p(18.1046, 5), control2: p(19, 5.89543))
            path.addLine(to: p(19, 11))
        case .smallWindow:
            path.addRoundedRect(in: CGRect(origin: p(13, 15), size: CGSize(width: 8 * unit, height: 5 * unit)),
                                cornerSize: CGSize(width: unit, height: unit))
        case .bracketLeft:
            path.move(to: p(7, 16))
            path.addLine(to: p(3.70711, 12.7071))
            path.addCurve(to: p(3.70711, 11.2929), control1: p(3.31658, 12.3166), control2: p(3.31658, 11.6834))
            path.addLine(to: p(7, 8))
        case .bracketRight:
            path.move(to: p(17, 8))
            path.addLine(to: p(20.2929, 11.2929))
            path.addCurve(to: p(20.2929, 12.7071), control1: p(20.6834, 11.6834), control2: p(20.6834, 12.3166))
            path.addLine(to: p(17, 16))
        }
        return path
    }
}
