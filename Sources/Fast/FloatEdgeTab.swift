import AppKit

/// What shows of a video tucked behind a side of the screen (read off a
/// 2x capture, 2026-10-06): a tab 24 points out of the window's side and 96 tall in its
/// middle, its outer corners round (10), of which 20 show past the screen's
/// edge, and a chevron pointing back in, light grey, round-ended. The
/// window goes all the way behind the side.
/// The tab is not drawn here: the window and its tab are one shape of the
/// picture itself, blurred and greyed (`Frost`), cut by the window's mask
/// (`outline`), joined by small inward curves (2) behind the edge. Nothing
/// rings it but the shadow and hairline the system gives every window, as
/// Safari's has nothing of its own. This view adds the chevron and the
/// restore action for accessibility; FloatLip keeps the clicks, carries and
/// gestures.
final class FloatEdgeTab: NSView {
    /// How far the tab stands out of the window's side.
    nonisolated static let visible: CGFloat = 24
    /// How much of it shows past the screen's edge: Safari's keeps the last
    /// 4 of its 24 and the curves where it meets the window behind it.
    nonisolated static let shown: CGFloat = 20
    /// The tab's whole width: it reaches on into the window, so the two are
    /// one shape.
    nonisolated static let width: CGFloat = visible + 10
    nonisolated static let height: CGFloat = 96
    /// The tab's outer corners, and the small inward curves where it meets
    /// the window.
    nonisolated static let radius: CGFloat = 10
    nonisolated static let fillet: CGFloat = 2

    /// The chevron, measured on a 2x capture by the middle of its line: the point 9.4 in from the tab's outer side,
    /// the ends 14 in and 11.3 above and below the middle, a 4 point
    /// round-ended line, white at 0.55.
    nonisolated static let chevronLine: CGFloat = 4
    nonisolated static let chevronWhite: CGFloat = 0.55
    /// Halfway between its point and its ends, from the tab's outer side.
    nonisolated static let chevronMiddle: CGFloat = (9.4 + 14) / 2

    /// The chevron for a tab whose outer side is at `outer`, its point at
    /// `middle`, behind `side`.
    nonisolated static func chevron(outer: CGFloat, middle: CGFloat, side: FloatPark.Side) -> CGPath {
        let x = { (inset: CGFloat) in side == .right ? outer + inset : outer - inset }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x(14), y: middle + 11.3))
        path.addLine(to: CGPoint(x: x(9.4), y: middle))
        path.addLine(to: CGPoint(x: x(14), y: middle - 11.3))
        return path
    }

    /// What shows of a window tucked behind `side`, in its own coordinates:
    /// its body, from `edge` in from the side the tab is on, and the tab (or
    /// a call's tray) `tab` out of that side, joined by inward curves. The
    /// same points whatever the tab's size, so one tab can be animated into
    /// another.
    nonisolated static func outline(body: NSRect, tab: NSRect?, side: FloatPark.Side, in bounds: NSRect,
                                    corner: CGFloat, radius: CGFloat = FloatEdgeTab.radius) -> CGPath {
        // Drawn for a window behind the right side, the tab on its left,
        // and turned over for the left side.
        func flip(_ r: NSRect) -> NSRect {
            side == .right ? r : NSRect(x: bounds.minX + bounds.maxX - r.maxX, y: r.minY, width: r.width, height: r.height)
        }
        let b = flip(body), x = b.minX
        let path = CGMutablePath()
        let R = min(corner, b.width / 2, b.height / 2)
        path.move(to: CGPoint(x: b.midX, y: b.maxY))
        path.addArc(tangent1End: CGPoint(x: x, y: b.maxY), tangent2End: CGPoint(x: x, y: b.minY), radius: R)
        if let tab = tab.map(flip), x - tab.minX > 0.5 {
            let out = x - tab.minX
            let top = min(tab.maxY, b.maxY - R), bottom = max(tab.minY, b.minY + R)
            let f = max(0, min(fillet, out / 2, b.maxY - R - top, bottom - (b.minY + R)))
            let r = max(0, min(radius, out - f, (top - bottom) / 2))
            path.addLine(to: CGPoint(x: x, y: top + f))
            path.addArc(tangent1End: CGPoint(x: x, y: top), tangent2End: CGPoint(x: tab.minX, y: top), radius: f)
            path.addArc(tangent1End: CGPoint(x: tab.minX, y: top), tangent2End: CGPoint(x: tab.minX, y: bottom), radius: r)
            path.addArc(tangent1End: CGPoint(x: tab.minX, y: bottom), tangent2End: CGPoint(x: x, y: bottom), radius: r)
            path.addArc(tangent1End: CGPoint(x: x, y: bottom), tangent2End: CGPoint(x: x, y: bottom - f), radius: f)
        }
        path.addArc(tangent1End: CGPoint(x: x, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY), radius: R)
        path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.maxY), radius: R)
        path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: x, y: b.maxY), radius: R)
        path.closeSubpath()
        guard side == .left else { return path }
        var turn = CGAffineTransform(translationX: bounds.minX + bounds.maxX, y: 0).scaledBy(x: -1, y: 1)
        return path.copy(using: &turn) ?? path
    }

    /// How much more of it comes out under the pointer.
    nonisolated static let nudge: CGFloat = 6

    /// What a call's tab says under its chevron, top to bottom: the
    /// microphone off, the camera on, the screen shown. A video's says
    /// nothing, and a call heard, unseen and not showing says nothing too.
    struct Marks: Equatable {
        var muted = false
        var camera = false
        var presenting = false

        /// The glyphs, in order, and their color.
        var shown: [(symbol: String, color: NSColor)] {
            var out: [(String, NSColor)] = []
            if muted { out.append(("mic.slash.fill", FloatEdgeTab.red)) }
            if camera { out.append(("video.fill", NSColor(white: 1, alpha: 0.78))) }
            if presenting { out.append(("rectangle.inset.filled.on.rectangle", NSColor(white: 1, alpha: 0.78))) }
            return out
        }
    }
    /// The call's red, as its window's muted mark.
    nonisolated(unsafe) static let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    /// Each mark adds this much to the tab's height.
    nonisolated static let markStep: CGFloat = 17

    nonisolated static func height(for marks: Marks) -> CGFloat {
        height + CGFloat(marks.shown.count) * markStep
    }

    /// Coordinates are in the full media host, which is never resized or
    /// ordered out when tucked. A right-parked host exposes its left edge.
    nonisolated static func tabFrame(in bounds: NSRect, side: FloatPark.Side,
                                    width requestedWidth: CGFloat = FloatEdgeTab.width,
                                    height requestedHeight: CGFloat = FloatEdgeTab.height) -> NSRect {
        let width = min(max(0, requestedWidth), max(0, bounds.width))
        let height = min(requestedHeight, max(0, bounds.height))
        let x = side == .right ? bounds.minX : bounds.maxX - width
        return NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
    }

    var side = FloatPark.Side.right {
        didSet { if side != oldValue { updateSymbol(); needsLayout = true } }
    }
    var lit = false {
        didSet { if lit != oldValue { updateSymbol() } }
    }
    var marks = Marks() {
        didSet { if marks != oldValue { mark(from: oldValue) } }
    }
    var onRestore: (() -> Void)?

    private let rim = CAShapeLayer()
    private let chevron = CAShapeLayer()
    /// A call's tab says who talks, and that a hand is up, in light along
    /// its inner side, not in marks: white and breathing while someone
    /// talks, warm and still while a hand waits.
    private let glow = CAGradientLayer()
    /// A reaction in the chevron's place for a moment.
    private let face = CATextLayer()
    /// The marks under the chevron, by symbol, so one staying is the same
    /// layer moving rather than a new one.
    private var glyphs: [String: CALayer] = [:]
    private var displayObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rim.fillColor = nil
        rim.lineWidth = 1
        rim.actions = ["path": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(rim)
        chevron.fillColor = nil
        chevron.lineCap = .round
        chevron.lineJoin = .round
        chevron.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(chevron)
        glow.opacity = 0
        glow.cornerRadius = 1
        glow.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(glow)
        face.alignmentMode = .center
        face.fontSize = 12
        face.opacity = 0
        face.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Restore video")
        setAccessibilityHelp("Bring the picture-in-picture window back onto the screen.")
        updateSymbol()
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSymbol() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let displayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayObserver)
        }
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        // Half a point in, so the hairline is whole on the pixel grid.
        // Only the side that faces into the screen: the far one is under
        // the picture while it is still going.
        let r = Self.radius, box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGMutablePath()
        if side == .right {
            path.move(to: CGPoint(x: box.maxX, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY), radius: r)
            path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        } else {
            path.move(to: CGPoint(x: box.minX, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX, y: box.minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.minX, y: box.minY), radius: r)
            path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        }
        rim.path = path
        chevron.frame = bounds
        // With marks under it, the chevron goes up by half of what they
        // take, so the whole is in the middle of the tab.
        let shown = marks.shown
        let middle = bounds.midY + CGFloat(shown.count) * Self.markStep / 2
        let x = { (inset: CGFloat) in self.side == .right ? inset : self.bounds.width - inset }
        chevron.path = Self.chevron(outer: x(0), middle: middle, side: side)
        glow.frame = CGRect(x: side == .right ? 0 : bounds.width - 2, y: middle - 22, width: 2, height: 44)
        face.frame = CGRect(x: x(Self.chevronMiddle) - 8, y: middle - 8, width: 16, height: 16)
        // Centered under the chevron's middle.
        let column = x(Self.chevronMiddle)
        for (index, item) in shown.enumerated() {
            guard let layer = glyphs[item.symbol] else { continue }
            layer.position = CGPoint(x: column, y: (middle - 11.3 - 10 - CGFloat(index) * Self.markStep).rounded())
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSymbol()
    }

    private func updateSymbol() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Light grey on the tab, brighter under the pointer, at once.
        chevron.strokeColor = NSColor(white: 1, alpha: lit || contrast ? 0.9 : Self.chevronWhite).cgColor
        chevron.lineWidth = Self.chevronLine + (contrast ? 0.5 : 0)
        CATransaction.commit()
        // No rim, as the system's has none to see; Increase Contrast gets one.
        rim.strokeColor = NSColor(white: 1, alpha: contrast ? 0.4 : 0).cgColor
        needsLayout = true
    }

    /// Marks come and go by fading and growing a little from the middle,
    /// 0.18 s; the ones staying slide to their new place with the tab.
    private func mark(from old: Marks) {
        let wanted = Set(marks.shown.map(\.symbol))
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (symbol, layer) in glyphs where !wanted.contains(symbol) {
            glyphs[symbol] = nil
            guard !reduce, window != nil else { layer.removeFromSuperlayer(); continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.opacity = 0
            layer.transform = CATransform3DMakeScale(0.6, 0.6, 1)
            CATransaction.commit()
        }
        for item in marks.shown where glyphs[item.symbol] == nil {
            let layer = CALayer()
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(.init(paletteColors: [item.color]))
            let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.bounds = CGRect(x: 0, y: 0, width: 13, height: 11)
            self.layer?.addSublayer(layer)
            glyphs[item.symbol] = layer
            guard !reduce, window != nil else { continue }
            layer.opacity = 0
            layer.transform = CATransform3DMakeScale(0.6, 0.6, 1)
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.18)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
        setAccessibilityValue(marks.shown.isEmpty ? nil : [
            marks.muted ? "Muted" : nil, marks.camera ? "Camera on" : nil, marks.presenting ? "Sharing screen" : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    /// Someone talking (true) or nobody, a hand waiting or not: the light
    /// along the inner side. Talking breathes, a little more than a second
    /// a breath; a hand is still. A hand outranks a voice.
    func light(talking: Bool, hand: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let warm = NSColor(srgbRed: 1, green: 0.76, blue: 0.29, alpha: 1)
        let color = hand ? warm : NSColor.white
        glow.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0).cgColor]
        glow.shadowColor = color.cgColor
        glow.shadowRadius = 4
        glow.shadowOpacity = 0.6
        glow.shadowOffset = .zero
        let on = talking || hand
        if !on {
            glow.removeAnimation(forKey: "breath")
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            glow.opacity = 0
            CATransaction.commit()
            return
        }
        glow.opacity = hand || reduce ? 1 : 0.8
        guard talking, !hand, !reduce, glow.animation(forKey: "breath") == nil else {
            if hand { glow.removeAnimation(forKey: "breath") }
            return
        }
        // A voice is longer light as well as brighter: 44 points quiet, up
        // to 68 at its loudest (the plan's 44 + 24k; the page gives no
        // level, so a breath stands for it).
        let bright = CABasicAnimation(keyPath: "opacity")
        bright.fromValue = 0.35
        bright.toValue = 1
        let long = CABasicAnimation(keyPath: "bounds.size.height")
        long.fromValue = 44
        long.toValue = 68
        let breath = CAAnimationGroup()
        breath.animations = [bright, long]
        breath.duration = 0.6
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breath, forKey: "breath")
    }

    /// A reaction where the chevron is, for a moment: the chevron goes as
    /// the face grows in 0.2 s past whole by 8%, held 0.9 s, and comes back.
    func flash(_ emoji: String) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        face.string = emoji
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : 0.2)
        chevron.opacity = 0
        CATransaction.commit()
        face.opacity = 1
        if !reduce {
            // Damping 0.63 overshoots by 8%; 24 a second reaches whole in
            // about 0.2 s.
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.3
            grow.toValue = 1
            grow.stiffness = 24 * 24
            grow.damping = 2 * 0.63 * 24
            grow.duration = grow.settlingDuration
            face.add(grow, forKey: "grow")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(reduce ? 0 : 0.16)
            self.face.opacity = 0
            self.chevron.opacity = 1
            CATransaction.commit()
        }
    }

    /// The covering FloatLip remains the mouse/gesture responder.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityPerformPress() -> Bool {
        guard !isHiddenOrHasHiddenAncestor, alphaValue > 0.01, let onRestore else { return false }
        onRestore()
        return true
    }
}

/// The picture on its way behind a side of the screen: blurred, then grey,
/// as it turns into its tab. No rim of its own: the light line round the
/// window is the system's. Over the page and under the buttons, nothing at all
/// while the window is out.
final class Frost: NSView {
    /// The blur a window comes up and goes away through (`fade`).
    private let blur = NSVisualEffectView()
    private let dim = CALayer()

    /// Safari's grey over the blurred picture: 52 of 255, at `darkest`.
    nonisolated(unsafe) static let grey = NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 52 / 255, alpha: 1)
    /// Safari's blur, its Gaussian's radius in points.
    static let sigma: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        blur.alphaValue = 0
        addSubview(blur)
        dim.backgroundColor = Self.grey.cgColor
        dim.opacity = 0
        dim.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(dim)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// How blurred, nought to one, and how grey, the grey's opacity. The
    /// blur of a picture behind a side is the picture's own (`Floater`'s
    /// `blurPicture`), a plain Gaussian: the system's materials
    /// tint as they blur and took the blue out of it.
    func show(blur amount: CGFloat, dark: CGFloat) {
        isHidden = amount <= 0 && dark <= 0
        blur.alphaValue = 0
        blurred = amount
        dim.opacity = Float(dark)
    }
    private var blurred: CGFloat = 0

    /// The blur alone, from one amount to another, the dark left off: a
    /// window coming up or going away.
    func fade(blur from: CGFloat, to: CGFloat, over duration: TimeInterval) {
        isHidden = false
        dim.opacity = 0
        blurred = 0
        blur.alphaValue = from
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            blur.animator().alphaValue = to
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, to <= 0, self.blur.alphaValue <= 0, self.dim.opacity <= 0 else { return }
                self.isHidden = true
            }
        })
    }

    var shown: (blur: CGFloat, dark: CGFloat) { (isHidden ? 0 : max(blur.alphaValue, blurred), isHidden ? 0 : CGFloat(dim.opacity)) }
}

/// What a tucked call's tab grows into from the edge, a tray
/// (docs/call-window.md, "At the edge"). It is the tab itself, the same
/// picture under the same blur and grey (Frost), grown out by the tray's
/// width while the rest of the window stays behind the side. The chevron
/// stays where the tab has it, in the strip by the screen's edge that
/// nothing else covers; a face and words come in from the other side, and
/// under the pointer a second row: Deny and Admit for someone asking to
/// come in, Reply for a message, which itself stretches into the field.
/// One tray goes from one thing to the next without closing (Floater.edge).
final class EdgeTray: NSView, NSTextFieldDelegate {
    enum Item: Equatable {
        case join(name: String, face: URL?, others: Int)
        case message(name: String, words: String, face: URL?)
        case hand(name: String, face: URL?)

        var name: String {
            switch self {
            case .join(let name, _, _), .message(let name, _, _), .hand(let name, _): return name
            }
        }
        var face: URL? {
            switch self {
            case .join(_, let face, _), .message(_, _, let face), .hand(_, let face): return face
            }
        }
        /// Whether the pointer brings out a second row.
        var opens: Bool { if case .hand = self { return false } else { return true } }
    }

    /// One inset on every side of what is inside, the face, the pills.
    static let inset: CGFloat = 10
    static let faceSide: CGFloat = 26
    static let pillHeight: CGFloat = 22
    /// One line: the face with the inset above and below it rounded up.
    static let compact: CGFloat = 44
    /// The second row: a pill with the inset over and under it.
    static let row: CGFloat = pillHeight + 2 * inset

    /// How far out past the edge, and how tall: compact, or open under
    /// the pointer.
    static func size(of item: Item, open: Bool) -> NSSize {
        let width: CGFloat
        switch item {
        case .join: width = 186
        case .message: width = 200
        case .hand: width = 170
        }
        return NSSize(width: width, height: compact + (open && item.opens ? row : 0))
    }

    /// The tray's corners: a capsule when compact, the window's own
    /// rhythm when open, the pills inside concentric with them.
    static func radius(height: CGFloat) -> CGFloat { min(height / 2, compact / 2) }

    var onAdmit: (() -> Void)?
    var onDeny: (() -> Void)?
    /// A click on it, not on a button: the window comes out.
    var onOpen: (() -> Void)?
    /// The pointer on it or off it.
    var onHover: ((Bool) -> Void)?
    /// Reply pressed: the field is open; the window should become key.
    var onReplying: (() -> Void)?
    /// Words sent from the field.
    var onSend: ((String) -> Void)?
    var side = FloatPark.Side.right { didSet { needsLayout = true } }
    private(set) var item: Item?
    /// The second row is out.
    var open = false { didSet { if open != oldValue { needsLayout = true; layoutRow() } } }
    private(set) var replying = false
    /// Let in, and saying so: the page's knock going away doesn't close it.
    private(set) var letIn = false
    /// The pointer on it: the chevron a shade brighter.
    var lit = false { didSet { if lit != oldValue { tintChevron() } } }
    /// Messages from the same one in a row.
    private var count = 1

    private var line = Line()
    private let deny = NSButton()
    private let admit = NSButton()
    private let reply = NSButton()
    private let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private let chevron = CAShapeLayer()

    /// A face and two lines of words: one set, so the next thing coming in
    /// can cross the last one.
    private final class Line {
        let picture = NSImageView()
        let title = NSTextField(labelWithString: "")
        let words = NSTextField(labelWithString: "")
        var views: [NSView] { [picture, title, words] }

        init() {
            picture.wantsLayer = true
            picture.layer?.cornerRadius = EdgeTray.faceSide / 2
            picture.layer?.masksToBounds = true
            picture.imageScaling = .scaleProportionallyUpOrDown
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .white
            words.font = .systemFont(ofSize: 11)
            words.textColor = NSColor(white: 1, alpha: 0.72)
            for label in [title, words] { label.lineBreakMode = .byTruncatingTail }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.views.forEach(addSubview)
        for (button, main, said) in [(deny, false, "Deny"), (admit, true, "Admit"), (reply, false, "Reply")] {
            CallIsland.pill(button, main: main)
            CallIsland.titled(button, said, main: main)
            button.target = self
            button.alphaValue = 0
            addSubview(button)
        }
        deny.action = #selector(pressedDeny)
        admit.action = #selector(pressedAdmit)
        reply.action = #selector(pressedReply)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Message everyone", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.45),
        ])
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        counter.font = .systemFont(ofSize: 10, weight: .bold)
        counter.textColor = NSColor(white: 0.07, alpha: 1)
        counter.alignment = .center
        counter.wantsLayer = true
        counter.layer?.backgroundColor = NSColor(white: 1, alpha: 0.96).cgColor
        counter.layer?.cornerRadius = 8
        counter.isHidden = true
        addSubview(counter)
        chevron.fillColor = nil
        chevron.lineWidth = FloatEdgeTab.chevronLine
        chevron.lineCap = .round
        chevron.lineJoin = .round
        layer?.addSublayer(chevron)
        tintChevron()
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What it says. The first time, at once; after, the last face and
    /// words go as the new come in from the edge's side, in the same tray.
    func show(_ item: Item) {
        let before = self.item
        let same: Bool = {
            if case .message(let a, _, _)? = before, case .message(let b, _, _) = item { return a == b }
            return false
        }()
        count = same ? count + 1 : 1
        self.item = item
        letIn = false
        admit.layer?.borderWidth = 0
        open = false
        if before != nil, !same, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let old = line
            line = Line()
            line.views.forEach { $0.alphaValue = 0; addSubview($0) }
            fill(line, item)
            needsLayout = true
            layoutSubtreeIfNeeded()
            let slide: CGFloat = side == .right ? 8 : -8
            line.views.forEach { $0.frame.origin.x += slide }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                old.views.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { old.views.forEach { $0.removeFromSuperview() } })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    self.line.views.forEach {
                        $0.animator().alphaValue = 1
                        $0.animator().frame.origin.x -= slide
                    }
                }
            }
        } else {
            fill(line, item)
        }
        if same { roll(line.words, to: Self.words(item)) }
        counter.stringValue = "\(count)"
        counter.isHidden = count < 2
        if case .join(_, _, let others) = item { CallIsland.titled(admit, others > 0 ? "Admit All" : "Admit", main: true) }
        needsLayout = true
    }

    private static func words(_ item: Item) -> String {
        switch item {
        case .join(_, _, let others): return others > 0 ? "want to join" : "wants to join"
        case .message(_, let words, _): return words
        case .hand: return "raised a hand"
        }
    }

    private func fill(_ line: Line, _ item: Item) {
        if case .join(let who, _, let others) = item, others > 0 {
            line.title.stringValue = "\(who) and \(others) other\(others > 1 ? "s" : "")"
        } else {
            line.title.stringValue = item.name
        }
        line.words.stringValue = Self.words(item)
        line.picture.image = CallIsland.initial(item.name, side: Self.faceSide)
        if let face = item.face {
            URLSession.shared.dataTask(with: face) { [weak picture = line.picture] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { picture?.image = image } }
            }.resume()
        }
    }

    /// The same one wrote again: the old line goes up and out, the new one
    /// comes up from under it.
    private func roll(_ label: NSTextField, to words: String) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = label.layer ?? { label.wantsLayer = true; return label.layer }() else {
            label.stringValue = words
            return
        }
        let push = CATransition()
        push.type = .push
        push.subtype = .fromBottom
        push.duration = 0.22
        push.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(push, forKey: "roll")
        label.stringValue = words
    }

    /// Let in: "wants to join" turns to "joined" where it stands, Admit
    /// lit at once, and the face goes under the chevron, into the window
    /// where the one let in now sits.
    func admitted() {
        guard case .join = item else { return }
        letIn = true
        CallIsland.titled(admit, "Admit", main: true)
        admit.layer?.borderWidth = 2
        admit.layer?.borderColor = NSColor(srgbRed: 0.64, green: 0.58, blue: 1, alpha: 1).cgColor
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        open = false
        roll(line.words, to: "joined")
        guard !reduce, let face = line.picture.layer else { return }
        let to = chevronPoint
        let from = CGPoint(x: line.picture.frame.midX, y: line.picture.frame.midY)
        let travel = CABasicAnimation(keyPath: "transform")
        travel.toValue = CATransform3DConcat(CATransform3DMakeScale(0.4, 0.4, 1),
                                             CATransform3DMakeTranslation(to.x - from.x, to.y - from.y, 0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [travel, fade]
        both.duration = 0.15
        both.beginTime = CACurrentMediaTime() + 0.12
        both.fillMode = .forwards
        both.isRemovedOnCompletion = false
        both.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        face.add(both, forKey: "travel")
    }

    /// Where the tab's outer side would be: the chevron stays where the
    /// tab has it, as far in from the screen's edge.
    private var tabOuter: CGFloat {
        side == .right ? out - FloatEdgeTab.shown : bounds.width - out + FloatEdgeTab.shown
    }

    /// Where the chevron points from, in its strip.
    private var chevronPoint: CGPoint {
        CGPoint(x: side == .right ? tabOuter + FloatEdgeTab.chevronMiddle : tabOuter - FloatEdgeTab.chevronMiddle,
                y: compactMidY)
    }

    /// How far it is out past the edge: the rest reaches on under the
    /// strip, so tab and tray are one shape.
    private var out: CGFloat { bounds.width - (FloatEdgeTab.width - FloatEdgeTab.visible) }
    /// The middle of the first line, where the tab's chevron is: the tray
    /// grows down from it.
    private var compactMidY: CGFloat { bounds.height - Self.compact / 2 }

    /// A rect laid out as if behind the right side, from the outer side
    /// in, turned over for the left.
    private func place(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        let fromOuter = side == .right ? x : bounds.width - x - width
        return NSRect(x: fromOuter, y: y, width: width, height: height)
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        // What is inside runs from the inset to the chevron's strip, an
        // inset short of it.
        let across = out - FloatEdgeTab.visible - 2 * inset
        let top = bounds.height
        let faceY = top - (Self.compact - Self.faceSide) / 2 - Self.faceSide
        line.picture.frame = place(inset, faceY, Self.faceSide, Self.faceSide)
        let textX = inset + Self.faceSide + 8
        let badge: CGFloat = counter.isHidden ? 0 : 16 + 4
        let textWidth = max(0, across - Self.faceSide - 8)
        line.title.frame = place(textX, top - 7 - 15, textWidth - badge, 15)
        line.words.frame = place(textX, top - 22 - 14, textWidth, 14)
        counter.frame = place(inset + across - 16, top - 7 - 15, 16, 16)
        layoutRow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.path = FloatEdgeTab.chevron(outer: tabOuter, middle: compactMidY, side: side)
        CATransaction.commit()
    }

    /// The second row: Deny and Admit, or Reply, or the field Reply
    /// became; out under the pointer.
    private func layoutRow() {
        let inset = Self.inset
        let across = out - FloatEdgeTab.visible - 2 * inset
        let y = inset
        let half = ((across - 6) / 2).rounded(.down)
        deny.frame = place(inset, y, half, Self.pillHeight)
        admit.frame = place(inset + across - half, y, half, Self.pillHeight)
        reply.frame = place(inset, y, across, Self.pillHeight)
        field.frame = place(inset + 11, y + 3, across - 22, 16)
        let asks: Bool = { if case .join = item { return true } else { return false } }()
        let writes: Bool = { if case .message = item { return true } else { return false } }()
        let shown: [(NSView, Bool)] = [(deny, open && asks), (admit, open && asks), (reply, open && writes)]
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Out of sight is out of reach: a pill fading away takes no click.
        for (view, on) in shown where on { view.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduce ? 0 : 0.12
            for (view, on) in shown { view.animator().alphaValue = on ? 1 : 0 }
        }, completionHandler: {
            for (view, _) in shown where view.alphaValue == 0 { view.isHidden = true }
        })
        for (view, on) in shown where !on { (view as? NSButton)?.isEnabled = false }
        for (view, on) in shown where on { (view as? NSButton)?.isEnabled = view !== reply || !replying }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tintChevron() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.strokeColor = NSColor(white: 1, alpha: lit ? 0.9 : FloatEdgeTab.chevronWhite).cgColor
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        lit = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        lit = false
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }

    @objc private func pressedAdmit() { onAdmit?() }
    @objc private func pressedDeny() { onDeny?() }

    /// Reply stretches into the field where it is.
    @objc private func pressedReply() {
        replying = true
        reply.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        reply.attributedTitle = NSAttributedString(string: "")
        reply.isEnabled = false
        field.isHidden = false
        field.stringValue = ""
        onReplying?()
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let words = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return true }
            fly(words)
            onSend?(words)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endReply()
            return true
        }
        return false
    }

    /// Back from the field to the Reply pill.
    func endReply() {
        guard replying else { return }
        replying = false
        field.isHidden = true
        CallIsland.pill(reply, main: false)
        CallIsland.titled(reply, "Reply", main: false)
        reply.isEnabled = true
    }

    /// What was written goes under the chevron, into the call.
    private func fly(_ words: String) {
        let sent = NSTextField(labelWithString: words)
        sent.font = field.font
        sent.textColor = .white
        sent.frame = field.frame
        sent.wantsLayer = true
        addSubview(sent)
        field.stringValue = ""
        field.isHidden = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = sent.layer else {
            sent.removeFromSuperview()
            return
        }
        let to = chevronPoint
        let travel = CABasicAnimation(keyPath: "transform")
        travel.toValue = CATransform3DConcat(CATransform3DMakeScale(0.3, 0.3, 1),
                                             CATransform3DMakeTranslation(to.x - sent.frame.minX, to.y - sent.frame.midY, 0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = 0.1
        fade.duration = 0.08
        let both = CAAnimationGroup()
        both.animations = [travel, fade]
        both.duration = 0.18
        both.fillMode = .forwards
        both.isRemovedOnCompletion = false
        both.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { sent.removeFromSuperview() }
        layer.add(both, forKey: "fly")
        CATransaction.commit()
    }

    /// For the bench: a press on what it shows, or words written into
    /// the field and sent.
    func bench(_ action: String, words: String) {
        switch action {
        case "admit": pressedAdmit()
        case "deny": pressedDeny()
        case "reply":
            pressedReply()
            guard !words.isEmpty else { return }
            field.stringValue = words
            fly(words)
            onSend?(words)
        default: break
        }
    }

    var benchState: [String: Any] {
        ["item": item.map { "\($0)" } ?? "", "title": line.title.stringValue, "words": line.words.stringValue,
         "frame": NSStringFromRect(frame), "shown": Double(alphaValue), "open": open, "replying": replying,
         "count": count]
    }
}
