import AppKit
import SwiftUI

// Mail's screens changing as one thing rather than two (docs/mail.md,
// Motion): what is on both screens
// travels, and everything else gets out of its way.
//
// Between every list and a letter, only the list name travels between
// the list title and breadcrumb. Subjects, senders, counts, dots and row
// backgrounds never join this flight; both screens otherwise change at once.
// ⌘↩ folds the reply into Send, and Send flies to the corner where Sending
// and its ⌘Z wait; C grows the new mail out of the pen by the lights.
//
// The travelling words are pictures drawn once, by the same views the pane
// draws (MailType), on layers over the window: Core Animation moves them on
// the render server, so the main thread pays a few small pictures and
// nothing a frame, however busy it is building the thread under them. The
// pane's own screens come and go by SwiftUI's transitions (MailPane).

/// The words the pane shows, drawn one way for the pane and for the
/// pictures that fly: a travelling word lands on its own pixels.
enum MailType {
    // `lit`: the words the list is searched by, lit where they are found,
    // in the row and in its pictures for the morph alike.
    static func subject(_ text: String, lit: String = "") -> some View {
        Text(MailSearch.lit(text, words: lit)).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
    }
    static func gist(_ text: String, lit: String = "") -> some View {
        Text(MailSearch.lit(" · " + text, words: lit)).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(1)
    }
    static func who(_ text: String, unread: Bool, lit: String = "") -> some View {
        Text(MailSearch.lit(text.isEmpty ? "(nobody)" : text, words: lit))
            .font(.system(size: 13, weight: unread ? .semibold : .regular))
            .foregroundStyle(unread ? Palette.ink : Palette.ink.opacity(0.8))
            .lineLimit(1)
    }
    static func when(_ text: String, late: Bool = false) -> some View {
        Text(text).font(.system(size: 12).monospacedDigit()).foregroundStyle(late ? Color.orange : Palette.muted).lineLimit(1)
    }
    static func title(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
    }
    static func count(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 20).monospacedDigit()).foregroundStyle(Palette.faint)
    }
    static func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .semibold)).lineSpacing(6).foregroundStyle(Palette.ink)
    }
    static func line(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2)
    }
    static func crumb(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
    }
    static func of(_ at: Int, _ count: Int) -> some View {
        Text("\(at) of \(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.muted)
    }
    /// A mail's sender: in one line when folded, whole when open.
    static func from(_ text: String, folded: Bool) -> some View {
        Text(text).font(.system(size: folded ? 12.5 : 13.5, weight: folded ? .medium : .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
    }
    static func newMail() -> some View {
        Text("New Mail").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
    }
}

extension View {
    /// Tells the morph where this part stands, whenever it moves: in the
    /// pane, or (`listed`) in the list's scrolled content, which a scroll
    /// doesn't move, so scrolling costs one part a frame, not every row's.
    /// `on` false: not watched.
    func mailPart(_ id: String, listed: Bool = false, on: Bool = true) -> some View {
        onGeometryChange(for: CGRect.self) { on ? $0.frame(in: .named(listed ? MailMorph.list : MailMorph.space)) : .null } action: { rect in
            guard on else { return }
            if listed { MailMorph.shared.listed[id] = rect } else { MailMorph.shared.parts[id] = rect }
        }
    }

    /// Hidden while its picture travels to it.
    func mailFlying(_ id: String, _ desk: MailDesk) -> some View {
        // At once, whatever the change around it animates: its picture
        // stands in for it from the same frame.
        opacity(desk.flying.contains(id) ? 0 : 1)
            .animation(nil, value: desk.flying.contains(id))
    }
}

@MainActor
final class MailMorph {
    static let shared = MailMorph()
    /// The pane's own coordinate space, top left origin, and the list's
    /// scrolled content's (its rows').
    nonisolated static let space = "mailPane"
    nonisolated static let list = "mailList"

    /// Where each part that travels stood when SwiftUI last laid it out,
    /// in the pane's points; a row's, in the list's content, which stands
    /// in the pane at `list:content`.
    var parts: [String: CGRect] = [:]
    var listed: [String: CGRect] = [:]
    /// The pane, the pen by the lights, the corner's notice: views in the
    /// window, for their places in it.
    weak var pane: NSView?
    weak var newMail: NSView?
    weak var notice: NSView?

    /// A test world's slow motion (bench `agent-mail-space act slow`): every
    /// length times this.
    static var pace: Double = 1

    // The travel: 95% of the way in about 170 ms,
    // at rest by 400, a trace of overshoot. Quicker for what repeats.
    static let travel = (response: 0.30, damping: 0.86)
    static let quick = (response: 0.24, damping: 0.90)
    /// A mark put on a row (S's star): out a little past its size and back.
    static let pop = (response: 0.30, damping: 0.55)
    /// A mark taken off a row (U's dot): away, quickly, never past nothing.
    static let gone = (response: 0.14, damping: 1.0)
    /// How long a row's mark plays, overshoot and all (MailSince), before
    /// it is let go and drawn still.
    static let marked = 0.7
    /// A letter opening out of its row and closing back into it: Apple's
    /// smooth, damped just enough never to pass its place, so nothing
    /// bounces. 95% of the way in about 200 ms, at rest by 400.
    static let opening = (response: 0.27, damping: 1.0)
    /// Between two words that would cross: the second starts when the
    /// first is a third of the way.
    static let beat = 0.045
    /// The same springs for the pane's SwiftUI transitions.
    static func spring(_ s: (response: Double, damping: Double), delay: Double = 0) -> Animation {
        .spring(response: s.response * pace, dampingFraction: s.damping).delay(delay * pace)
    }

    private var sky: MailSky?
    /// Send's notice, waiting for the pill to land.
    private var popping: DispatchWorkItem?
    /// Flights flown, for the bench.
    private(set) var flight = 0
    /// A flight's pictures are up over the window now, for the bench.
    var aloft: Bool { sky != nil }
    /// What the last flight did, for the bench: why it didn't, when it didn't.
    var said = ""
    /// Main-thread milliseconds the last take-off and flight start cost, for the bench.
    var took: Double = 0
    var started: Double = 0

    // MARK: - places

    /// A part's rect in the window's own points.
    func window(_ id: String) -> CGRect? {
        guard let pane, pane.window != nil else { return nil }
        if let rect = listed[id] {
            guard let content = parts["list:content"] else { return nil }
            return pane.convert(rect.offsetBy(dx: content.minX, dy: content.minY), to: nil)
        }
        return parts[id].map { pane.convert($0, to: nil) }
    }

    private func place(of view: NSView?) -> CGRect? {
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    // MARK: - the sky

    /// A layer over the window's content, beside it in the frame (a view
    /// added inside SwiftUI's host never gets its layer into the tree).
    private func open(in window: NSWindow) -> (MailSky, CALayer)? {
        // A flight still up goes; what hides for this one stays hidden.
        sky?.removeFromSuperview()
        sky = nil
        guard let content = window.contentView, let frame = content.superview else { return nil }
        let sky = MailSky(frame: content.frame)
        sky.autoresizingMask = [.width, .height]
        frame.addSubview(sky, positioned: .above, relativeTo: content)
        guard let layer = sky.layer else { sky.removeFromSuperview(); return nil }
        self.sky = sky
        flight += 1
        return (sky, layer)
    }

    /// The flight over: the real parts shown again, and a moment later the
    /// pictures over them gone, so there is never a frame with neither.
    func land(now: Bool = false) {
        let desk = MailDesk.shared
        if !desk.flying.isEmpty {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { desk.flying = [] }
        }
        guard let sky else { return }
        self.sky = nil
        if now { sky.removeFromSuperview() } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { sky.removeFromSuperview() }
        }
    }

    /// This flight lands as its animations end, and by a second at most
    /// should the window's not run (covered, the screen asleep). Set before
    /// the animations: a transaction's completion waits only for those
    /// added after it.
    private func landing(_ now: Int) {
        // Out of Core Animation's commit first: the desk changes from the
        // run loop, as SwiftUI expects, not from inside a commit.
        CATransaction.setCompletionBlock { [self] in
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { if flight == now { land() } } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MailMorph.pace) { [self] in MainActor.assumeIsolated {
            if flight == now, sky != nil { land() }
        } }
    }

    // MARK: - pictures

    /// A view drawn once, as the pane would draw it in this window's look.
    private func picture<V: View>(_ view: V, width: CGFloat?, in window: NSWindow) -> CGImage? {
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let sized = view
            .fixedSize(horizontal: width == nil, vertical: true)
            .frame(width: width, alignment: .leading)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: sized)
        renderer.scale = window.backingScaleFactor
        renderer.isOpaque = false
        var image: CGImage?
        window.effectiveAppearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image
    }

    /// Where a line's baseline sits under the top of its box.
    private static func base(_ size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return font.ascender
    }

    // MARK: - layers and motion

    private func layer(_ image: CGImage?, at rect: CGRect, scale: CGFloat, in sky: CALayer) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.contentsGravity = .topLeft
        // Scaled about its top left, as words grow from where they start.
        layer.anchorPoint = CGPoint(x: 0, y: 1)
        layer.bounds = CGRect(origin: .zero, size: image.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) } ?? rect.size)
        layer.position = CGPoint(x: rect.minX, y: rect.maxY)
        sky.addSublayer(layer)
        return layer
    }

    private func plate(_ rect: CGRect, color: CGColor, corner: CGFloat, in sky: CALayer) -> CALayer {
        let plate = CALayer()
        plate.anchorPoint = .zero
        plate.frame = rect
        plate.backgroundColor = color
        plate.cornerRadius = corner
        plate.cornerCurve = .continuous
        sky.addSublayer(plate)
        return plate
    }

    private static func spring(_ key: String, _ from: Any, _ to: Any, _ s: (response: Double, damping: Double), delay: CFTimeInterval = 0) -> CAAnimation {
        let a = CASpringAnimation(keyPath: key)
        a.mass = 1
        a.stiffness = pow(2 * .pi / s.response, 2)
        a.damping = 4 * .pi * s.damping / s.response
        a.fromValue = from
        a.toValue = to
        // At rest to a thousandth by half a second: no longer, so the real
        // parts take over as soon as the words are home.
        a.duration = min(a.settlingDuration, 0.5)
        a.beginTime = CACurrentMediaTime() + delay * pace
        a.speed = Float(1 / pace)
        a.fillMode = .backwards
        return a
    }

    private static func ease(_ key: String, _ from: Any, _ to: Any, _ duration: CFTimeInterval, delay: CFTimeInterval = 0,
                             curve: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)) -> CAAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay * pace
        a.speed = Float(1 / pace)
        a.timingFunction = curve
        a.fillMode = .backwards
        return a
    }

    /// One word from its place to the one it takes: a picture of each,
    /// meeting on their baselines, the first handing over to the second
    /// early, while they move fastest.
    private func fly(_ from: Word, to: Word, in sky: CALayer, into: NSView, scale: CGFloat, delay: CFTimeInterval = 0, held: CALayer? = nil) {
        let a = into.convert(from.rect, from: nil), b = into.convert(to.rect, from: nil)
        let k = to.size / from.size
        // Tops, in the sky's upward points, that put each baseline on the other's.
        let baseA = MailMorph.base(from.size), baseB = MailMorph.base(to.size)
        // And lefts that put each one's words where the other's are.
        let endA = CGPoint(x: b.minX + to.lead - k * from.lead, y: b.maxY - baseB + k * baseA)
        let startB = CGPoint(x: a.minX + from.lead - to.lead / k, y: a.maxY - baseA + baseB / k)
        let one = held ?? self.layer(from.image, at: a, scale: scale, in: sky)
        let two = self.layer(to.image, at: b, scale: scale, in: sky)
        let s = MailMorph.opening
        one.position = endA
        one.transform = CATransform3DMakeScale(k, k, 1)
        one.opacity = 0
        one.add(MailMorph.titleFlight([
            (MailMorph.spring("position", NSValue(point: CGPoint(x: a.minX, y: a.maxY)), NSValue(point: endA), s), delay),
            (MailMorph.spring("transform.scale", 1, k, s), delay),
            (MailMorph.ease("opacity", 1, 0, 0.09, curve: CAMediaTimingFunction(name: .linear)), delay + 0.01),
        ]), forKey: "title")
        two.add(MailMorph.titleFlight([
            (MailMorph.spring("position", NSValue(point: startB), NSValue(point: CGPoint(x: b.minX, y: b.maxY)), s), delay),
            (MailMorph.spring("transform.scale", 1 / k, 1, s), delay),
            (MailMorph.ease("opacity", 0, 1, 0.09, curve: CAMediaTimingFunction(name: .linear)), delay + 0.04),
        ]), forKey: "title")
    }

    /// Start with the committed frame, after SwiftUI has laid out the letter.
    /// Absolute start times spent part of the flight building that frame,
    /// making short titles such as Other appear to jump straight to the end.
    private static func titleFlight(_ steps: [(CAAnimation, CFTimeInterval)]) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = steps.map { animation, delay in
            animation.beginTime = delay * pace
            return animation
        }
        group.duration = steps.map { $0.0.beginTime + $0.0.duration / Double($0.0.speed) }.max() ?? 0
        return group
    }

    /// A word: its picture, where it stands in the window, its type's size.
    struct Word {
        let image: CGImage?
        let rect: CGRect
        let size: CGFloat
        /// Where its words begin in the picture: a row's gist starts with
        /// its " · ", which the letter's line doesn't have.
        var lead: CGFloat = 0
    }

    // MARK: - only the list title moves between list and letter

    /// A single title, held over the screen while the next one is laid out.
    struct Takeoff {
        let window: NSWindow
        let row: String
        var words: [String: Word] = [:]
        var sky: MailSky?
        var held: [String: CALayer] = [:]
    }

    private func hold(_ t: inout Takeoff) {
        land(now: true)
        guard let (view, sky) = open(in: t.window) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, word) in t.words {
            t.held[id] = layer(word.image, at: view.convert(word.rect, from: nil), scale: t.window.backingScaleFactor, in: sky)
        }
        CATransaction.commit()
        t.sky = view
    }

    private func sky(for t: Takeoff) -> (MailSky, CALayer, held: Bool)? {
        if let held = t.sky, held === sky, let layer = held.layer { return (held, layer, true) }
        return open(in: t.window).map { ($0.0, $0.1, false) }
    }

    /// On every list, only its name travels to the letter's breadcrumb.
    func takeOff(row: MailDesk.Row, title: String) -> Takeoff? {
        guard !MailDesk.still, let pane, let window = pane.window,
              let rect = self.window("list:title") else { return nil }
        let started = CACurrentMediaTime()
        defer { took = (CACurrentMediaTime() - started) * 1000 }
        var out = Takeoff(window: window, row: row.id)
        out.words["list:title"] = Word(image: picture(MailType.title(title), width: rect.width, in: window), rect: rect, size: 20)
        hold(&out)
        return out
    }

    static let letter: Set<String> = ["crumb:name"]
    static func row(_ id: String) -> Set<String> { ["list:title"] }

    func openLetter(_ from: Takeoff, tries: Int = 0) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            let desk = MailDesk.shared
            guard desk.screen == .thread, desk.open?.id == from.row else { return land() }
            guard fresh(["crumb:name"]), let rect = window("crumb:name") else {
                return tries < 4 ? openLetter(from, tries: tries + 1) : land()
            }
            guard let word = from.words["list:title"], let (view, sky, held) = self.sky(for: from) else { return land() }
            let target = Word(image: picture(MailType.crumb(desk.crumbName), width: rect.width, in: from.window), rect: rect, size: 12)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            landing(flight)
            fly(word, to: target, in: sky, into: view, scale: from.window.backingScaleFactor, held: held ? from.held["list:title"] : nil)
            said = "open: list title only"
            CATransaction.commit()
        } }
    }

    /// Where a row stands in the list's height, 0 at its top and 1 at its
    /// foot: for the list to stand the same way again (esc).
    func spot(of row: String) -> CGFloat? {
        guard let rect = listed["row:" + row], let content = parts["list:content"], let scroll = parts["list:scroll"],
              scroll.height > rect.height else { return nil }
        let y = rect.minY + content.minY - scroll.minY
        return min(max(y / (scroll.height - rect.height), 0), 1)
    }

    /// Parts laid out since the flight was asked for: stale ones are taken
    /// out before the change.
    private func fresh(_ ids: [String]) -> Bool { ids.allSatisfy { parts[$0] != nil || listed[$0] != nil } }

    /// Forget where parts stood before a change, so a flight waits for
    /// the new ones.
    func forget(_ ids: Set<String>) {
        for id in ids {
            parts[id] = nil
            listed[id] = nil
        }
    }

    /// The letter's list name travels back; its contents never join it.
    func takeOffLetter() -> Takeoff? {
        let desk = MailDesk.shared
        guard !MailDesk.still, let pane, let window = pane.window, let open = desk.open,
              let rect = self.window("crumb:name") else { return nil }
        var out = Takeoff(window: window, row: open.id)
        out.words["crumb:name"] = Word(image: picture(MailType.crumb(desk.crumbName), width: rect.width, in: window), rect: rect, size: 12)
        hold(&out)
        return out
    }

    func closeLetter(_ from: Takeoff, title: String, tries: Int = 0) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            guard MailDesk.shared.screen == .list else { return land() }
            guard fresh(["list:title"]), let rect = window("list:title") else {
                return tries < 4 ? closeLetter(from, title: title, tries: tries + 1) : land()
            }
            guard let word = from.words["crumb:name"], let (view, sky, held) = self.sky(for: from) else { return land() }
            let target = Word(image: picture(MailType.title(title), width: rect.width, in: from.window), rect: rect, size: 20)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            landing(flight)
            fly(word, to: target, in: sky, into: view, scale: from.window.backingScaleFactor, held: held ? from.held["crumb:name"] : nil)
            said = "close: list title only"
            CATransaction.commit()
        } }
    }

    // MARK: - Send: the reply folds into it, and it flies to the corner

    /// The reply's picture, or a new mail's, and Send's place, taken as
    /// ⌘↩ is pressed.
    struct Sending {
        let window: NSWindow
        let reply: CGRect
        let send: CGRect
        let picture: CGImage?
    }

    func takeOffSend(from surface: String) -> Sending? {
        guard !MailDesk.still, let pane, let window = pane.window, let reply = self.window(surface), let send = self.window("send"),
              let content = window.contentView?.layer, let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return nil }
        return Sending(window: window, reply: reply, send: send,
                       picture: ChatFlight.picture(of: content, in: root, at: reply, scale: MailMorph.folded))
    }

    /// The scale a surface folding away is drawn at, once, inside its key:
    /// a point to a pixel. Drawn as the screen has it, it took the key 25 to
    /// 45 ms; it is gone in 90, shrinking, before anyone could tell.
    static let folded: CGFloat = 1

    /// The reply, or the new mail, folds into Send; Send, a pill now,
    /// flies to the notice's place and gives way to it, which comes up
    /// there without its own entrance (Toaster.pop, landing).
    func send(_ from: Sending, notice text: String, keys: [String], toaster: Toaster, until: Date? = nil) {
        guard let opened = open(in: from.window) else {
            toaster.pop(text, mark: "paperplane", keys: keys, stay: MailCenter.undoSend, until: until)
            return
        }
        let (view, sky) = opened
        let window = from.window
        let a = view.convert(from.reply, from: nil), b = view.convert(from.send, from: nil)
        var ground = NSColor.white, ink = NSColor.black, line = NSColor.gray
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            ground = Palette.NS.ground.usingColorSpace(.sRGB) ?? .white
            ink = Palette.NS.ink.usingColorSpace(.sRGB) ?? .black
            line = Palette.NS.hairline.usingColorSpace(.sRGB) ?? .gray
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let flightNow = flight
        landing(flightNow)
        // The reply, its words pinned at its top left, shrinking into Send.
        let fold = plate(b, color: ground.cgColor, corner: Radius.control, in: sky)
        fold.borderColor = line.cgColor
        fold.borderWidth = 1
        fold.masksToBounds = true
        let picture = CALayer()
        picture.contents = from.picture
        picture.contentsScale = MailMorph.folded
        picture.anchorPoint = .zero
        picture.frame = CGRect(x: 0, y: b.height - a.height, width: a.width, height: a.height)
        fold.addSublayer(picture)
        let span = 0.19
        let curve = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.25, 1)
        fold.add(MailMorph.ease("position", NSValue(point: a.origin), NSValue(point: b.origin), span, curve: curve), forKey: "position")
        fold.add(MailMorph.ease("bounds.size", NSValue(size: a.size), NSValue(size: b.size), span, curve: curve), forKey: "size")
        fold.add(MailMorph.ease("cornerRadius", Radius.surface, Radius.control, span, curve: curve), forKey: "corner")
        picture.add(MailMorph.ease("position", NSValue(point: .zero), NSValue(point: CGPoint(x: 0, y: b.height - a.height)), span, curve: curve), forKey: "position")
        picture.opacity = 0
        picture.add(MailMorph.ease("opacity", 1, 0, 0.09, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
        fold.opacity = 0
        fold.add(MailMorph.ease("opacity", 1, 0, 0.05, delay: span - 0.03, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
        // Send, a pill of its ink, from where it was to where the notice
        // will stand, as wide as its words.
        let to = noticePlace(text: text, keys: keys, until: until, into: view) ?? b
        let hud = HUD.dark.cgColor
        let pill = plate(to, color: hud, corner: Notice.corner, in: sky)
        let delay = span - 0.04
        pill.add(MailMorph.spring("position", NSValue(point: b.origin), NSValue(point: to.origin), MailMorph.travel, delay: delay), forKey: "position")
        pill.add(MailMorph.spring("bounds.size", NSValue(size: b.size), NSValue(size: to.size), MailMorph.travel, delay: delay), forKey: "size")
        // Send's ink on the way to the notice's own dark (HUD), light in a dark window.
        pill.add(MailMorph.ease("backgroundColor", ink.cgColor, hud, 0.2, delay: delay), forKey: "color")
        pill.opacity = 0
        let shown = CAKeyframeAnimation(keyPath: "opacity")
        shown.values = [0, 1, 1, 0]
        shown.keyTimes = [0, 0.1, 0.78, 1]
        shown.duration = 0.46
        shown.beginTime = CACurrentMediaTime() + (delay - 0.02) * MailMorph.pace
        shown.speed = Float(1 / MailMorph.pace)
        shown.fillMode = .backwards
        pill.add(shown, forKey: "opacity")
        CATransaction.commit()
        // The notice comes up where the pill lands, as it lands.
        // Gone when the send goes, however long the flight took to land.
        let pop = DispatchWorkItem {
            let stay = until.map { max(0.5, $0.timeIntervalSinceNow) } ?? MailCenter.undoSend
            toaster.pop(text, mark: "paperplane", keys: keys, stay: stay, landing: true, until: until)
        }
        popping = pop
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay + 0.3) * MailMorph.pace, execute: pop)
    }

    /// The corner's notice, where it will stand saying these words: its
    /// right edge and top are the corner's, its width its words'.
    private func noticePlace(text: String, keys: [String], until: Date?, into view: NSView) -> CGRect? {
        guard let mark = place(of: notice) else { return nil }
        let m = view.convert(mark, from: nil)
        let span = until.map { Notice.count($0, at: Date()) } ?? 0
        let size = Notice.size(of: Say.toast(text, mark: "paperplane", keys: keys, until: until, span: span))
        return CGRect(x: m.maxX - size.width, y: m.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: - ⌘Z on a send: back out of the corner into its words

    /// The send played backwards: the corner's notice, where it stands,
    /// grows back into the surface it came from (`part`: the reply, or the
    /// new mail's), taking its ground and edge on the way; its words show
    /// under it as it comes to rest. The notice goes as it leaves.
    func unsend(into part: String, toaster: Toaster, tries: Int = 0) {
        let desk = MailDesk.shared
        if tries == 0 {
            // Taken back before it landed: the notice never comes.
            popping?.cancel()
            popping = nil
            guard !MailDesk.still, toaster.shown, toaster.mark == "paperplane", place(of: notice) != nil else { return toaster.dismiss() }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { _ = desk.flying.insert(part) }
            forget([part])
        }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            @MainActor func miss() {
                toaster.dismiss()
                land()
            }
            guard desk.draft != nil, desk.screen == (part == "reply" ? .thread : .compose) else { return miss() }
            guard fresh([part]), let to = self.window(part) else {
                return tries < 4 ? unsend(into: part, toaster: toaster, tries: tries + 1) : miss()
            }
            guard let window = pane?.window, let from = place(of: notice), let opened = self.open(in: window) else { return miss() }
            let (view, sky) = opened
            let a = view.convert(from, from: nil), b = view.convert(to, from: nil)
            // From the notice's own dark (HUD) to the surface's ground.
            let ink = HUD.dark
            var ground = NSColor.white, line = NSColor.gray
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                ground = Palette.NS.ground.usingColorSpace(.sRGB) ?? .white
                line = Palette.NS.hairline.usingColorSpace(.sRGB) ?? .gray
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let flightNow = flight
            landing(flightNow)
            let grow = plate(b, color: ground.cgColor, corner: Radius.surface, in: sky)
            grow.borderColor = line.cgColor
            grow.borderWidth = 1
            grow.add(MailMorph.spring("position", NSValue(point: a.origin), NSValue(point: b.origin), MailMorph.travel), forKey: "position")
            grow.add(MailMorph.spring("bounds.size", NSValue(size: a.size), NSValue(size: b.size), MailMorph.travel), forKey: "size")
            grow.add(MailMorph.ease("cornerRadius", Notice.corner, Radius.surface, 0.2), forKey: "corner")
            grow.add(MailMorph.ease("backgroundColor", ink.cgColor, ground.cgColor, 0.16), forKey: "color")
            grow.add(MailMorph.ease("borderWidth", 0, 1, 0.16), forKey: "border")
            // Gone over the words as they show under it.
            grow.opacity = 0
            grow.add(MailMorph.ease("opacity", 1, 0, 0.1, delay: 0.22, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
            CATransaction.commit()
            // The notice is the plate now.
            toaster.lift()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * MailMorph.pace) { [self] in MainActor.assumeIsolated {
                guard flight == flightNow, desk.flying.contains(part) else { return }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { _ = desk.flying.remove(part) }
            } }
        } }
    }

    // MARK: - a new mail grows out of the pen

    /// The pen's place, taken as C is pressed.
    func takeOffCompose() -> CGRect? {
        guard !MailDesk.still, pane?.window != nil else { return nil }
        return place(of: newMail)
    }

    static let composing: Set<String> = ["compose:surface", "compose:head"]

    /// The new mail's surface grows from the pen to its place, its head
    /// coming out of the pen with it; the real ones show as they land.
    func openCompose(from pen: CGRect, tries: Int = 0) {
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated {
            let desk = MailDesk.shared
            guard desk.screen == .compose, let window = pane?.window else { return land() }
            guard fresh(["compose:surface", "compose:head"]), let surface = self.window("compose:surface"), let head = self.window("compose:head") else {
                return tries < 4 ? openCompose(from: pen, tries: tries + 1) : land()
            }
            guard let opened = self.open(in: window) else { return land() }
            let (view, sky) = opened
            let a = view.convert(pen, from: nil), b = view.convert(surface, from: nil), h = view.convert(head, from: nil)
            var ground = NSColor.white, button = NSColor.gray, line = NSColor.gray
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                ground = Palette.NS.ground.usingColorSpace(.sRGB) ?? .white
                button = Palette.NS.wash.usingColorSpace(.sRGB) ?? .gray
                line = Palette.NS.hairline.usingColorSpace(.sRGB) ?? .gray
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let flightNow = flight
            landing(flightNow)
            let grow = plate(b, color: ground.cgColor, corner: Radius.surface, in: sky)
            grow.borderColor = line.cgColor
            grow.borderWidth = 1
            grow.add(MailMorph.spring("position", NSValue(point: a.origin), NSValue(point: b.origin), MailMorph.travel), forKey: "position")
            grow.add(MailMorph.spring("bounds.size", NSValue(size: a.size), NSValue(size: b.size), MailMorph.travel), forKey: "size")
            grow.add(MailMorph.ease("cornerRadius", Radius.control, Radius.surface, 0.2), forKey: "corner")
            grow.add(MailMorph.ease("backgroundColor", button.cgColor, ground.cgColor, 0.16), forKey: "color")
            // Gone over the new mail as it shows under it, once home: never
            // an empty card waiting for the springs to settle.
            grow.opacity = 0
            grow.add(MailMorph.ease("opacity", 1, 0, 0.1, delay: 0.25, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
            // "New Mail" out of the pen, up to the head's size.
            let image = picture(MailType.newMail(), width: nil, in: window)
            let word = layer(image, at: h, scale: window.backingScaleFactor, in: sky)
            let start = CGPoint(x: a.midX - 6, y: a.midY + 6)
            word.add(MailMorph.spring("position", NSValue(point: start), NSValue(point: CGPoint(x: h.minX, y: h.maxY)), MailMorph.travel, delay: 0.02), forKey: "position")
            word.add(MailMorph.spring("transform.scale", 0.3, 1, MailMorph.travel, delay: 0.02), forKey: "scale")
            word.add(MailMorph.ease("opacity", 0, 1, 0.1, delay: 0.02, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24 * MailMorph.pace) { [self] in MainActor.assumeIsolated {
                guard flight == flightNow else { return }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { desk.flying.subtract(MailMorph.composing) }
            } }
        } }
    }

    /// esc on a new mail: its surface back into the pen, its head with it.
    struct Closing {
        let window: NSWindow
        let surface: CGRect
        let head: CGRect
        let pen: CGRect
        let picture: CGImage?
    }

    func takeOffUncompose() -> Closing? {
        guard !MailDesk.still, let pane, let window = pane.window, let surface = self.window("compose:surface"),
              let head = self.window("compose:head"), let pen = place(of: newMail),
              let content = window.contentView?.layer, let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return nil }
        return Closing(window: window, surface: surface, head: head, pen: pen,
                       picture: ChatFlight.picture(of: content, in: root, at: surface, scale: MailMorph.folded))
    }

    func closeCompose(_ from: Closing) {
        guard let opened = self.open(in: from.window) else { return }
        let (view, sky) = opened
        let window = from.window
        let a = view.convert(from.surface, from: nil), b = view.convert(from.pen, from: nil), h = view.convert(from.head, from: nil)
        var ground = NSColor.white, button = NSColor.gray, line = NSColor.gray
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            ground = Palette.NS.ground.usingColorSpace(.sRGB) ?? .white
            button = Palette.NS.wash.usingColorSpace(.sRGB) ?? .gray
            line = Palette.NS.hairline.usingColorSpace(.sRGB) ?? .gray
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let flightNow = flight
        landing(flightNow)
        let span = 0.26
        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        let fold = plate(b, color: button.cgColor, corner: Radius.control, in: sky)
        fold.borderColor = line.cgColor
        fold.borderWidth = 1
        fold.masksToBounds = true
        let picture = CALayer()
        picture.contents = from.picture
        picture.contentsScale = MailMorph.folded
        picture.anchorPoint = .zero
        picture.frame = CGRect(x: 0, y: b.height - a.height, width: a.width, height: a.height)
        fold.addSublayer(picture)
        fold.add(MailMorph.ease("position", NSValue(point: a.origin), NSValue(point: b.origin), span, curve: curve), forKey: "position")
        fold.add(MailMorph.ease("bounds.size", NSValue(size: a.size), NSValue(size: b.size), span, curve: curve), forKey: "size")
        fold.add(MailMorph.ease("cornerRadius", Radius.surface, Radius.control, span, curve: curve), forKey: "corner")
        fold.add(MailMorph.ease("backgroundColor", ground.cgColor, button.cgColor, span, curve: curve), forKey: "color")
        picture.add(MailMorph.ease("position", NSValue(point: .zero), NSValue(point: CGPoint(x: 0, y: b.height - a.height)), span, curve: curve), forKey: "position")
        picture.opacity = 0
        picture.add(MailMorph.ease("opacity", 1, 0, 0.09, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
        fold.opacity = 0
        fold.add(MailMorph.ease("opacity", 1, 0, 0.06, delay: span - 0.06, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
        let image = self.picture(MailType.newMail(), width: nil, in: window)
        let word = layer(image, at: h, scale: window.backingScaleFactor, in: sky)
        let end = CGPoint(x: b.midX - 6, y: b.midY + 6)
        word.position = end
        word.transform = CATransform3DMakeScale(0.3, 0.3, 1)
        word.opacity = 0
        word.add(MailMorph.ease("position", NSValue(point: CGPoint(x: h.minX, y: h.maxY)), NSValue(point: end), 0.24, curve: curve), forKey: "position")
        word.add(MailMorph.ease("transform.scale", 1, 0.3, 0.24, curve: curve), forKey: "scale")
        word.add(MailMorph.ease("opacity", 1, 0, 0.2, delay: 0.04, curve: CAMediaTimingFunction(name: .linear)), forKey: "opacity")
        CATransaction.commit()
    }
}

/// The layer flights fly on: over everything, taking no clicks.
final class MailSky: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Whether mail holds still (MailDesk.still), for a view: Reduce Motion
/// and Settings › Mail's Animations read as the view's own, so it draws
/// again the moment either turns, and a transition it hands a row or a
/// screen is never one picked before the turn.
@propertyWrapper
struct MailStill: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @AppStorage("mail.motion", store: Store.settings) private var animations = true

    var wrappedValue: Bool { MailDesk.still(reduce: reduce, animations: animations) }
}

/// Whether nothing of mail moves or fades at all (MailDesk.instant): Settings
/// › Mail's Animations off. Reduce Motion alone keeps a fade where a move was.
@propertyWrapper
struct MailInstant: DynamicProperty {
    @AppStorage("mail.motion", store: Store.settings) private var animations = true

    var wrappedValue: Bool { !animations }
}

/// A view's place in the window, kept for a flight: the pane itself, the
/// pen by the lights, the corner's notice.
struct MailPlace: NSViewRepresentable {
    enum Kind { case pane, newMail, notice }
    let kind: Kind

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) {
        switch kind {
        case .pane: MailMorph.shared.pane = view
        case .newMail: MailMorph.shared.newMail = view
        case .notice: MailMorph.shared.notice = view
        }
    }

    final class MarkView: NSView {
        /// The pane's own points run down, as SwiftUI's do.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
