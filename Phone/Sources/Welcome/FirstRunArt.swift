import SwiftUI
import UIKit

/// The first run's pieces (the "One chain" prototype, artifact unse3fvhd9 v4):
/// pen drawings with their marker swipe, the flat drop whose eye blinks, and
/// the sparks that burst out of whatever just happened.
/// Every path here is read from a Shape, which SwiftUI draws on its own
/// renderer thread as well as the main one, so none of this is main-actor
/// bound and the cache is kept under a lock (a MainActor.assumeIsolated here
/// traps the async renderer: the first run crashed on launch, 2026-11-10).
enum FirstRunPenArt {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGPath] = [:]

    /// A drawing's ink or its marker in PenArt's 384-point space: the first
    /// run's own words first, then Settings' drawings (the round "about" blot).
    static func path(_ name: String, marker: Bool) -> CGPath? {
        words(name + (marker ? ".marker" : ".ink")) {
            marker ? FirstRunPenWords.marker[name] : FirstRunPenWords.ink[name]
        }
    }

    static func mark(_ layer: String) -> CGPath? {
        words(layer + ".mark") { FirstRunPenWords.mark[layer] }
    }

    private static func words(_ key: String, _ make: () -> String?) -> CGPath? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        guard let made = make().flatMap(SettingsPenArt.parse) else { return nil }
        cache[key] = made
        return made
    }
}

/// One PenArt path, drawn into the rect it is given.
struct PenShape: Shape {
    let name: String
    var marker = false

    func path(in rect: CGRect) -> Path {
        guard let cg = FirstRunPenArt.path(name, marker: marker) else { return Path() }
        // PenArt's space: 384 square, y up, at a tenth (potrace's own).
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 384, y: rect.height / 384)
            .translatedBy(x: 0, y: 384).scaledBy(x: 0.1, y: -0.1)
        return Path(cg.copy(using: &t) ?? cg)
    }
}

/// A pen drawing as Settings draws its tiles: the marker swipe under, at .6
/// (.75 in dark), the ink over. `painted` runs the marker in from the left,
/// the way the found Mac's drawing gets its colour.
struct PenDrawing: View {
    let ink: String?
    var marker: String? = nil
    var tint: Color? = nil
    var painted: CGFloat = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let marker, let tint {
                PenShape(name: marker, marker: true)
                    .fill(tint)
                    .opacity(scheme == .dark ? 0.75 : 0.6)
                    .mask { Rectangle().scaleEffect(x: max(0.001, painted), y: 1, anchor: .leading) }
            }
            if let ink {
                PenShape(name: ink)
                    .fill(FirstRunInk.pen(scheme))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The flat drop (Icon/Alternates/07-flat.icon): body, cheek, face, and the
/// open eye on its own, so it can close (`eye` 0.12) and open (1).
struct FlatMark: View {
    var eye: CGFloat = 1
    /// Only the dark face and its eye, no blob: what the search field wears
    /// (the drop lands there as the field's eyes).
    var faceOnly = false

    var body: some View {
        ZStack {
            if !faceOnly {
                MarkLayer(layer: "blob").fill(Color(red: 0x2E / 255, green: 0xBC / 255, blue: 0xF6 / 255))
                MarkLayer(layer: "cheek").fill(Color(red: 0x01 / 255, green: 0x85 / 255, blue: 0xDA / 255))
            }
            MarkLayer(layer: "face").fill(Self.face)
            MarkLayer(layer: "eye").fill(Self.face)
                // About the eye's own middle (374, 525 of 1024).
                .scaleEffect(x: 1, y: eye, anchor: UnitPoint(x: 0.3657, y: 0.5127))
        }
        .accessibilityHidden(true)
    }

    static let face = Color(red: 0x07 / 255, green: 0x2B / 255, blue: 0x43 / 255)

    private struct MarkLayer: Shape {
        let layer: String
        func path(in rect: CGRect) -> Path {
            guard let cg = FirstRunPenArt.mark(layer) else { return Path() }
            var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 1024, y: rect.height / 1024)
            return Path(cg.copy(using: &t) ?? cg)
        }
    }
}

/// The app icon as the default-browser step makes it: the drop on paper.
struct ChainAppIcon: View {
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
            .fill(FirstRunInk.iconPaper(scheme))
            .overlay(FlatMark().padding(size * 0.02))
            .overlay(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The colours the prototype draws with, light and dark.
enum FirstRunInk {
    static func pen(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.945, green: 0.945, blue: 0.953) : Color(red: 0.11, green: 0.11, blue: 0.118)
    }
    /// Settings' tile paper (SettingsPenArt.drawTile).
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.169, green: 0.169, blue: 0.184) : Color(red: 0.984, green: 0.98, blue: 0.973)
    }
    /// The app icon's paper, a shade warmer than a tile's.
    static func iconPaper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.2, green: 0.2, blue: 0.21) : Color(red: 0.961, green: 0.961, blue: 0.945)
    }
    /// A keycap and what is written on it; joined, they swap (black keys).
    static func cap(_ scheme: ColorScheme, done: Bool) -> (fill: Color, letter: Color) {
        let light = (Color.white, Color(red: 0.067, green: 0.067, blue: 0.067))
        let dark = (Color(red: 0.173, green: 0.173, blue: 0.18), Color.white)
        let ink = scheme == .dark ? (Color.white, Color(red: 0.067, green: 0.067, blue: 0.067))
                                  : (Color(red: 0.067, green: 0.067, blue: 0.067), Color.white)
        return done ? ink : (scheme == .dark ? dark : light)
    }
    static let shield = Color(red: 0x2E / 255, green: 0xBC / 255, blue: 0xF6 / 255)
    static let shieldOff = Color(red: 0xB9 / 255, green: 0xB9 / 255, blue: 0xC2 / 255)
    static let teal = Color(red: 0x2F / 255, green: 0xA3 / 255, blue: 0xB8 / 255)
    static let yellow = Color(red: 0xE8 / 255, green: 0xB3 / 255, blue: 0x3A / 255)
    static let sky = Color(red: 0x36 / 255, green: 0xA7 / 255, blue: 0xD3 / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x53 / 255, blue: 0x4B / 255)
    static let orange = Color(red: 0xF0 / 255, green: 0x94 / 255, blue: 0x3A / 255)
    static let violet = Color(red: 0xA9 / 255, green: 0x6B / 255, blue: 0xE0 / 255)
    static let pink = Color(red: 0xE8 / 255, green: 0x4C / 255, blue: 0x6C / 255)
    static let green = Color(red: 0x34 / 255, green: 0xB8 / 255, blue: 0x5A / 255)
    static let blue = Color(red: 0x2F / 255, green: 0x8C / 255, blue: 0xF6 / 255)
    static let purple = Color(red: 0xAF / 255, green: 0x52 / 255, blue: 0xDE / 255)
    static let indigo = Color(red: 0x61 / 255, green: 0x5F / 255, blue: 0xD8 / 255)
}

/// Sparks flying out of a point: each goes out, overshoots a little and
/// fades as it falls (the prototype's sparks(), 560 ms).
struct SparkBurstView: View {
    let burst: FirstRun.Burst
    /// Its centre on screen, and the stage's scale.
    let center: CGPoint
    let scale: CGFloat
    @State private var p: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<burst.count, id: \.self) { i in
                Spark(progress: p, angle: angle(i), distance: burst.radius * scale * spread(i), size: (14 + 12 * jitter(i, 3)) * scale)
            }
        }
        .position(center)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.3, 1, duration: 0.56)) { p = 1 }
        }
    }

    private func angle(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(burst.count) * 2 * .pi + jitter(i, 1) * 0.6 }
    private func spread(_ i: Int) -> CGFloat { 0.7 + jitter(i, 2) * 0.5 }
    /// A fixed scatter per burst, so a still and a film agree.
    private func jitter(_ i: Int, _ k: Int) -> CGFloat {
        let v = sin(Double(burst.seed &* 31 &+ i &* 17 &+ k &* 7)) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }

    private struct Spark: View, Animatable {
        var progress: CGFloat
        let angle: CGFloat
        let distance: CGFloat
        let size: CGFloat
        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        var body: some View {
            // Out to the distance by 60%, then a little further, down and gone.
            let out = min(1, progress / 0.6)
            let late = max(0, (progress - 0.6) / 0.4)
            let reach = distance * (out + 0.15 * late)
            PenDrawing(ink: "spark")
                .frame(width: size, height: size)
                .scaleEffect(progress < 0.6 ? 0.2 + 0.8 * out : 1 - 0.5 * late)
                .opacity(1 - late)
                .offset(x: cos(angle) * reach, y: sin(angle) * reach + 8 * late)
        }
    }
}
