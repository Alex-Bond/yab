import SwiftUI

// Two fingers sideways, drawn.
//
// A disc of glass comes in at the edge you pull from and stays there, a line
// of ink winding round it as the fingers go. Where letting go would mean it,
// it is armed at once: the
// ink fills it and it opens into a pill that names the page it would take you
// to, the size change being the sign (family-values-motion P1, P6). Pull on
// and the pill grows, where it is, into a list of the pages behind, one more
// lit for every stretch of travel, rolling on through the whole history of
// the tab, then the tab it was opened from, and last "Search History", which
// opens the tab's history as a panel (HistoryPanel.swift).
// Turn back and each step is given back the same way. Let go short of the
// first page and the disc goes back out past its edge, the way it came (P3);
// let go armed and it steps a little further on and is gone, quicker than it
// came.
//
// The page going back is done every day, dozens of times, so the one-page
// swipe stays a small pill at the edge; the list is for the rarer pull that
// means to go deep (P10).
//
// All of it is Core Animation, and a move of the fingers changes only how far
// the ring is wound: SwiftUI draws the list's rows once, when it comes.
// Drawn by SwiftUI as the disc was, every event of the gesture drew the whole
// page's view over again. The glass (macOS 26) is set where the disc is once
// a gesture and never moved while the fingers are: a glass carried along
// with them is worked out again on every event, measured at half as much
// main-thread time again as the whole gesture, and a still one at nothing.

/// Laid over the page, where a sideways swipe shows how far it has got. The
/// tab hands it each move itself (`Tab.pull`); this only says which view is
/// the tab's now.
struct PullHost: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> PullView { PullView() }

    func updateNSView(_ view: PullView, context: Context) {
        guard tab.pullView !== view || view.owner !== tab else { return }
        // Another tab's page now: the last one's history panel goes.
        if view.owner !== tab { view.closePanel(animated: false) }
        view.owner = tab
        tab.pullView = view
        view.show(tab.pull, of: tab)
    }
}

final class PullView: NSView {
    /// The tab whose swipes this draws. A view handed to another tab's page
    /// ignores what the one before says.
    weak var owner: Tab?

    /// The disc's size, and the pill's height.
    static let disc: CGFloat = 40
    /// How far in from the page's edge the disc stands.
    static let inset: CGFloat = 16
    /// Between the disc and the ring that winds round it.
    static let ringGap: CGFloat = 4
    /// How much of the dark ground is laid over the glass in the dark look.
    static let darkVeil: Double = 0.5

    /// Liquid Glass under the disc and the list, where there is glass and it
    /// is wanted; the plain white ground otherwise.
    static var glassy: Bool { LiquidGlass.wanted }

    static func glass(corner: CGFloat) -> NSView? {
        guard glassy, #available(macOS 26.0, *) else { return nil }
        let glass = NSGlassEffectView()
        glass.cornerRadius = corner
        glass.wantsLayer = true
        return glass
    }
    /// The longest a page's name gets in the pill before it is cut short.
    static let words: CGFloat = 190
    /// The longest the pill gets: its arrow, the longest name, the insets.
    static let longest: CGFloat = 12 + 18 + 8 + words + 12 + 4
    static let listWidth: CGFloat = 280
    /// Room round the list for its shadow, which SwiftUI draws only inside
    /// its own view.
    static let margin: CGFloat = 32
    /// Where the list grows from, and shrinks back to.
    private static let grown: CGFloat = 0.6

    private let pill = CALayer()
    private let ground = CAShapeLayer()
    private let ring = CAShapeLayer()
    /// Under the ring, a wider band of the ground, so the ring reads over
    /// whatever the page has there.
    private let halo = CAShapeLayer()
    private let arrow = CALayer()
    private let label = CATextLayer()
    private var list: Listing?
    /// The disc's glass, in a view of its own: a view moved or shown marks
    /// its superview for layout, and the list's SwiftUI would go with it.
    private let glassHost = NSView()
    private let glass = PullView.glass(corner: PullView.disc / 2)

    /// The list drawn twice, once as it is and once all in ink, the ink one
    /// shown only through a mask the size of the lit row. Lighting another
    /// row moves the mask: SwiftUI draws nothing again mid-gesture, where
    /// each row drawn again was a backing store that could wait on a busy
    /// window server. A long history shows `window` rows at a time, the
    /// rows moved under a clip as the lit one goes down, again without
    /// drawing anything.
    private final class Listing: NSView {
        static let window = 7

        let stops: [Stop]
        let plain: NSHostingView<PullList>
        let ink: NSHostingView<PullList>
        let lit = CAShapeLayer()
        /// The card: glass, with the dark look's veil over it, or the white
        /// ground with its hairline and shadow.
        let glass = PullView.glass(corner: DropFrame.corner)
        let card = CAShapeLayer()
        let clip = NSView()
        /// The first row in view, the list rolled on by that many.
        private(set) var first = 0
        /// The row lit now, counted from the top.
        private(set) var litRow = 0

        init(stops: [Stop]) {
            self.stops = stops
            plain = NSHostingView(rootView: PullList(stops: stops, ink: false))
            ink = NSHostingView(rootView: PullList(stops: stops, ink: true))
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = false
            if let glass { addSubview(glass) }
            layer?.addSublayer(card)
            card.lineWidth = 1
            // The card's shadow (Design.swift, floatingFrame), from a path.
            card.shadowColor = NSColor.black.cgColor
            card.shadowRadius = 24
            card.shadowOffset = CGSize(width: 0, height: -8)
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            addSubview(clip)
            for host in [plain, ink] {
                host.sizingOptions = []
                host.wantsLayer = true
                clip.addSubview(host)
            }
            ink.layer?.mask = lit
            paint()
        }

        required init?(coder: NSCoder) { nil }

        var shown: Int { min(stops.count, Listing.window) }

        var size: CGSize {
            let m = PullView.margin, i = DropFrame.inset
            return CGSize(width: PullView.listWidth + 2 * m, height: CGFloat(shown) * PullList.rowHeight + 2 * i + 2 * m)
        }

        override func layout() {
            super.layout()
            // Only when it changed: a hosting view given a frame, even the
            // same one, lays its SwiftUI out again.
            let box = bounds.insetBy(dx: PullView.margin, dy: PullView.margin)
            if let glass, glass.frame != box { glass.frame = box }
            let path = CGPath.rounded(box.insetBy(dx: 0.5, dy: 0.5), corner: DropFrame.corner - 0.5)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            card.path = path
            card.shadowPath = path
            CATransaction.commit()
            let inside = box.insetBy(dx: DropFrame.inset, dy: DropFrame.inset)
            if clip.frame != inside { clip.frame = inside }
            let tall = CGFloat(stops.count) * PullList.rowHeight
            let rows = CGRect(x: 0, y: inside.height - tall, width: inside.width, height: tall)
            if plain.frame != rows { plain.frame = rows }
            if ink.frame != rows { ink.frame = rows }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paint()
        }

        /// Glass is the ground where there is glass, laid half over with
        /// the dark ground in the dark look (over a light page clear glass
        /// came out a mid gray the light words barely stood off); the white
        /// card otherwise.
        private func paint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if glass != nil {
                    card.fillColor = Palette.NS.ground.withAlphaComponent(dark ? PullView.darkVeil : 0).cgColor
                    card.strokeColor = nil
                    card.shadowOpacity = 0
                } else {
                    card.fillColor = Palette.NS.ground.cgColor
                    card.strokeColor = Palette.NS.hairline.cgColor
                    card.shadowOpacity = 0.14
                }
                CATransaction.commit()
            }
        }

        /// The card, in this view.
        var cardRect: CGRect { bounds.insetBy(dx: PullView.margin, dy: PullView.margin) }

        /// Where the lit row is drawn, in another view, rolled as it is.
        func litRect(in view: NSView) -> CGRect {
            let rect = PullList.row(max(0, litRow), in: ink.bounds, flipped: ink.isFlipped)
            var out = ink.convert(rect, to: view)
            out.origin.y += CGFloat(first) * PullList.rowHeight * (view.isFlipped ? -1 : 1)
            return out
        }

        /// The row lit, counted from the top of the whole list.
        func light(_ row: Int, animated: Bool) {
            litRow = row
            // Kept in view with a row or two of what is still to come
            // below it, until the end.
            let top = max(0, min(row - (Listing.window - 3), stops.count - shown))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ink.layer?.mask = lit
            lit.frame = ink.bounds
            // None lit, above the first: nothing to go to.
            let rect = PullList.row(max(0, row), in: ink.bounds, flipped: ink.layer?.contentsAreFlipped() ?? true)
            lit.path = row < 0 ? nil : CGPath.rounded(rect, corner: Radius.control)
            if top != first, let layer = clip.layer {
                let was = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
                let now = CATransform3DMakeTranslation(0, CGFloat(top) * PullList.rowHeight, 0)
                layer.sublayerTransform = now
                if animated {
                    let move = CABasicAnimation(keyPath: "sublayerTransform")
                    move.fromValue = NSValue(caTransform3D: was)
                    move.toValue = NSValue(caTransform3D: now)
                    move.duration = 0.14
                    move.timingFunction = Reshape.Pace.arrive.timing
                    layer.add(move, forKey: "sublayerTransform")
                }
                first = top
            }
            CATransaction.commit()
        }
    }

    private var shown: Pull?
    /// The pill is on its way out with the page, or back past its edge.
    private var leaving = false
    private var armed = false
    private var width = PullView.disc

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        pill.opacity = 0
        pill.addSublayer(ground)
        pill.addSublayer(halo)
        pill.addSublayer(ring)
        pill.addSublayer(arrow)
        pill.addSublayer(label)
        // The card's shadow (Design.swift, floatingFrame), from a path.
        ground.shadowColor = NSColor.black.cgColor
        ground.shadowOpacity = 0.14
        ground.shadowRadius = 24
        ground.shadowOffset = CGSize(width: 0, height: -8)
        ground.lineWidth = 1
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.lineCap = .round
        halo.fillColor = nil
        halo.lineWidth = 4.5
        halo.lineCap = .round
        arrow.contentsGravity = .resizeAspect
        label.font = PullView.font
        label.fontSize = PullView.font.pointSize
        label.truncationMode = .end
        label.alignmentMode = .left
        layer?.addSublayer(pill)
        pill.zPosition = 10
        if let glass {
            glassHost.wantsLayer = true
            glassHost.autoresizingMask = [.width, .height]
            addSubview(glassHost)
            glass.layer?.opacity = 0
            glassHost.addSubview(glass)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Never in the way of the page: nothing here takes a click but the
    /// history's panel, while it is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let panel = historyPanel, let local = superview.map({ convert(point, from: $0) }),
              panel.frame.contains(local) else { return nil }
        return panel.hitTest(convert(local, to: panel.superview))
    }

    /// The tab's history, opened from "Search History" (HistoryPanel.swift).
    var historyPanel: NSView?
    /// Where the list last stood and which edge it hung from, for the panel
    /// to come out of the same place.
    private(set) var listPlace: (frame: CGRect, back: Bool)?

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        label.contentsScale = scale
        arrow.contentsScale = scale
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - what the tab says

    func show(_ pull: Pull?, of tab: Tab) {
        guard tab === owner else { return }
        guard let pull else {
            if shown != nil, !leaving { back() } else { clear() }
            return
        }
        if pull.going {
            leave(pull)
            return
        }
        // A new gesture while the last one's pill is still on its way out:
        // that one is simply taken away.
        if leaving { clear() }
        follow(pull)
    }

    // MARK: - following the fingers

    private func follow(_ pull: Pull) {
        let first = shown == nil || shown?.back != pull.back
        shown = pull
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if first {
            pill.removeAllAnimations()
            armed = false
            width = PullView.disc
            shape(for: pull)
            arrive(pull)
        }
        // Passing through on the way to the list, the pill waits: a disc
        // until the list grows out of it, or the fingers stop short.
        let nowArmed = pull.armed && !pull.passing
        // The list about to come: it grows from what is on screen now, the
        // disc or a pill part way, not from where the pill was headed.
        var start: (rect: CGRect, fill: CGColor?, disc: Bool)?
        if pull.listed, list == nil, let host = layer {
            let live = ground.presentation() ?? ground
            let box = (live.path ?? ground.path)?.boundingBoxOfPath ?? .zero
            start = (ground.convert(box, to: host), live.fillColor, !armed)
        }
        if nowArmed != armed {
            armed = nowArmed
            // Straight into the list, the pill is never drawn on the way;
            // given back at speed, it is a disc again at once.
            shape(for: pull, growing: start == nil && !(pull.quick && !nowArmed))
        }
        place(pull)
        CATransaction.commit()
        deepen(pull, from: start)
    }

    /// Where the disc stands, in from the edge. With nowhere to go, it only
    /// looks out from behind it.
    private func offset(_ pull: Pull) -> CGFloat {
        pull.blocked ? -PullView.disc * 0.35 : PullView.inset
    }

    private func place(_ pull: Pull) {
        let x = offset(pull)
        pill.bounds = CGRect(x: 0, y: 0, width: width, height: PullView.disc)
        pill.anchorPoint = CGPoint(x: pull.back ? 0 : 1, y: 0.5)
        pill.position = CGPoint(x: pull.back ? x : bounds.width - x, y: bounds.midY)
        let seen: Float = list == nil ? (pull.blocked ? 0.55 : 1) : 0
        pill.opacity = seen
        // Glass under the disc only: the armed pill is ink, whole.
        glass?.layer?.opacity = armed ? 0 : seen
        ring.strokeEnd = pull.blocked ? 0 : min(1, pull.travel / Swipe.arm)
        halo.strokeEnd = ring.strokeEnd
    }

    /// The pill's rect in this view at a width, from the edge it hangs from.
    private func pillRect(_ pull: Pull, width: CGFloat) -> CGRect {
        let h = PullView.disc, x = offset(pull)
        return CGRect(x: pull.back ? x : bounds.width - x - width, y: bounds.midY - h / 2, width: width, height: h)
    }


    /// In from the edge it lives past, a short way, 0.16 s: once a gesture,
    /// then it stands.
    private func arrive(_ pull: Pull) {
        if let glass, let layer = glass.layer {
            // Laid once at the longest the pill can get and never moved or
            // resized while the fingers are down: a glass given a new frame
            // lays itself out a frame late, and showed its old shape inside
            // the new one. Only its mask changes.
            let rect = pillRect(pull, width: PullView.longest)
            if glass.frame != rect { glass.frame = rect }
            if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView { glass.cornerRadius = PullView.disc / 2 }
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = glass.bounds
            let h = PullView.disc
            let disc = CGRect(x: pull.back ? 0 : PullView.longest - h, y: 0, width: h, height: h)
            mask.path = CGPath(roundedRect: disc.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil)
            layer.mask = mask
        }
        guard !still else { return }
        let pace = Reshape.Pace.arrive
        let from: CGFloat = pull.back ? -10 : 10
        for layer in [pill, glass?.layer].compactMap({ $0 }) {
            PullView.run(layer, "transform.translation.x", from: from, to: 0, 0.16, pace.timing)
            PullView.run(layer, "opacity", from: 0, to: pull.blocked ? 0.55 : 1, 0.16, pace.timing)
        }
    }

    /// The disc, or the pill that names the page, laid out for which side it
    /// is on. Growing, the ground is drawn from the disc to the pill, or
    /// back, and the name comes in over it.
    private func shape(for pull: Pull, growing: Bool = false) {
        let name = armed ? (pull.stops.first?.title ?? "") : ""
        let words = name.isEmpty ? 0 : min(PullView.words, ceil((name as NSString).size(withAttributes: [.font: PullView.font]).width))
        let was = ground.path
        let wasFill = ground.fillColor, wasStroke = ground.strokeColor
        let wasArrow: CGPoint? = growing ? arrow.position : nil
        let wasArt = growing ? arrow.contents : nil
        // Arrow at the edge the pill comes from; the name beside it, inwards.
        let side: CGFloat = 18
        let pad: CGFloat = 12
        width = armed ? pad + side + 8 + words + pad + 4 : PullView.disc
        let h = PullView.disc
        let lead = pull.back
        let disc = CGRect(x: lead ? 0 : width - h, y: 0, width: h, height: h)
        let whole = CGRect(x: 0, y: 0, width: width, height: h)
        let path = CGPath(roundedRect: whole.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil)
        ground.frame = whole
        ground.path = path
        ground.shadowPath = path
        ring.frame = whole
        let center = CGPoint(x: disc.midX, y: disc.midY)
        let round = CGMutablePath()
        // Round the disc with room between, not on its edge.
        round.addArc(center: center, radius: h / 2 + PullView.ringGap, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.path = round
        ring.opacity = armed ? 0 : 1
        halo.frame = whole
        halo.path = round
        halo.opacity = armed ? 0 : 0.8
        arrow.frame = CGRect(x: armed ? (lead ? pad : width - pad - side) : disc.midX - side / 2, y: (h - side) / 2, width: side, height: side)
        label.string = name
        label.frame = CGRect(x: lead ? pad + side + 8 : pad + 4, y: (h - 17) / 2, width: words, height: 17)
        paint()
        let cut = glass?.layer?.mask as? CAShapeLayer
        if !growing {
            // At once: whatever was on its way there is dropped, and the
            // glass is cut to the same shape.
            for key in ["path", "shadowPath", "fillColor", "strokeColor"] { ground.removeAnimation(forKey: key) }
            for layer in [label, arrow, ring, halo] { layer.removeAllAnimations() }
            cut?.removeAllAnimations()
            glass?.layer?.removeAnimation(forKey: "opacity")
            var move = CGAffineTransform(translationX: lead ? 0 : PullView.longest - width, y: 0)
            if cut != nil, width > h { cut?.path = path.copy(using: &move) }
            if cut != nil, width <= h {
                let round = CGRect(x: lead ? 0 : PullView.longest - h, y: 0, width: h, height: h)
                cut?.path = CGPath(roundedRect: round.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil)
            }
        }
        guard growing, !still, let was else { return }
        // The ground from where it was, laid in the new bounds: the disc
        // stays where the pill starts, at the edge it came from.
        let from: CGPath
        if armed {
            from = CGPath(roundedRect: disc.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil)
        } else {
            let wide = was.boundingBoxOfPath.width + 1
            let rect = CGRect(x: lead ? 0 : width - wide, y: 0, width: wide, height: h)
            from = CGPath.rounded(rect.insetBy(dx: 0.5, dy: 0.5), corner: h / 2 - 0.5)
        }
        // One shape the whole way: the ground drawn from the disc to the
        // pill (or back), the ink coming up in it as the glass goes, the
        // arrow sliding to its place and turning color, the name coming in
        // after it. Nothing is swapped at once.
        let pace = Reshape.Pace.arrive
        let span: CFTimeInterval = 0.22
        // Armed, the click: the pill shoots out and stops at its length,
        // and the arrow gives a nudge towards the edge, with the tap. Given
        // back, it just goes.
        let snap = armed ? PullView.snap : nil
        let capsule = { (w: CGFloat) -> CGPath in
            let rect = CGRect(x: lead ? 0 : self.width - w, y: 0, width: w, height: h)
            return CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil)
        }
        for key in ["path", "shadowPath"] {
            if let snap {
                let spring = CAKeyframeAnimation(keyPath: key)
                spring.values = snap.map { capsule(h + (width - h) * $0) }
                spring.duration = PullView.snapTime
                spring.calculationMode = .linear
                ground.add(spring, forKey: key)
            } else {
                PullView.run(ground, key, from: from, to: path, span, pace.timing)
            }
        }
        if snap != nil {
            let nudge = CAKeyframeAnimation(keyPath: "transform.translation.x")
            nudge.values = [0, lead ? -3 : 3, 0]
            nudge.keyTimes = [0, 0.3, 1]
            nudge.duration = 0.18
            nudge.isAdditive = true
            nudge.timingFunctions = [pace.timing, pace.timing]
            arrow.add(nudge, forKey: "nudge")
        }
        PullView.run(ground, "fillColor", from: wasFill ?? ground.fillColor as Any, to: ground.fillColor as Any, 0.14, pace.timing)
        PullView.run(ground, "strokeColor", from: wasStroke ?? ground.strokeColor as Any, to: ground.strokeColor as Any, 0.14, pace.timing)
        // The ring has done its work once armed: gone at once, before the
        // pill grows over it; given back, it comes again only once the pill
        // is a disc again, never a ring laid over a pill.
        for (layer, seen) in [(ring, Float(1)), (halo, Float(0.8))] {
            if armed {
                // At once (P6): faded, its far side lay across the pill.
                layer.removeAnimation(forKey: "opacity")
                _ = seen
            } else {
                let back = CAKeyframeAnimation(keyPath: "opacity")
                back.values = [0, 0, seen]
                back.keyTimes = [0, 0.8, 1]
                back.duration = span
                layer.add(back, forKey: "opacity")
            }
        }
        if let wasArrow { PullView.run(arrow, "position", from: NSValue(point: wasArrow), to: NSValue(point: arrow.position), span, pace.timing) }
        if let wasArt { PullView.run(arrow, "contents", from: wasArt, to: arrow.contents as Any, 0.14, pace.timing) }
        if let view = glass, let layer = view.layer, let mask = layer.mask as? CAShapeLayer {
            // The glass is cut by the same shape as the ground, drawn the
            // same way: one shape all the way, the glass going as the ink
            // comes, never a round glass beside a long pill.
            var move = CGAffineTransform(translationX: lead ? 0 : PullView.longest - width, y: 0)
            mask.path = path.copy(using: &move)
            if let snap {
                let spring = CAKeyframeAnimation(keyPath: "path")
                spring.values = snap.map { capsule(h + (width - h) * $0).copy(using: &move) as Any }
                spring.duration = PullView.snapTime
                mask.add(spring, forKey: "path")
            } else {
                PullView.run(mask, "path", from: from.copy(using: &move) as Any, to: mask.path as Any, span, pace.timing)
            }
            PullView.run(layer, "opacity", from: armed ? 1 : 0, to: armed ? 0 : 1, 0.14, pace.timing)
        }
        if armed {
            let words = CAKeyframeAnimation(keyPath: "opacity")
            // Only once the pill is nearly as long as the name, so the
            // words never stand past its end.
            // On the spring, from the sample where the pill first reaches
            // past the words' end (they stop its end padding short of it),
            // over the next few.
            let reach = 1 - (pad + 4) / max(1, width - h)
            let first = PullView.snap.firstIndex { $0 >= reach } ?? PullView.snap.count - 1
            let last = PullView.snap.count - 1
            let from = Double(first) / Double(last)
            words.values = [0, 0, 1, 1]
            words.keyTimes = [0, from, min(1, from + 0.25), 1].map { NSNumber(value: $0) }
            words.duration = PullView.snapTime
            label.add(words, forKey: "opacity")
            PullView.run(label, "transform.translation.x", from: lead ? -6 : 6, to: 0, span, pace.timing)
        }
    }

    /// The colors for the look the window has now: glass (or white) with a
    /// hairline and ink while pulling, filled with ink the moment it is armed.
    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let ink = Palette.NS.ink
            let paper = Palette.NS.ground
            let clear = glass != nil && !armed
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let veil = paper.withAlphaComponent(dark ? PullView.darkVeil : 0)
            ground.fillColor = armed ? ink.cgColor : (clear ? veil.cgColor : paper.cgColor)
            ground.strokeColor = (armed ? ink : Palette.NS.hairline).cgColor
            // The glass casts its own.
            ground.shadowOpacity = clear ? 0 : 0.14
            ring.strokeColor = ink.cgColor
            halo.strokeColor = paper.cgColor
            label.foregroundColor = paper.cgColor
            let blocked = shown?.blocked == true
            let tint = armed ? paper : (blocked ? Palette.NS.faint : ink)
            // Fixed here, under the window's look: the icon is drawn later,
            // when the layer asks, and a color that follows the look would
            // be read then, as whatever look is current.
            let fixed = NSColor(cgColor: tint.cgColor) ?? tint
            arrow.contents = Glyphs.image(shown?.back == false ? "arrow.right" : "arrow.left", size: 13, color: fixed)
            CATransaction.commit()
        }
    }

    // MARK: - deeper: the list

    private func deepen(_ pull: Pull, from start: (rect: CGRect, fill: CGColor?, disc: Bool)? = nil) {
        let deep = pull.listed
        guard deep else {
            if let list {
                if pull.quick { drop(list) } else { fold(list) }
            }
            return
        }
        if let list, list.stops == pull.stops {
            list.light(pull.steps - 1, animated: !still)
            return
        }
        let listing = Listing(stops: pull.stops)
        addSubview(listing)
        list = listing
        let size = listing.size
        let m = PullView.margin
        // Its edge where the pill's is, level with it, kept on the page.
        let x = offset(pull)
        let left = pull.back ? x - m : bounds.width - x - size.width + m
        let bottom = min(max(bounds.midY - size.height / 2, -m), bounds.height - size.height + m)
        listing.frame = CGRect(x: left, y: bottom, width: size.width, height: size.height).integral
        listing.layoutSubtreeIfNeeded()
        listing.light(pull.steps - 1, animated: false)
        // Hung so that the lit row is where the pill is: the pill becomes
        // that row where it stands, and the list opens round it (P4), unless
        // the page's edge leaves no room.
        let lift = pill.position.y - listing.litRect(in: self).midY
        let y = min(max(listing.frame.minY + lift, -m), bounds.height - size.height + m)
        listing.setFrameOrigin(NSPoint(x: listing.frame.minX, y: y.rounded()))
        listPlace = (listing.frame, pull.back)
        grow(listing, from: pull, start: start)
    }

    /// The point the list grows out of, the pill's middle, in the list's
    /// own layer: a view's layer hangs from its corner, so a scale about a
    /// point is a scale and a step towards it.
    private func scaled(_ host: NSView, _ scale: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: pill.position.x + (pill.anchorPoint.x == 0 ? 1 : -1) * PullView.disc / 2, y: pill.position.y)
        let point = host.convert(middle, from: self)
        return CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation((1 - scale) * point.x, (1 - scale) * point.y, 0)
        )
    }

    private static func rounded(_ rect: CGRect, _ corner: CGFloat) -> CGPath {
        CGPath.rounded(rect, corner: corner)
    }

    /// The pill opens into the list: the pill itself goes to be the lit row,
    /// its name and arrow let go on the way, and the card opens out of the
    /// pill's outline round it to its own (family-values-motion P1, P4).
    /// The card's mask is taken off once it is open, so the list at rest is
    /// drawn with none.
    private func grow(_ listing: Listing, from pull: Pull, start: (rect: CGRect, fill: CGColor?, disc: Bool)?) {
        guard let layer = listing.layer else { return }
        let pace = Reshape.Pace.arrive
        let span: CFTimeInterval = 0.26
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        pill.opacity = 0
        let glassWas = glass?.layer?.presentation()?.opacity ?? glass?.layer?.opacity ?? 0
        glass?.layer?.opacity = 0
        guard !still, let host = self.layer else {
            PullView.run(layer, "opacity", from: 0, to: 1, pace.duration, pace.timing)
            PullView.run(pill, "opacity", from: pull.blocked ? 0.55 : 1, to: 0, 0.12, pace.timing)
            CATransaction.commit()
            return
        }
        let begin = start?.rect ?? pill.frame
        let outline = listing.convert(begin, from: self)
        let card = listing.cardRect
        let mask = CAShapeLayer()
        mask.frame = listing.bounds
        mask.path = PullView.rounded(card, DropFrame.corner)
        layer.mask = mask
        CATransaction.setCompletionBlock { [weak layer, weak mask] in
            MainActor.assumeIsolated { if let layer, layer.mask === mask { layer.mask = nil } }
        }
        PullView.run(mask, "path", from: PullView.rounded(outline, outline.height / 2), to: mask.path as Any, span, pace.timing)
        PullView.run(layer, "opacity", from: 0.4, to: 1, 0.1, pace.timing)
        // The pill to where its row is, and gone once it is there, the ink
        // row under it the same ink.
        let row = pill.convert(listing.litRect(in: self), from: host)
        let into = PullView.rounded(row, Radius.control)
        let local = pill.convert(begin, from: host)
        let from = start == nil ? ground.path : PullView.rounded(local, local.height / 2)
        for key in ["path", "shadowPath"] { PullView.run(ground, key, from: from as Any, to: into, span, pace.timing) }
        if let start {
            // Out of the disc: the ink comes up in it as the glass goes, the
            // way the pill takes it.
            if let fill = start.fill { PullView.run(ground, "fillColor", from: fill, to: ground.fillColor as Any, 0.14, pace.timing) }
            if let glass = glass?.layer, glassWas > 0 { PullView.run(glass, "opacity", from: glassWas, to: 0, 0.14, pace.timing) }
        }
        // Gone as it arrives, the ink row with its name under it taking over.
        let hold = CAKeyframeAnimation(keyPath: "opacity")
        hold.values = [1, 1, 0, 0]
        hold.keyTimes = [0, 0.3, 0.6, 1]
        hold.duration = span
        pill.add(hold, forKey: "opacity")
        // The name is the lit row's own, in the same place: it stays, and
        // only the arrow gives way to the site's mark.
        let away = CAKeyframeAnimation(keyPath: "opacity")
        away.values = [1, 0, 0]
        away.keyTimes = [0, 0.35, 1]
        away.duration = span
        arrow.add(away, forKey: "opacity")
        if start?.disc == true {
            // Out of the disc the name was never there: the lit row brings it.
            let none = CABasicAnimation(keyPath: "opacity")
            none.fromValue = 0
            none.toValue = 0
            none.duration = span
            label.add(none, forKey: "opacity")
        }
        CATransaction.commit()
    }

    /// Back into the pill, a page given back: the lit row goes back to be
    /// the pill and the card closes into its outline, the same way out.
    private func fold(_ listing: Listing) {
        list = nil
        guard !still, let layer = listing.layer, let host = self.layer, window != nil else {
            let pace = Reshape.Pace.depart
            dismiss(listing, scale: PullView.grown, duration: pace.duration, timing: pace.timing)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.opacity = 1
            PullView.run(pill, "opacity", from: 0, to: 1, 0.12, Reshape.Pace.arrive.timing)
            CATransaction.commit()
            return
        }
        let pace = Reshape.Pace.arrive
        let span: CFTimeInterval = 0.22
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { listing.removeFromSuperview() } }
        let outline = listing.convert(pill.frame, from: self)
        let mask = CAShapeLayer()
        mask.frame = listing.bounds
        mask.path = PullView.rounded(outline, outline.height / 2)
        layer.mask = mask
        PullView.run(mask, "path", from: PullView.rounded(listing.cardRect, DropFrame.corner), to: mask.path as Any, span, pace.timing)
        // The rows go in the first half, so none shows through the outline
        // closing on the pill; the pill is there from the start.
        layer.opacity = 0
        let gone = CAKeyframeAnimation(keyPath: "opacity")
        gone.values = [1, 0, 0]
        gone.keyTimes = [0, 0.45, 1]
        gone.duration = span
        layer.add(gone, forKey: "opacity")
        let come = CAKeyframeAnimation(keyPath: "opacity")
        come.values = [0, 1, 1]
        come.keyTimes = [0, 0.25, 1]
        come.duration = span
        pill.add(come, forKey: "opacity")
        let row = pill.convert(listing.litRect(in: self), from: host)
        for key in ["path", "shadowPath"] {
            PullView.run(ground, key, from: PullView.rounded(row, Radius.control), to: ground.path as Any, span, pace.timing)
        }
        pill.opacity = 1
        for part in [label, arrow] {
            let back = CAKeyframeAnimation(keyPath: "opacity")
            back.values = [0, 0, 1]
            back.keyTimes = [0, 0.5, 1]
            back.duration = span
            part.add(back, forKey: "opacity")
        }
        CATransaction.commit()
    }

    /// Given back at speed: the list simply goes, the pill there at once.
    private func drop(_ listing: Listing) {
        list = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [pill, ground, label, arrow] { layer.removeAnimation(forKey: "opacity") }
        for key in ["path", "shadowPath"] { ground.removeAnimation(forKey: key) }
        pill.opacity = shown?.blocked == true ? 0.55 : 1
        CATransaction.commit()
        let pace = Reshape.Pace.depart
        dismiss(listing, scale: 1, duration: 0.1, timing: pace.timing)
    }

    private func dismiss(_ host: NSView, scale: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let layer = host.layer, window != nil else { return host.removeFromSuperview() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { host.removeFromSuperview() } }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        PullView.run(layer, "opacity", from: from, to: 0, duration, timing)
        if !still {
            let end = scaled(host, scale)
            layer.transform = end
            PullView.run(layer, "transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                         to: NSValue(caTransform3D: end), duration, timing)
        }
        CATransaction.commit()
    }

    // MARK: - letting go

    /// Let go armed: the page is on its way. The pill steps a little further
    /// on and is gone; the list, if it was out, closes where it is.
    private func leave(_ pull: Pull) {
        guard !leaving, shown != nil else { return }
        leaving = true
        let duration: CFTimeInterval = 0.13
        let timing = Reshape.Pace.depart.timing
        if let list {
            self.list = nil
            dismiss(list, scale: 0.92, duration: duration, timing: timing)
        }
        slide(by: pull.back ? 12 : -12, duration: duration, timing: CAMediaTimingFunction(name: .easeOut))
    }

    /// Let go short: back out past the edge it came from.
    private func back() {
        guard let pull = shown else { return }
        leaving = true
        if let list {
            self.list = nil
            // Taken back home: gone where it stands, quicker than it came.
            dismiss(list, scale: 1, duration: 0.1, timing: Reshape.Pace.depart.timing)
        }
        slide(by: (pull.back ? -1 : 1) * (offset(pull) + PullView.disc), duration: 0.12, timing: Reshape.Pace.depart.timing)
    }

    private func slide(by dx: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        let from = pill.presentation()?.opacity ?? pill.opacity
        let was = pill.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.done() } }
        pill.opacity = 0
        PullView.run(pill, "opacity", from: from, to: 0, duration, timing)
        if let layer = glass?.layer, layer.opacity > 0 {
            let seen = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = 0
            PullView.run(layer, "opacity", from: seen, to: 0, duration, timing)
            if !still { PullView.run(layer, "transform.translation.x", from: 0, to: dx, duration, timing) }
        }
        if !still {
            let to = CGPoint(x: was.x + dx, y: was.y)
            pill.position = to
            PullView.run(pill, "position", from: NSValue(point: was), to: NSValue(point: to), duration, timing)
        }
        CATransaction.commit()
    }

    /// Gone: ready for the next swipe. Only if no new one started meanwhile.
    private func done() {
        guard leaving else { return }
        clear()
    }

    private func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.removeAllAnimations()
        pill.opacity = 0
        glass?.layer?.removeAllAnimations()
        glass?.layer?.opacity = 0
        CATransaction.commit()
        list?.removeFromSuperview()
        list = nil
        shown = nil
        leaving = false
        armed = false
    }

    /// The pill's click on arming: a spring from the disc (0) to the pill
    /// (1), critically damped, so it shoots out quick and stops at its own
    /// length, never past it; there by `snapTime`, sampled for a keyframe
    /// path.
    static let snapTime: CFTimeInterval = 0.24
    static let snap: [CGFloat] = {
        let omega = 30.0
        return (0...24).map { i in
            guard i < 24 else { return 1 }
            let t = snapTime * Double(i) / 24
            return CGFloat(1 - (1 + omega * t) * exp(-omega * t))
        }
    }()

    private static func run(_ layer: CALayer, _ key: String, from: Any, to: Any, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: key)
    }
}

/// The rows of the list a swipe pulled deep shows, nearest first: pages,
/// runs of one site, the tab this one came from, and the history to search,
/// on the accounts list's measures (Accounts.swift). The lit row is filled
/// with ink, as the pill is: it is the pill, grown into its place in the
/// list, and it has to read at a glance, mid-gesture. Drawn once plain and
/// once all ink (`ink`), the ink one seen through the lit row only
/// (PullView.Listing); the card under it is the listing's.
struct PullList: View, Equatable {
    let stops: [Stop]
    let ink: Bool

    /// Every row the same height, so the lit one's place is known without
    /// asking SwiftUI.
    static let rowHeight: CGFloat = 36

    /// The lit row's rect in the rows' view, `row` counted from the top.
    static func row(_ row: Int, in bounds: CGRect, flipped: Bool) -> CGRect {
        let top = CGFloat(row) * rowHeight
        let y = flipped ? top : bounds.height - top - rowHeight
        return CGRect(x: 0, y: y, width: bounds.width, height: rowHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                PullList.row(stop, lit: ink)
            }
            Spacer(minLength: 0)
        }
    }

    /// One row, the swipe's list's and the held door's (DoorList) alike.
    @ViewBuilder
    static func row(_ stop: Stop, lit: Bool) -> some View {
        switch stop.kind {
        case .page, .run:
            let site = Browser.site(stop.host)
            // The site is its mark: only a run says more, how many pages.
            PullRow(title: stop.title, detail: stop.kind == .run ? "\(stop.count) pages" : "", lit: lit) {
                Mark(icon: Favicons.shared.cached(stop.host) ?? Favicons.shared.cached(site),
                     letter: site.first.map { String($0).uppercased() } ?? "•", size: 20)
            }
        case .from:
            PullRow(title: stop.title, detail: "opened this tab", lit: lit) { mark("arrow.uturn.backward", lit: lit) }
        case .search:
            PullRow(title: "Search History", detail: "", lit: lit) { mark("magnifyingglass", lit: lit) }
        }
    }

    private static func mark(_ name: String, lit: Bool) -> some View {
        Symbol(name, size: 12)
            .foregroundStyle(lit ? Palette.ground : Palette.muted)
            .frame(width: 20, height: 20)
    }
}

struct PullRow<Picture: View>: View {
    let title: String
    let detail: String
    let lit: Bool
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        HStack(spacing: 8) {
            picture()
            Text(title)
                .font(.system(size: 12.5, weight: lit ? .medium : .regular))
                .foregroundStyle(lit ? Palette.ground : Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                // The page's name before the site's: the site gives way first.
                .layoutPriority(1)
            Spacer(minLength: 8)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(lit ? Palette.ground.opacity(0.6) : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PullList.rowHeight)
        .background(lit ? Palette.ink : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
