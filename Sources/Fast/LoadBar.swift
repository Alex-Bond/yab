import AppKit
import Combine
import SwiftUI

/// A page taking its time, said the way Arc says it, over the page's top
/// edge: a short capsule breathing while the server says nothing, stretched
/// into a track with a run of fill along it once the page comes in, filled
/// and drawn in to its middle as the page paints. A page that paints within
/// 0.4 s never shows it. It ends where the tab's ring does (TabBar): at the
/// page's first paint (Tab.drawn), not its load event.
///
/// Layers only, every motion on the render server: the main thread hears of
/// it a few times a load, as the phase changes. Measured off Arc's own, 120
/// frames a second: 44 by 3.5 points, breathing 25 to 70% over 1.6 s; 128
/// once coming, the fill's run 1 s, growing 0.35, leaving 0.35, empty 0.3.
///
/// Arc's breathing 44-point dash was missed by people waiting on a slow
/// server (feedback register #408: "stuck on a page ... without a loading
/// state"): a gray dash at a quarter to two thirds of the ink, over the
/// card's top, read as part of the frame. Safari and Dia put a bar along
/// the address at once, Chrome spins the tab's icon. So, `clear`, the bar
/// comes with the tab's ring and Stop (0.15 s, Tab.ringAfter) and is the
/// whole track with Arc's run from the start, the server answered or not,
/// its fill darker: one motion from the click to the paint, never a jump
/// at the commit.
/// YAB_LOAD_CLEAR=0 brings Arc's dash back, for an A/B on one build.
final class LoadBar: NSView {
    enum Phase: String { case idle, waiting, coming }

    static let short: CGFloat = 44
    static let long: CGFloat = 128
    static let thick: CGFloat = 3.5
    /// The clear bar (#408), on unless YAB_LOAD_CLEAR=0.
    nonisolated static let clear = ProcessInfo.processInfo.environment["YAB_LOAD_CLEAR"] != "0"
    /// How long a page may take before anything is said: as long as the
    /// tab's ring waits, or Arc's 0.4 s for its dash.
    nonisolated static var patience: TimeInterval { clear ? 0.15 : 0.4 }
    /// The fill's ink.
    nonisolated static var fillInk: Float { clear ? 0.9 : 0.75 }

    /// What the bar says of a tab now: nothing once its page has painted or
    /// the load is over; coming once the server has answered and the page
    /// committed; waiting before that.
    nonisolated static func phase(loading: Bool, drawn: Bool, answered: Bool) -> Phase {
        guard loading && !drawn else { return .idle }
        return answered ? .coming : .waiting
    }

    /// How much longer a load `waited` seconds old goes before the bar
    /// shows: none once past the patience.
    nonisolated static func showIn(waited: TimeInterval) -> TimeInterval {
        max(0, patience - max(0, waited))
    }
    /// The view's size: the longest track and a plate's rim round it.
    static let size = CGSize(width: long + 16, height: 14)

    /// Every bar up, for the bench.
    @MainActor static let all = NSHashTable<LoadBar>.weakObjects()

    /// On a plate of the page's ground, for a bar over a page rather than
    /// over the window's own: a peek's, or a page edge to edge.
    var plated = false { didSet { if plated != oldValue { dress() } } }
    /// The plate's rim beside and above the bar.
    var rim = CGSize(width: 6, height: 3.5) { didSet { if rim != oldValue { dress() } } }

    private let plate = CALayer()
    private let bar = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var phase = Phase.idle
    private var shown = false
    /// Counts the times it came, so an ending finishing late leaves a bar
    /// that came again alone.
    private var round = 0
    private weak var tab: Tab?
    private var watching: Set<AnyCancellable> = []
    private var due: DispatchWorkItem?

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        // The bar's middle is its origin, so it grows and shrinks from there
        // with its bounds alone.
        for each in [plate, bar] {
            each.bounds = CGRect(x: -Self.short / 2, y: -Self.thick / 2, width: Self.short, height: Self.thick)
            each.cornerCurve = .continuous
        }
        bar.cornerRadius = Self.thick / 2
        bar.masksToBounds = true
        track.frame = CGRect(x: -Self.long / 2, y: -Self.thick / 2, width: Self.long, height: Self.thick)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.bounds = CGRect(x: 0, y: 0, width: 0, height: Self.thick)
        fill.position = CGPoint(x: -Self.long / 2, y: 0)
        bar.addSublayer(track)
        bar.addSublayer(fill)
        plate.isHidden = true
        plate.borderWidth = 0.5
        layer?.addSublayer(plate)
        layer?.addSublayer(bar)
        for each in [plate, bar, track, fill] { each.actions = LoadBar.quiet }
        bar.opacity = 0
        plate.opacity = 0
        dress()
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { nil }

    private static let quiet: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(),
        "borderColor": NSNull(), "hidden": NSNull(), "contents": NSNull(),
    ]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        bar.position = middle
        plate.position = middle
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dress()
    }

    /// Colors as the window wears them now.
    private func dress() {
        var ink = NSColor.labelColor.cgColor
        var ground = Palette.NS.ground.withAlphaComponent(0.92).cgColor
        var edge = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
            ground = Palette.NS.ground.withAlphaComponent(0.92).cgColor
            edge = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = ink
        fill.backgroundColor = ink
        plate.backgroundColor = ground
        plate.borderColor = edge
        plate.cornerRadius = Self.thick / 2 + rim.height
        plate.isHidden = !plated
        CATransaction.commit()
    }

    // MARK: - the tab

    /// The tab it speaks for, or none.
    func bind(_ tab: Tab?) {
        guard tab !== self.tab else { return }
        self.tab = tab
        watching.removeAll()
        due?.cancel()
        settle()
        guard let tab else { return }
        // Heard a turn later: @Published says so before the value changes.
        Publishers.Merge3(tab.changes(\.loading).map { _ in () }, tab.changes(\.drawn).map { _ in () }, tab.loadMoved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.follow(fresh: false) } }
            .store(in: &watching)
        follow(fresh: true)
    }

    /// `fresh`: just put up over a tab that may have been loading a while,
    /// a tab come back to: shown as it stands, with no coming.
    private func follow(fresh: Bool) {
        guard let tab else { return }
        let want = Self.phase(loading: tab.loading, drawn: tab.drawn, answered: tab.answered)
        guard want != phase else { return }
        let was = phase
        phase = want
        if want == .idle {
            due?.cancel()
            guard shown else { return }
            end(painted: tab.drawn && !tab.stoppedEarly && tab.failure == nil)
            return
        }
        if was == .idle {
            let wait = Self.showIn(waited: Date().timeIntervalSince(tab.loadStarted))
            if wait <= 0 {
                show(instant: fresh)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.phase != .idle, !self.shown else { return }
                        self.show(instant: false)
                    }
                }
                due = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            }
            return
        }
        if shown { draw(want, animated: true) }
    }

    // MARK: - motion

    private func show(instant: Bool) {
        shown = true
        round += 1
        for each in [bar, track, fill, plate] { each.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        size(phase == .coming || Self.clear ? Self.long : Self.short, from: nil, over: 0)
        bar.opacity = 1
        plate.opacity = 1
        CATransaction.commit()
        if !instant && !still {
            run(bar, "opacity", from: 0, to: 1, 0.2, .easeOut)
            run(plate, "opacity", from: 0, to: 1, 0.2, .easeOut)
        }
        draw(phase, animated: false)
    }

    private func draw(_ phase: Phase, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch phase {
        case .idle:
            break
        case .waiting where Self.clear, .coming where Self.clear:
            // The whole track and its run, whichever: a run already going
            // (waiting, then coming, or another link taken) goes on as it is.
            size(Self.long, from: nil, over: 0)
            track.removeAnimation(forKey: "breath")
            track.opacity = still ? 0.45 : 0.2
            if !still, fill.animation(forKey: "run") == nil { runFill() }
        case .waiting:
            // Another link taken while a page came in: short again.
            let width = bar.presentation()?.bounds.width ?? bar.bounds.width
            if animated && !still && width > Self.short {
                size(Self.short, from: width, over: 0.25)
            } else {
                size(Self.short, from: nil, over: 0)
            }
            fill.removeAllAnimations()
            fill.opacity = 0
            track.opacity = still ? 0.45 : 0.25
            if !still {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 0.25
                breath.toValue = 0.7
                breath.duration = 0.8
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                track.add(breath, forKey: "breath")
            }
        case .coming:
            let was = track.presentation()?.opacity ?? track.opacity
            track.removeAnimation(forKey: "breath")
            track.opacity = still ? 0.45 : 0.2
            if animated && !still {
                size(Self.long, from: bar.presentation()?.bounds.width ?? Self.short, over: 0.3)
                run(track, "opacity", from: was, to: 0.2, 0.3, .easeOut)
            } else {
                size(Self.long, from: nil, over: 0)
            }
            if !still { runFill() }
        }
        CATransaction.commit()
    }

    /// The fill's run along the track: from the left to the end, away off
    /// the end, a beat of nothing, and again.
    private func runFill() {
        fill.opacity = Self.fillInk
        let left = -Self.long / 2
        let place = CAKeyframeAnimation(keyPath: "position.x")
        place.values = [left, left, left + Self.long, left + Self.long]
        let wide = CAKeyframeAnimation(keyPath: "bounds.size.width")
        wide.values = [0, Self.long, 0, 0]
        let group = CAAnimationGroup()
        for each in [place, wide] {
            each.keyTimes = [0, 0.35, 0.7, 1]
            each.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
        }
        group.animations = [place, wide]
        group.duration = 1.0
        group.repeatCount = .infinity
        fill.add(group, forKey: "run")
    }

    /// `painted`: the fill to the end and the bar drawn in to its middle;
    /// otherwise, stopped or failed, only drawn in.
    private func end(painted: Bool) {
        shown = false
        let mine = round
        let width = bar.presentation()?.bounds.width ?? bar.bounds.width
        let fillAt = fill.presentation()?.position.x ?? fill.position.x
        let fillWide = fill.presentation()?.bounds.width ?? fill.bounds.width
        let trackAt = track.presentation()?.opacity ?? track.opacity
        for each in [track, fill] { each.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.opacity = trackAt
        let lead: CFTimeInterval = painted && !still ? 0.15 : 0
        if painted && !still && phase != .waiting {
            // The fill from where it was to the whole track.
            fill.opacity = Self.fillInk
            fill.position.x = -Self.long / 2
            fill.bounds.size.width = Self.long
            run(fill, "position.x", from: fillAt, to: -Self.long / 2, lead, .easeOut)
            run(fill, "bounds.size.width", from: fillWide, to: Self.long, lead, .easeOut)
        }
        let away: CFTimeInterval = still ? 0.15 : (painted ? 0.3 : 0.25)
        if !still { size(width * 0.55, from: width, over: away, after: lead, curve: .easeIn) }
        bar.opacity = 0
        plate.opacity = 0
        run(bar, "opacity", from: 1, to: 0, away, .easeIn, after: lead)
        run(plate, "opacity", from: 1, to: 0, away, .easeIn, after: lead)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + away + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.round == mine, !self.shown else { return }
                self.settle()
            }
        }
    }

    /// Nothing up, nothing running.
    private func settle() {
        shown = false
        phase = .idle
        for each in [bar, track, fill, plate] { each.removeAllAnimations() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.opacity = 0
        plate.opacity = 0
        fill.opacity = 0
        size(Self.short, from: nil, over: 0)
        CATransaction.commit()
    }

    /// The bar `width` long about its middle, and its plate round it.
    private func size(_ width: CGFloat, from: CGFloat?, over duration: CFTimeInterval, after: CFTimeInterval = 0,
                      curve: CAMediaTimingFunctionName = .easeOut) {
        let to = CGRect(x: -width / 2, y: -Self.thick / 2, width: width, height: Self.thick)
        let plateTo = to.insetBy(dx: -rim.width, dy: -rim.height)
        let fromRect = from.map { CGRect(x: -$0 / 2, y: -Self.thick / 2, width: $0, height: Self.thick) }
        bar.bounds = to
        plate.bounds = plateTo
        guard let fromRect, duration > 0 else { return }
        run(bar, "bounds", from: NSValue(rect: fromRect), to: NSValue(rect: to), duration, curve, after: after)
        run(plate, "bounds", from: NSValue(rect: fromRect.insetBy(dx: -rim.width, dy: -rim.height)), to: NSValue(rect: plateTo), duration, curve, after: after)
    }

    private func run(_ layer: CALayer, _ key: String, from: Any, to: Any, _ duration: CFTimeInterval,
                     _ curve: CAMediaTimingFunctionName, after: CFTimeInterval = 0) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: curve)
        if after > 0 {
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + after
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: "load." + key)
    }

    /// What the bench reads of it.
    var state: [String: Any] {
        [
            "phase": phase.rawValue, "shown": shown, "plated": plated,
            "width": Double(bar.presentation()?.bounds.width ?? bar.bounds.width),
            "opacity": Double(bar.presentation()?.opacity ?? bar.opacity),
            "running": fill.animation(forKey: "run") != nil, "breathing": track.animation(forKey: "breath") != nil,
            "tab": tab.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? "",
            "where": window.map { _ in NSStringFromRect(convert(bounds, to: nil)) } ?? "",
        ]
    }
}

/// A page's bar over its card (LoadBar), in SwiftUI.
struct LoadPill: NSViewRepresentable {
    let tab: Tab
    var plated = false

    func makeNSView(context: Context) -> LoadBar { LoadBar(frame: CGRect(origin: .zero, size: LoadBar.size)) }

    func updateNSView(_ bar: LoadBar, context: Context) {
        bar.plated = plated
        bar.bind(tab)
    }

    static func dismantleNSView(_ bar: LoadBar, coordinator: ()) {
        bar.bind(nil)
    }
}
