import SwiftUI

/// A sheet that grows out of what summoned it and goes back there, or rises
/// from below and drops away when there is nothing to go back to: the
/// prototype's "code, yes" surfaces, which Settings, its pages and joining a
/// Mac move like (motion.md, "Settings": as code, yes).
///
///  - from an origin: the sheet is clipped from the origin's rect, at the
///    origin's own radius (a settings row's 16, a capsule's half height),
///    out to its own bounds at 34, sheetGrow (340 ms), then takes its own
///    corners; its words fade in and rise 8 a little later, sheetContents
///    (220 ms after 90).
///  - no origin: up from 105 % of its height, sheetRise (300 ms).
///  - back: into the origin if it is still on screen, sheetBack (260 ms) with
///    the words out first (120 ms); else down 60 % and away, sheetDrop.
///  - Reduce Motion: no morphs, a plain cross-fade both ways (Motion.reduced).
///  - plain (Settings): never from an origin; up from its own height below
///    and down out of sight the same way, opaque all along, each by its own
///    motion.
///
/// Each entrance and exit is noted by name in the motion journal of test
/// runs (TaskMotion.note, YAB_MOTION_JOURNAL), so a UI test can tell a page
/// that grew out of its row from one that rose from nowhere.
@MainActor
@Observable
final class GrowingSurface {
    /// A plain sheet's own movements: up as it opens, down as it closes.
    struct Plain: Sendable {
        let up: Motion
        let down: Motion
    }

    /// Set for a plain sheet: no origin, no fade, its own up and down.
    let plain: Plain?

    init(plain: Plain? = nil) {
        self.plain = plain
    }

    /// In the tree at all: from the moment it is shown until it has gone.
    private(set) var presented = false
    /// 0 at its origin (or below the screen), 1 in its place.
    private(set) var grown: CGFloat = 1
    /// What it holds: 0 hidden and 8 lower, 1 in place.
    private(set) var contents: Double = 1
    /// Leaving downward: 0 in place, 1 gone.
    private(set) var dropped: CGFloat = 0
    /// The finger's pull down, in points.
    var drag: CGFloat = 0
    /// Where it grows from, in the coordinates of the place it stands in.
    private(set) var origin: CGRect?
    /// The origin's corner radius: where the clip's corners start.
    private(set) var originRadius: CGFloat = Metrics.Settings.originRadius
    /// Whether the last show grew from an origin (for tests and notes).
    private(set) var grewFromOrigin = false
    /// In its place and still: arrived, not leaving. What it covers can
    /// step out of the tree meanwhile.
    private(set) var settled = false

    /// Each show and hide counts, so a late completion of an old movement
    /// never undoes a newer one.
    @ObservationIgnored private var generation = 0
    /// Shown, its entrance still to run once its view is on screen.
    @ObservationIgnored private var entering = false

    /// The motion the next show runs, by where it comes from.
    static func entrance(from origin: CGRect?) -> Motion {
        origin == nil ? .sheetRise : .sheetGrow
    }

    /// The motion the next hide runs, by whether its origin is still there.
    static func exit(back: Bool) -> Motion {
        back ? .sheetBack : .sheetDrop
    }

    /// `radius` is the origin's own: a row's 16 unless it says otherwise.
    func show(from origin: CGRect?, radius: CGFloat = Metrics.Settings.originRadius) {
        generation += 1
        let wasPresented = presented
        let origin = Motion.reduced || plain != nil ? nil : origin
        let instant = Motion.disabled
        grewFromOrigin = origin != nil
        still {
            self.origin = origin
            self.originRadius = radius
            self.grown = instant ? 1 : 0
            self.dropped = 0
            self.drag = 0
            self.contents = (origin == nil || instant) ? 1 : 0
            self.presented = true
            self.settled = instant
        }
        entering = !instant
        // A view that arrives already moved shows its end at once: a new one
        // moves once it is on screen (appeared), one still there moves now.
        if wasPresented { appeared() }
    }

    /// The surface's view is on screen: its entrance runs now.
    func appeared() {
        guard entering else { return }
        entering = false
        let turn = generation
        let motion = plain?.up ?? Self.entrance(from: origin)
        TaskMotion.note(motion)
        motion.run({ self.grown = 1 }, completion: { [self] in
            if turn == generation { settled = true }
        })
        if origin != nil { Motion.sheetContents.run { self.contents = 1 } }
    }

    /// Away: back into the origin when `back` (it is still on screen), else down.
    func hide(back: Bool, then done: (() -> Void)? = nil) {
        guard presented else { done?(); return }
        settled = false
        generation += 1
        let turn = generation
        let finish = { [self] in
            guard turn == generation else { return }
            still { self.reset() }
            done?()
        }
        if Motion.disabled {
            finish()
            return
        }
        let intoOrigin = back && origin != nil && !Motion.reduced
        let motion = intoOrigin ? Self.exit(back: true) : plain?.down ?? Self.exit(back: false)
        TaskMotion.note(motion)
        if intoOrigin {
            Motion.sheetContentsOut.run { self.contents = 0 }
            motion.run({ self.grown = 0 }, completion: finish)
        } else {
            motion.run({ self.dropped = 1 }, completion: finish)
        }
    }

    /// Let go of past the close line: on down from where the finger left it.
    func flick(height: CGFloat, then done: (() -> Void)? = nil) {
        guard presented else { done?(); return }
        settled = false
        generation += 1
        let turn = generation
        let finish = { [self] in
            guard turn == generation else { return }
            still { self.reset() }
            done?()
        }
        if Motion.disabled {
            finish()
            return
        }
        TaskMotion.note(Motion.sheetFlick)
        Motion.sheetFlick.run({ self.drag = height }, completion: finish)
    }

    /// Let go of short of it: back in place.
    func snap() {
        guard drag != 0 else { return }
        Motion.sheetSnap.run { self.drag = 0 }
    }

    /// Gone at once, without moving: the sheet it stands in has gone.
    /// How much of it is there, 0 to 1: up, not dropped, not pulled down
    /// (of `height`), for what dims behind it.
    func presence(height: CGFloat) -> Double {
        let pulled = height > 0 ? min(max(drag / height, 0), 1) : 0
        return Double(grown) * (1 - Double(dropped)) * Double(1 - pulled)
    }

    func dismissNow() {
        generation += 1
        still { reset() }
    }

    private func reset() {
        entering = false
        settled = false
        presented = false
        grown = 1
        contents = 1
        dropped = 0
        drag = 0
        origin = nil
        originRadius = Metrics.Settings.originRadius
    }

    private func still(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// The surface's shape while it grows: the prototype's clip-path inset, from
/// the origin's rect at the origin's radius out to its own bounds at 34 on
/// every corner. Arrived, it is the sheet's own shape: its top corners at the
/// sheet's radius, the bottom ones at the screen's edge.
struct GrowClip: Shape {
    var origin: CGRect
    var originRadius: CGFloat
    var topRadius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(progress, 0), 1)
        if p >= 1 {
            return UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: topRadius, style: .continuous)
                .path(in: rect)
        }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let frame = CGRect(x: mix(origin.minX, rect.minX), y: mix(origin.minY, rect.minY),
                           width: mix(origin.width, rect.width), height: mix(origin.height, rect.height))
        let radius = min(mix(originRadius, Metrics.Settings.growRadius), frame.height / 2, frame.width / 2)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: frame)
    }
}

extension View {
    /// Places a surface's movement on the view: its clip while it grows, its
    /// rise, drop and pull, its fade under Reduce Motion. `size` is the
    /// surface's own; its origin is in the same coordinates.
    func growing(_ surface: GrowingSurface, size: CGSize, topRadius: CGFloat) -> some View {
        modifier(GrowingSurfaceStyle(surface: surface, size: size, topRadius: topRadius))
    }

    /// What a surface holds: in a little after the surface has grown.
    func surfaceContents(_ surface: GrowingSurface) -> some View {
        opacity(surface.contents)
            .offset(y: Metrics.Settings.contentsRise * (1 - surface.contents))
    }
}

private struct GrowingSurfaceStyle: ViewModifier {
    let surface: GrowingSurface
    let size: CGSize
    let topRadius: CGFloat

    func body(content: Content) -> some View {
        let reduced = Motion.reduced
        let origin = surface.origin
        let plain = surface.plain != nil
        let rising = origin == nil && !reduced
        let rise = rising ? (1 - surface.grown) * (plain ? 1 : Metrics.Settings.riseFrom) * size.height : 0
        // Reduce Motion: neither rise nor drop, only the fade (in by
        // `grown`, out by `dropped`). A plain sheet drops out of sight, opaque.
        let drop = reduced ? 0 : surface.dropped * (plain ? 1 : Metrics.Settings.dropTo) * size.height
        content
            .clipShape(GrowClip(origin: origin ?? CGRect(origin: .zero, size: size),
                                originRadius: surface.originRadius,
                                topRadius: topRadius,
                                progress: origin == nil ? 1 : surface.grown))
            .shadow(color: Ink.shadow.opacity(Metrics.Settings.shadowOpacity * Double(surface.grown)),
                    radius: Metrics.Settings.shadowRadius, y: Metrics.Settings.shadowY)
            .offset(y: rise + drop + max(0, surface.drag))
            .opacity((reduced ? Double(surface.grown) : 1) * (plain && !reduced ? 1 : 1 - Double(surface.dropped)))
    }
}
