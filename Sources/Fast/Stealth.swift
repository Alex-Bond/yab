import SwiftUI

/// Going private, as one quiet moment: the page goes dark, and the field
/// says what kind of place this is, the glass turns into a mask, "Enter a
/// web address" runs into "Nothing here is kept" around nothing it has to
/// move, and a single light passes over the new words, the way a hidden
/// balance shows it is still live.
///
/// Only for the act of going private, ⌘⇧N, or New Private Tab from the
/// field, and only from a tab that kept things. Coming back to a private
/// tab, opening a link from one, going from one private tab to another, and
/// leaving: all simply there, in the frame the tab changes. That is the path
/// taken many times; this one is taken once, on purpose.
///
/// Everything is read off the time the tab went private rather than kept as
/// state, so a view that is already on screen when it happens and one that
/// arrives with the tab play the same moment, from the same first frame,
/// no frame of the finished look before it starts.
enum Stealth {
    /// The ground of a private tab: darker than the dark ground, so a
    /// private tab is told apart from a dark window too.
    static let ground = Color(white: 0.085)

    /// The page going dark.
    static let fade = Beat(delay: 0, duration: 0.22)
    /// The glass into the mask, the words into the new words.
    static let morph = Beat(delay: 0.06, duration: 0.24)
    /// The one light over the new words.
    static let shine = Beat(delay: 0.36, duration: 0.6)

    /// When the whole moment is over, after the tab went private.
    static let length = shine.delay + shine.duration

    struct Beat {
        let delay: TimeInterval
        let duration: TimeInterval

        /// How far along, 0 to 1, `at` after `start`, settling on the
        /// curve things arrive on. Done at once without a start, or when
        /// motion is to be kept down.
        func progress(since start: Date?, at now: Date, still: Bool) -> CGFloat {
            guard let start, !still else { return 1 }
            let t = (now.timeIntervalSince(start) - delay) / duration
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            return CGFloat(UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.2, y: 1)).value(at: t))
        }
    }

    /// Whether the moment is still playing for a tab that went private at
    /// `start`.
    static func playing(since start: Date?, still: Bool) -> Bool {
        guard let start, !still else { return false }
        return Date().timeIntervalSince(start) < length
    }
}

/// Redraws what is inside it every frame while the moment plays, and not a
/// frame after: a timeline left running would redraw a still field sixty
/// times a second for as long as the tab is open.
struct StealthClock<Content: View>: View {
    let since: Date?
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.accessibilityReduceMotion) private var still
    /// Bumped once the moment is over, so this is drawn again and the
    /// timeline finds it has stopped.
    @State private var over = 0

    var body: some View {
        let playing = Stealth.playing(since: since, still: still)
        TimelineView(.animation(minimumInterval: nil, paused: !playing)) { context in
            content(playing ? context.date : .distantFuture)
        }
        .task(id: since) {
            guard playing, let since else { return }
            let left = Stealth.length - Date().timeIntervalSince(since)
            try? await Task.sleep(for: .seconds(max(0, left) + 0.02))
            over += 1
        }
    }
}

/// The ground under a private tab's page: dark, and on the moment of going
/// private, the ordinary ground fading off it.
struct Hush: View {
    let since: Date?
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        StealthClock(since: since) { now in
            let p = Stealth.fade.progress(since: since, at: now, still: still)
            ZStack {
                Stealth.ground
                if p < 1 {
                    Palette.ground.opacity(1 - p)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Something that was light, going dark with the page as the tab goes
/// private: its old color laid over it, fading off on the page's beat.
/// Without it the field would be dark in the first frame, on a page still
/// light round it.
struct Unveil<S: Shape>: View {
    let since: Date?
    let shape: S
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        if Stealth.playing(since: since, still: still) {
            StealthClock(since: since) { now in
                shape.fill(color)
                    .opacity(1 - Stealth.fade.progress(since: since, at: now, still: still))
            }
            .allowsHitTesting(false)
        }
    }
}

/// What stands in the private field's first column: the mask, the glass
/// turning into it as the tab goes private.
struct StealthGlass: View {
    let since: Date?
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        StealthClock(since: since) { now in
            let p = Stealth.morph.progress(since: since, at: now, still: still)
            ZStack {
                if p < 1 {
                    Symbol("magnifyingglass", size: size)
                        .rotationEffect(.degrees(-30 * p))
                        .scaleEffect(1 - 0.3 * p)
                        .opacity(1 - p)
                }
                Symbol("incognito", size: size)
                    .scaleEffect(0.7 + 0.3 * p)
                    .opacity(p)
            }
            .foregroundStyle(Palette.muted)
        }
    }
}

/// The private field's words before anything is typed. Drawn here rather
/// than as the text field's own placeholder, so the old words can run into
/// the new and the light can pass over them, set in the field's own face,
/// size and gray, where the field would have set them.
struct StealthHint: View {
    let since: Date?
    static let before = "Enter a web address"
    static let after = "Nothing here is kept"
    private static let font = Font.system(size: 20)
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        StealthClock(since: since) { now in
            let p = Stealth.morph.progress(since: since, at: now, still: still)
            let s = Stealth.shine.progress(since: since, at: now, still: still)
            ZStack(alignment: .leading) {
                if p < 1 {
                    Text(Self.before)
                        .offset(y: -6 * p)
                        .opacity(1 - p)
                }
                Text(Self.after)
                    .offset(y: 6 * (1 - p))
                    .opacity(p)
                    .overlay(alignment: .leading) {
                        if s > 0, s < 1 {
                            GeometryReader { space in
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.6), .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: 44)
                                .offset(x: -44 + (space.size.width + 44) * s)
                            }
                            .mask(alignment: .leading) { Text(Self.after).font(Self.font) }
                        }
                    }
            }
            .font(Self.font)
            .foregroundStyle(Palette.ink.opacity(0.3))
            .lineLimit(1)
            .fixedSize()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
