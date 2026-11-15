import AppKit
import SwiftUI

/// A tab that starts to play out of sight sings once: two or three notes
/// up out of its speaker, or out of a pin's corner, over about a second,
/// and then it is quiet again.
///
/// Sound on a tab can go on for hours, and the tabs are looked at all day,
/// so the speaker itself stays still. Three moving bars stood there once
/// and went for being noise. What the notes answer is the one moment
/// someone asks where that sound is coming from: a tab you aren't on
/// beginning to play. So not for:
/// - a tab on screen, whose sound comes from where you are looking;
/// - anything shorter than `hold`, a message's ping, or every ping would sing;
/// - sound back within `rest` of stopping, the same song after a pause;
/// - a muted tab, an agent's (its face has the tab's end), Reduce Motion,
///   a window nobody can see, a tab whose row is out of sight.
///
/// Silenced mid-song, the notes go in a tenth of a second: the slashed
/// speaker is there at once, and nothing goes on singing over it. Let back
/// in while the page still plays, one note, since that is where you are
/// looking and what you just asked for.
@MainActor
final class Chorus {
    weak var sky: ChorusView?
    /// When each tab last went quiet.
    private var quiet: [Tab.ID: Date] = [:]
    /// What each tab was doing when last heard from.
    private var playing: [Tab.ID: Bool] = [:]
    private var muted: [Tab.ID: Bool] = [:]
    /// A tab that has just started, waiting out `hold`.
    private var waits: [Tab.ID: DispatchWorkItem] = [:]
    /// Two tabs starting together sing a fifth of a second apart, as the
    /// buttons at the end of the row take turns hopping (Hop): at once they
    /// read as one twitch.
    private var turn: Date = .distantPast
    /// Songs begun, and why the last one that wasn't wasn't, for the bench.
    private(set) var sung = 0
    /// The last song's main-thread time, in ms, and the instructions the
    /// process retired while it was made and handed over, in millions.
    private(set) var cost: (ms: Double, instructions: Double) = (0, 0)
    private(set) var unsung = ""

    private func untold(_ why: String) { unsung = why }

    /// What the strip or the column is wearing, as they last said (ChorusInk).
    var tone: Tone?

    static let hold: TimeInterval = 0.6
    static let rest: TimeInterval = 60

    func heard(_ tab: Tab, in browser: Browser) {
        let id = tab.id
        let wasMuted = muted[id] ?? false
        let wasPlaying = playing[id] ?? false
        muted[id] = tab.muted
        playing[id] = tab.noisy

        if tab.muted != wasMuted {
            if tab.muted {
                sky?.hush(id)
            } else if tab.noisy {
                sing(tab, notes: 1, in: browser)
            }
        }
        guard tab.noisy != wasPlaying else { return }
        guard tab.noisy else {
            quiet[id] = Date()
            waits.removeValue(forKey: id)?.cancel()
            return
        }
        let rested = quiet[id].map { Date().timeIntervalSince($0) >= Self.rest } ?? true
        guard rested else { return }
        let wait = DispatchWorkItem { [weak self, weak tab, weak browser] in
            guard let self, let tab, let browser else { return }
            waits[id] = nil
            guard tab.noisy, !tab.muted, !browser.onScreen(id) else { return }
            sing(tab, notes: 3, in: browser)
        }
        waits.removeValue(forKey: id)?.cancel()
        waits[id] = wait
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: wait)
    }

    /// For the bench: the tab has never been heard, so its next sound sings.
    func forget(_ id: Tab.ID) {
        quiet[id] = nil
        playing[id] = nil
        muted[id] = nil
        waits.removeValue(forKey: id)?.cancel()
    }

    private func sing(_ tab: Tab, notes: Int, in browser: Browser) {
        guard let sky, let window = sky.window else { return untold("no sky") }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return untold("reduce motion") }
        guard window.occlusionState.contains(.visible), !window.isMiniaturized else { return untold("window unseen") }
        guard tab.worker == nil else { return untold("agent") }
        guard let frame = browser.keySky.place(tab.id), frame.width > 0 else { return untold("no frame") }
        guard let from = source(frame, pinned: tab.pin != nil, in: browser, sky: sky) else { return untold("row unseen") }
        // In the ink the speaker is in, on whatever the tabs are wearing.
        let look = tone.flatMap { NSAppearance(named: $0.scheme == .dark ? .darkAqua : .aqua) }
        let ink = tone == nil ? Palette.NS.muted : Palette.NS.ink.withAlphaComponent(0.72)
        let wait = max(0, turn.timeIntervalSinceNow)
        turn = Date().addingTimeInterval(wait + 0.2)
        sung += 1
        let id = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak sky, weak tab] in
            guard let sky, let tab, tab.noisy, !tab.muted else { return }
            let cpu = Bench.mainCPU(), work = Bench.instructions()
            sky.sing(id, from: from, notes: notes, ink: ink, look: look ?? sky.effectiveAppearance)
            self?.cost = (Bench.mainCPU() - cpu, Bench.instructions() - work)
        }
    }

    /// Where the notes leave from, in the window's SwiftUI space: the
    /// speaker at a tab's end, 7 in from it and 15 across, or a pin's mark,
    /// off its top right shoulder, a pin having no speaker of its own and
    /// being as wide as the column when it is the only one. Nil for a tab
    /// that can't be seen: past the window's edge, or down a column that
    /// is shut.
    private func source(_ frame: CGRect, pinned: Bool, in browser: Browser, sky: ChorusView) -> CGPoint? {
        let at = pinned ? CGPoint(x: frame.midX + 9, y: frame.midY - 5) : CGPoint(x: frame.maxX - 14.5, y: frame.midY)
        guard sky.bounds.insetBy(dx: 2, dy: 2).contains(at) else { return nil }
        if browser.prefs.sidebar, frame.minX < browser.sideShown {
            guard at.x <= browser.sideShown else { return nil }
        }
        return at
    }
}

/// Tells the chorus what the tabs around it are wearing, from inside the
/// strip or the column, where the tone is: a view of its own, so only it is
/// drawn again when the tone changes.
struct ChorusInk: View {
    let chorus: Chorus
    @Environment(\.tone) private var tone

    var body: some View {
        Color.clear.onChange(of: tone, initial: true) { _, tone in chorus.tone = tone }
    }
}

// MARK: - the notes

/// Over the whole window, like the downloads' sky, so a note can leave its
/// row and cross the one above it. Each note is a layer with one group of
/// animations handed to the render server: nothing on the main thread moves
/// while it flies, and the layer goes when it lands.
struct ChorusSky: NSViewRepresentable {
    let chorus: Chorus

    func makeNSView(context: Context) -> ChorusView {
        let view = ChorusView()
        chorus.sky = view
        return view
    }

    func updateNSView(_ view: ChorusView, context: Context) {
        chorus.sky = view
    }
}

/// One song's notes, for the block that takes them down when they land.
private final class Song {
    var notes: [CALayer] = []
}

final class ChorusView: NSView {
    /// The notes of each tab still in the air, to be hushed.
    private var flying: [Tab.ID: [CALayer]] = [:]
    var inFlight: Int { flying.values.reduce(0) { $0 + $1.count } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// From the top left, as SwiftUI's window space is.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Each note: up 15 to 24 points and a few to the side, swaying back
    /// once on the way, turning a little, full size in its first fifth and
    /// gone by the end, 0.9 s on a curve that is quick off the mark and
    /// slow at the top. The second and third leave 0.12 s after the one
    /// before, a single and a pair of notes taking turns.
    func sing(_ id: Tab.ID, from spot: CGPoint, notes: Int, ink: NSColor, look: NSAppearance) {
        guard let host = layer else { return }
        let from = place(spot)
        let scale = window?.backingScaleFactor ?? 2
        let sways: [CGFloat] = [4, -5, 7]
        let rises: [CGFloat] = [18, 24, 15]
        // Never higher than the window: a tab along the top has little room
        // over it, and a note cut off by the edge is worse than a short one.
        let room = max(8, from.y - 2)
        let start = CACurrentMediaTime()
        var made: [CALayer] = []

        // The block is for the animations added after it, so it goes first,
        // and gets the notes by reference: they are made below.
        let song = Song()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.land(id, song.notes) }
        for index in 0..<min(notes, 3) {
            let name = index % 2 == 0 ? "music.note" : "music.note.2"
            let size: CGFloat = index % 2 == 0 ? 7.5 : 8
            guard let (image, side) = Self.note(name, size: size, ink: ink, look: look, scale: scale) else { continue }
            let note = CALayer()
            note.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            note.contents = image
            note.contentsScale = scale
            // The glyph keeps clear of its square's edges, so turning it has
            // no edge to smooth: that pass would be work for nothing.
            note.allowsEdgeAntialiasing = false
            note.position = from
            note.opacity = 0
            host.addSublayer(note)
            made.append(note)

            let sway = sways[index], rise = min(rises[index], room)
            let turn: CGFloat = sway > 0 ? 1 : -1
            let times: [NSNumber] = [0, 0.18, 0.6, 1]
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [
                CGPoint(x: from.x, y: from.y + 2),
                CGPoint(x: from.x + sway * 0.3, y: from.y - rise * 0.3),
                CGPoint(x: from.x - sway * 0.35, y: from.y - rise * 0.7),
                CGPoint(x: from.x + sway, y: from.y - rise),
            ].map { NSValue(point: $0) }
            let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            spin.values = [-8, 0, 5 * turn, 12 * turn].map { $0 * .pi / 180 }
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.55, 1, 1, 0.9]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0.85, 0]
            let parts = [path, spin, grow, fade]
            for part in parts {
                part.keyTimes = times
                part.duration = 0.9
            }
            let flight = CAAnimationGroup()
            flight.animations = parts
            flight.duration = 0.9
            flight.beginTime = start + Double(index) * 0.12
            flight.fillMode = .backwards
            flight.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
            flight.isRemovedOnCompletion = true
            note.add(flight, forKey: "flight")
        }
        song.notes = made
        CATransaction.commit()
        flying[id, default: []] += made
    }

    /// A note drawn once for each ink and each screen's scale and kept:
    /// a song then only hands over layers, where drawing its three from
    /// their SVGs every time was most of its time on the main thread.
    private static var notes: [String: CGImage] = [:]

    private static func note(_ name: String, size: CGFloat, ink: NSColor, look: NSAppearance, scale: CGFloat) -> (CGImage, CGFloat)? {
        let side = (size * Glyphs.scale).rounded()
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        look.performAsCurrentDrawingAppearance {
            (ink.usingColorSpace(.sRGB) ?? ink).getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        let rgba = [r, g, b, a]
        let key = "\(name) \(side) \(scale) " + rgba.map { String(Int($0 * 255)) }.joined(separator: " ")
        if let kept = notes[key] { return (kept, side) }
        guard let shape = Glyphs.art(name) else { return nil }
        // In the ink as it is, see-through where the speaker's is: filling
        // over the black artwork would darken a half-clear ink with it.
        let fill = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        let art = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            shape.draw(in: rect)
            fill.set()
            rect.fill(using: .sourceIn)
            return true
        }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = art.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) else { return nil }
        if notes.count > 16 { notes.removeAll() }
        notes[key] = image
        return (image, side)
    }

    /// The tab was silenced: whatever of its song is still in the air
    /// fades where it is, in a tenth of a second.
    func hush(_ id: Tab.ID) {
        guard let notes = flying.removeValue(forKey: id), !notes.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { notes.forEach { $0.removeFromSuperlayer() } }
        for note in notes {
            let now = note.presentation()
            note.position = now?.position ?? note.position
            note.transform = now?.transform ?? note.transform
            let shown = now?.opacity ?? 0
            note.removeAllAnimations()
            note.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shown
            fade.toValue = 0
            fade.duration = 0.1
            note.add(fade, forKey: "hush")
        }
        CATransaction.commit()
    }

    private func land(_ id: Tab.ID, _ notes: [CALayer]) {
        notes.forEach { $0.removeFromSuperlayer() }
        guard var left = flying[id] else { return }
        left.removeAll { note in notes.contains { $0 === note } }
        flying[id] = left.isEmpty ? nil : left
    }

    /// A point of SwiftUI's window space, from the content view's top left,
    /// in this view.
    private func place(_ point: CGPoint) -> CGPoint {
        guard let content = window?.contentView else { return point }
        let there = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
        return convert(there, from: content)
    }
}
