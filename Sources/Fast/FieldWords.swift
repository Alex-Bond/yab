import AppKit
import QuartzCore

/// The field's words while nothing is in it, drawn by us rather than as the
/// text field's placeholder, a layer a letter, so that when they change the
/// letters the old words and the new share keep who they are and slide to
/// where the new words want them, and only the rest fade, on the spot. Tab
/// after "youtube": the same seven letters, two of them capitals now, move
/// over to make room for "Search " coming up in front of them, and go from
/// ink to the placeholder's gray on the way. ⌫ plays it back.
///
/// A text morph, as for a title or a button's label: the line reads as edited, not replaced. Only for Tab into a site
/// and out of it, where the site's name is carried into "Search YouTube".
/// Typing, the words are simply gone, in the frame the key lands, as a
/// placeholder would be.
///
/// Core Animation runs it, one commit and the render server does the rest:
/// a SwiftUI animation here would be a main-thread commit every frame.
final class FieldWords: NSView {
    /// The field's own face, size and placeholder gray.
    static let font = NSFont.systemFont(ofSize: 20)
    static let faint: Float = 0.3

    /// How long the letters take to move, and the curve things arrive on.
    static let travel: CFTimeInterval = 0.26
    /// A new letter comes up a hair after the others start to move, over
    /// most of their way; a letter no longer wanted goes quicker, slow to
    /// start, so old and new are on the line together and there is never a
    /// frame with next to nothing on it.
    static let comeDelay: CFTimeInterval = 0.03
    static let come: CFTimeInterval = 0.2
    static let go: CFTimeInterval = 0.16
    private static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// Room round each letter's picture, for the strokes that reach past
    /// its advance.
    private static let pad: CGFloat = 3

    private struct Glyph {
        let layer: CALayer
        var character: Character
        var x: CGFloat
    }

    /// What the words say now, and whether in ink (typed words, on their
    /// way somewhere) or in the placeholder's gray.
    private(set) var words = ""
    private(set) var faint = true
    private var glyphs: [Glyph] = []
    /// Letters fading out, taken away when they have.
    private var leaving: [CALayer] = []
    private let run = CALayer()

    /// Where the words start in the field, and their baseline from its top,
    /// as the field sets its own text.
    var origin = CGPoint(x: 2, y: 0) {
        didSet {
            guard origin != oldValue, !busy else { return }
            let (text, faint) = (words, self.faint)
            still {
                clear()
                place(text, faint: faint, shift: 0)
            }
        }
    }

    /// A change asked for, to be played once layout has put the field
    /// where it will be drawn: Tab puts a site's chip before the field,
    /// which moves it, and the old words have to start from where they
    /// were on the screen, not where they were in the field.
    private struct Carry {
        let from: (words: String, faint: Bool)?
        let to: (words: String, faint: Bool)
        let windowX: CGFloat
        let veiling: NSView?
    }
    private var pending: Carry?
    /// What is drawn over while the words play: the field's own text, when
    /// the words end up being it. Shown again as they land.
    private var veiled: NSView?
    private var landing: DispatchWorkItem?

    /// Whether letters are on their way somewhere.
    var busy: Bool { pending != nil || landing != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        run.anchorPoint = .zero
        run.masksToBounds = false
        layer?.addSublayer(run)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    // MARK: Asked

    /// These words, at once.
    func set(_ text: String, faint: Bool) {
        guard text != words || faint != self.faint || glyphs.count != text.count else { return }
        still {
            clear()
            place(text, faint: faint, shift: 0)
        }
    }

    /// These words, the letters they share with what is shown now (or with
    /// `from`, put where the field showed it) carried over. `veiling`, the
    /// field's own text, is hidden until they land, when the words end up
    /// saying what it does.
    func carry(from: (words: String, faint: Bool)? = nil, to text: String, faint: Bool, veiling: NSView? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            set(text, faint: faint)
            return
        }
        pending = Carry(from: from, to: (text, faint), windowX: seenX ?? windowX, veiling: veiling)
        veiling?.alphaValue = 0
        needsLayout = true
    }

    /// Everything where it would have ended, now: a key was typed.
    func settle() {
        pending = nil
        landing?.perform()
        landing?.cancel()
        landing = nil
        still {
            for layer in leaving { layer.removeFromSuperlayer() }
            leaving = []
            for glyph in glyphs {
                glyph.layer.removeAllAnimations()
            }
            run.removeAllAnimations()
        }
        veiled?.alphaValue = 1
        veiled = nil
    }

    // MARK: Played

    private var windowX: CGFloat { convert(NSPoint.zero, to: nil).x }

    /// Where the field was in the window the last time it was looked at,
    /// before whatever is changing now moved it: by the time the field
    /// hears of Tab, the site's chip has already pushed it along.
    private var seenX: CGFloat?

    /// The field is where it is: remembered, for the next change to start
    /// from.
    func seen() {
        guard pending == nil else { return }
        seenX = windowX
    }

    /// The field moved in the window (the site's chip came or went): while
    /// letters are on their way, the line is held where it was on the
    /// screen and eased over to the field's new place on the letters' own
    /// curve, so SwiftUI laying the row out a pass later never jumps them.
    @objc private func moved() {
        // Between changes the field's own updates say where it was: a move
        // heard here first is the change itself, the chip laid out before
        // the field hears of Tab, and must not count as where it was.
        guard landing != nil, let before = seenX else { return }
        let x = windowX
        seenX = x
        guard abs(before - x) > 0.5 else { return }
        let hold = CABasicAnimation(keyPath: "position.x")
        hold.fromValue = before - x
        hold.toValue = 0
        hold.isAdditive = true
        hold.duration = Self.travel
        hold.timingFunction = Self.curve
        run.add(hold, forKey: "moved")
    }

    private var watched: [NSView] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for view in watched {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
        }
        watched = []
        guard window != nil else { return }
        // The field, and what SwiftUI holds it in: whichever of them is
        // moved when the row is laid out again.
        var view = superview
        for _ in 0..<3 {
            guard let this = view else { break }
            this.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.frameDidChangeNotification, object: this)
            watched.append(this)
            view = this.superview
        }
    }

    override func layout() {
        super.layout()
        // The line hangs from the field's top, whatever its height.
        if run.position.y != bounds.height {
            still { run.position = CGPoint(x: 0, y: bounds.height) }
        }
        guard let carry = pending else { return }
        pending = nil
        play(carry, shift: carry.windowX - windowX)
        seenX = windowX
    }

    private func play(_ carry: Carry, shift: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = CACurrentMediaTime()

        for layer in leaving { layer.removeFromSuperlayer() }
        leaving = []
        if let from = carry.from {
            clear()
            place(from.words, faint: from.faint, shift: shift)
        } else if shift != 0 {
            for glyph in glyphs { glyph.layer.position.x += shift }
        }

        let old = glyphs
        let text = carry.to.words
        let characters = Array(text)
        let xs = offsets(text)
        let pairs = Self.shared(old.map(\.character), characters)
        var kept = Set<Int>()
        var next: [Glyph] = []
        // The stretch of line each carried letter sweeps on its way. A new
        // letter under one comes up once it has gone by, and a letter going
        // where one lands goes at once: Tab after "wiki" slid "Wikipedia"
        // across "Search " coming up and over ".org" still going, and for a
        // few frames the line read "SearcWikipergdia".
        var swept: [ClosedRange<CGFloat>] = []
        for (j, character) in characters.enumerated() {
            guard let i = pairs[j] else { continue }
            let from = (old[i].layer.presentation()?.position.x ?? old[i].layer.position.x) + Self.pad
            let to = origin.x + xs[j]
            guard abs(from - to) > 0.5 else { continue }
            let width = Self.box(character).width - 2 * Self.pad
            swept.append(min(from, to)...(max(from, to) + width))
        }
        func crossed(_ x: CGFloat, _ character: Character) -> Bool {
            let span = x...(x + Self.box(character).width - 2 * Self.pad)
            return swept.contains { $0.overlaps(span) }
        }

        for (j, character) in characters.enumerated() {
            let x = origin.x + xs[j]
            if let i = pairs[j] {
                kept.insert(i)
                var glyph = old[i]
                let from = glyph.layer.presentation()?.position.x ?? glyph.layer.position.x
                glyph.layer.position.x = x - Self.pad
                move(glyph.layer, from: from, now: now)
                if glyph.character != character {
                    // The same letter in another case: its picture turns
                    // into the new one as it goes.
                    let before = glyph.layer.contents
                    glyph.layer.contents = image(character)
                    glyph.layer.bounds.size = Self.box(character)
                    let fade = CABasicAnimation(keyPath: "contents")
                    fade.fromValue = before
                    // Quick: the two cases drawn over each other read as
                    // a smudge ("tube" and "Tube" at once).
                    fade.duration = Self.travel * 0.3
                    fade.timingFunction = Self.curve
                    glyph.layer.add(fade, forKey: "contents")
                    glyph.character = character
                }
                glyph.x = x
                next.append(glyph)
            } else {
                let layer = letter(character, at: x)
                layer.opacity = 1
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                let late = crossed(x, character)
                fade.beginTime = now + (late ? Self.travel * 0.45 : Self.comeDelay)
                fade.duration = late ? Self.come * 0.6 : Self.come
                fade.fillMode = .backwards
                fade.timingFunction = Self.curve
                layer.add(fade, forKey: "opacity")
                next.append(Glyph(layer: layer, character: character, x: x))
            }
        }
        for (i, glyph) in old.enumerated() where !kept.contains(i) {
            let from = glyph.layer.presentation()?.opacity ?? glyph.layer.opacity
            glyph.layer.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            let underfoot = crossed((glyph.layer.presentation()?.position.x ?? glyph.layer.position.x) + Self.pad, glyph.character)
            fade.duration = underfoot ? Self.go * 0.2 : Self.go
            fade.timingFunction = CAMediaTimingFunction(name: underfoot ? .easeOut : .easeIn)
            glyph.layer.add(fade, forKey: "opacity")
            leaving.append(glyph.layer)
        }
        glyphs = next
        words = text

        let target: Float = carry.to.faint ? Self.faint : 1
        if run.opacity != target {
            let from = run.presentation()?.opacity ?? run.opacity
            run.opacity = target
            let tone = CABasicAnimation(keyPath: "opacity")
            tone.fromValue = from
            tone.duration = Self.travel
            tone.timingFunction = Self.curve
            run.add(tone, forKey: "opacity")
        }
        faint = carry.to.faint
        CATransaction.commit()

        veiled = carry.veiling
        let land = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.landing = nil
            self.still {
                for layer in self.leaving { layer.removeFromSuperlayer() }
                self.leaving = []
            }
            if let veiled = self.veiled {
                // The field's text takes over from the words, in one frame.
                veiled.alphaValue = 1
                self.veiled = nil
                self.isHidden = true
            }
        }
        landing?.cancel()
        landing = land
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.travel + Self.comeDelay, execute: land)
    }

    private func move(_ layer: CALayer, from: CGFloat, now: CFTimeInterval) {
        guard abs(from - layer.position.x) > 0.01 else { return }
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = from
        slide.duration = Self.travel
        slide.timingFunction = Self.curve
        layer.add(slide, forKey: "position.x")
    }

    // MARK: Letters

    private func clear() {
        for glyph in glyphs { glyph.layer.removeFromSuperlayer() }
        glyphs = []
    }

    private func place(_ text: String, faint: Bool, shift: CGFloat) {
        let xs = offsets(text)
        glyphs = zip(Array(text), xs).map { character, x in
            let at = origin.x + x + shift
            return Glyph(layer: letter(character, at: at), character: character, x: at)
        }
        run.opacity = faint ? Self.faint : 1
        words = text
        self.faint = faint
    }

    private func letter(_ character: Character, at x: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        // Drawn at its own size, so a letter turning into a wider one
        // mid-way is never squeezed into the old one's box.
        layer.contentsGravity = .bottomLeft
        layer.contentsScale = scale
        layer.contents = image(character)
        let size = Self.box(character)
        let descent = -Self.font.descender
        layer.frame = CGRect(x: x - Self.pad, y: -origin.y - descent - Self.pad,
                             width: size.width, height: size.height)
        run.addSublayer(layer)
        return layer
    }

    /// Where each letter starts along the line, kerning and all, as the
    /// field would set the words.
    private func offsets(_ text: String) -> [CGFloat] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: Self.font]))
        return text.indices.map { index in
            CTLineGetOffsetForStringIndex(line, NSRange(index..<index, in: text).location, nil)
        }
    }

    /// Which of `b`'s letters are `a`'s, by position in `a`: the longest run
    /// of letters the two share in order, capitals and small alike.
    static func shared(_ a: [Character], _ b: [Character]) -> [Int: Int] {
        let a = a.map { $0.lowercased() }, b = b.map { $0.lowercased() }
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [Int: Int] = [:]
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs[j] = i
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    // MARK: Pictures

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var pictures: [String: CGImage] = [:]

    private static func box(_ character: Character) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(width) + 2 * pad, height: ceil(font.ascender - font.descender) + 2 * pad)
    }

    /// One letter in the field's ink, at the screen's scale, kept.
    private func image(_ character: Character) -> CGImage? {
        let scale = scale
        var ink: CGColor = Palette.NS.ink.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = Palette.NS.ink.cgColor }
        let key = "\(character)|\(scale)|\(ink.components ?? [])"
        if let made = pictures[key] { return made }
        let size = Self.box(character)
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setShouldSmoothFonts(false)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(character),
            attributes: [.font: Self.font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink]
        ))
        context.textPosition = CGPoint(x: Self.pad, y: Self.pad - Self.font.descender)
        CTLineDraw(line, context)
        let made = context.makeImage()
        pictures[key] = made
        return made
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    private func redraw() {
        still {
            for glyph in glyphs {
                glyph.layer.contentsScale = scale
                glyph.layer.contents = image(glyph.character)
            }
        }
    }

    /// Changes made at once, no implicit animation on a layer of our own.
    private func still(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
