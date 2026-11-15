import AppKit

// What a call says beyond its people, for its floating window: who waits
// to come in, whether it is recorded, your hand, the captions, the chat
// (docs/call-window.md, "Beyond the people"). Read from the page by
// CallStage with every look; the people's own news (a message, a hand, a
// reaction) is drawn on them by the stage itself.

/// One read of the call's news.
struct CallNews: Equatable {
    struct Person: Equatable {
        var name: String
        /// The page's picture of them, when it has one.
        var face: URL?
    }

    /// Asking to come in, the first to ask first.
    var waiting: [Person] = []
    /// Messages come since the chat was last opened from the window.
    var unread = 0
    var recording = false
    var myHand = false
    var captions = false
    /// What the page has a button for: what the window's second row offers.
    var canHand = false
    var canCaptions = false
    var canReact = false
    var canChat = false
    /// What happened to someone since the last read, for a tucked window's
    /// edge (Floater.edge); the window itself draws them on the people.
    enum Event: Equatable {
        case message(name: String, words: String, face: URL?)
        case hand(name: String, face: URL?)
        case react(name: String, emoji: String)
    }
    var events: [Event] = []
    /// Someone talking now, someone's hand up: light along a tucked tab.
    var talking = false
    var handsUp = false

    init() {}

    init(_ answer: Any?) {
        guard let read = answer as? [String: Any] else { return }
        waiting = (read["waiting"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return Person(name: name, face: (row["face"] as? String).flatMap(URL.init(string:)))
        }
        unread = (read["unread"] as? NSNumber)?.intValue ?? 0
        recording = read["recording"] as? Bool ?? false
        myHand = read["hand"] as? Bool ?? false
        captions = read["captions"] as? Bool ?? false
        canHand = read["canHand"] as? Bool ?? false
        canCaptions = read["canCaptions"] as? Bool ?? false
        canReact = read["canReact"] as? Bool ?? false
        canChat = read["canChat"] as? Bool ?? false
        talking = read["talking"] as? Bool ?? false
        handsUp = read["handsUp"] as? Bool ?? false
        events = (read["events"] as? [[String: Any]] ?? []).compactMap { row in
            let name = row["name"] as? String ?? ""
            let face = (row["face"] as? String).flatMap(URL.init(string:))
            switch row["kind"] as? String {
            case "message": return .message(name: name, words: row["text"] as? String ?? "", face: face)
            case "hand": return .hand(name: name, face: face)
            case "react": return .react(name: name, emoji: row["emoji"] as? String ?? "")
            default: return nil
            }
        }
    }

    /// The second row has something in it.
    var hasMore: Bool { canHand || canCaptions || canReact || canChat }
}

/// What the window asks of the page (Calls.swift carries it to CallStage).
enum CallAsk: Equatable {
    /// Someone let in, or everyone waiting when nil.
    case admit(String?)
    /// Someone turned away, or everyone waiting when nil.
    case deny(String?)
    case hand
    case captions
    case react(String)
    case send(String)
    /// The chat read, from the window: the count starts again.
    case read
    /// A click on the stage, in the window's points from its top left: a
    /// message there opens the field to answer it.
    case tap(NSPoint)
    /// Where the window's own things stand over the stage, so the people's
    /// news keeps clear of them: the island, in points from the window's
    /// top left (zero when there is none), and how much of the foot the
    /// marks in the bottom left corner take while the buttons are away.
    case overlay(island: NSRect, marks: CGFloat)
    /// The field open (true) or put away: the last messages stand over it
    /// and the people under them blur.
    case thread(Bool)
}

/// A spring as the call window's motion has it (the ideas'
/// `sp`), in closed form: how far along a value is, `t` seconds after it
/// set off from 0 toward 1. Under 1 damping, it passes 1 a little and
/// comes back.
struct CallSpring {
    var response: Double = 0.38
    var damping: Double = 0.78

    func at(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response, zeta = min(damping, 0.999)
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
    }

    /// When it is still for the eye: within a thousandth.
    var settles: Double { 6.9 / (2 * Double.pi / response * min(damping, 0.999)) }
}

/// The island along the top: what concerns the whole call. "● Rec" while
/// it is recorded, first said in full ("This call is being recorded",
/// "Recording", then the letters R, e, c stay as the rest fade). Someone
/// asking to come in grows it out of nothing, or out of Rec, as their face
/// and name, and it opens down into a card with Deny and Admit (several:
/// View and Admit All; View a list with Admit by each, Deny All and Admit
/// All under it), for six seconds, then a line that stays until it is
/// answered; the pointer on it opens it again. Answered, it draws in to the
/// face (the stage flies the face to its seat) and goes, or back to Rec.
/// One surface on one spring: the card, the line, the list and Rec are the
/// island at other sizes, its corners half its height up to the window's
/// 20. In a narrow window the card has only Admit; a right-click on the
/// island has Deny.
final class CallIsland: NSView {
    var onAsk: ((CallAsk) -> Void)?
    /// The island's size changed: the window lays it out again.
    var onResize: (() -> Void)?
    /// The most height it may take, so the list stops clear of the row.
    var room: CGFloat = 132

    enum Shape: Equatable { case none, rec, card, line, list }
    private(set) var shape = Shape.none
    /// What it shows at this moment, which may be on the way to its shape:
    /// a line before a card, a face on the way out, Rec in words first.
    private enum Look: Equatable {
        case none, face, line, card, list
        case rec(Words)
    }
    private enum Words { case phrase, recording, rec }
    private var look = Look.none
    private var news = CallNews()
    private var narrow = false

    /// The island's dark glass, the design's rgba(24, 24, 28, .86).
    static let ink = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 28 / 255, alpha: 0.86)
    private let plate = FloatGlass.media(cornerRadius: 12) // design: min(height / 2, the window's corner), set as it moves
    /// What it says, laid out at the size it is heading to and pinned to
    /// the top, so the plate opens down over it.
    private let sheet = NSView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    /// The rest of "Recording" after its R, e and c: what fades.
    private let tail = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private var faces: [NSImageView] = []
    private let left = NSButton()
    private let right = NSButton()
    private var rows: [(face: NSImageView, name: NSTextField, admit: NSButton)] = []
    private var settle: Timer?
    private var hovered = false
    /// Names already shown as a card: a new one opens it again.
    private var seen: Set<String> = []
    /// The one asking last shown, for the face it draws in to once answered.
    private var lastWaiting: CallNews.Person?
    /// Rec said in full once a recording: a window floated again during it
    /// says only Rec.
    private static var toldRecording = false

    /// The size it shows, on its way from `from` to `to`.
    private var shown = NSSize.zero
    private var from = NSSize.zero
    private var to = NSSize.zero
    private var began: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var steps: [DispatchWorkItem] = []
    private let spring = CallSpring()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(plate)
        // The design's dark glass: the material's blur under a fill of the
        // island's own ink, not a tint the glass may lighten.
        plate.content.wantsLayer = true
        plate.content.layer?.masksToBounds = true
        plate.content.layer?.backgroundColor = CallIsland.ink.cgColor
        plate.content.addSubview(sheet)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1).cgColor
        dot.layer?.cornerRadius = 3
        for label in [title, tail, subtitle] {
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            sheet.addSubview(label)
        }
        tail.lineBreakMode = .byClipping
        subtitle.textColor = NSColor(white: 1, alpha: 0.6)
        subtitle.font = .systemFont(ofSize: 11)
        sheet.addSubview(dot)
        for (button, main) in [(left, false), (right, true)] {
            CallIsland.pill(button, main: main)
            button.target = self
            button.action = #selector(pressed(_:))
            sheet.addSubview(button)
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if shape == .line { reshape(.card) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if shape == .card, !news.waiting.isEmpty { wait() }
    }

    /// A pill button, as the window's notes have them: white for the one
    /// that says yes. Its corners are half its height, set as it is placed.
    static func pill(_ button: NSButton, main: Bool) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.layer?.backgroundColor = (main ? NSColor(white: 1, alpha: 0.96) : NSColor(white: 1, alpha: 0.16)).cgColor
        button.contentTintColor = main ? NSColor(white: 0.07, alpha: 1) : .white
    }

    static func titled(_ button: NSButton, _ words: String, main: Bool) {
        button.attributedTitle = NSAttributedString(string: words, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: main ? NSColor(white: 0.07, alpha: 1) : NSColor.white,
        ])
        button.setAccessibilityLabel(words)
    }

    private static func put(_ button: NSButton, _ frame: NSRect) {
        button.frame = frame
        button.layer?.cornerRadius = frame.height / 2
    }

    /// The buttons a click may reach, for the window's hit test.
    var pressable: [NSView] { isHidden ? [] : [left, right] + rows.map(\.admit) }

    /// The news, as read: the island takes the shape it calls for.
    func show(_ news: CallNews, narrow: Bool) {
        let names = Set(news.waiting.map(\.name))
        let fresh = !names.subtracting(seen).isEmpty
        seen = names
        let changed = news != self.news || narrow != self.narrow
        self.news = news
        self.narrow = narrow
        if let first = news.waiting.first { lastWaiting = first }
        if !news.recording { CallIsland.toldRecording = false }
        if news.waiting.isEmpty {
            settle?.invalidate()
            reshape(news.recording ? .rec : .none)
        } else if fresh || shape == .none || shape == .rec {
            reshape(.card)
            wait()
        } else if changed {
            refill()
        }
    }

    /// Six seconds as a card, unless the pointer is on it; then a line.
    private func wait() {
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovered, self.shape == .card else { return }
                self.reshape(.line)
            }
        }
    }

    /// Moving, or set at once: Reduce Motion, or no window on the screen.
    private var moves: Bool {
        window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func reshape(_ to: Shape) {
        let was = shape
        guard to != was else { return refill() }
        shape = to
        steps.forEach { $0.cancel() }
        steps = []
        let final: Look = to == .none ? .none : to == .rec ? .rec(.rec) : to == .card ? .card : to == .line ? .line : .list
        defer { onResize?() }
        guard moves else {
            look = final
            fill()
            jump(to: lookSize(final))
            isHidden = final == .none
            return
        }
        let asking: Set<Shape> = [.card, .line, .list]
        if (was == .none || was == .rec), to == .card {
            // Out of nothing, or out of Rec: the face and the name first,
            // then down into the card.
            if was == .none { shown = NSSize(width: 28, height: 28) }
            go(.line)
            later(0.42) { if $0.shape == .card { $0.go(.card) } }
        } else if asking.contains(was), !asking.contains(to) {
            // Answered: in to the face, which the stage flies to its seat;
            // then gone, or Rec again.
            go(.face)
            later(0.34) { island in
                guard !asking.contains(island.shape) else { return }
                if island.shape == .rec { island.go(.rec(.rec)) } else { island.vanish() }
            }
        } else if was == .none, to == .rec, !CallIsland.toldRecording {
            // Said loud first, then small for the rest of the call.
            CallIsland.toldRecording = true
            shown = NSSize(width: 24, height: 24)
            go(.rec(.phrase))
            later(1.9) { if $0.shape == .rec { $0.go(.rec(.recording)) } }
            later(2.7) { if $0.shape == .rec { $0.go(.rec(.rec)) } }
        } else if to == .none {
            vanish()
        } else {
            if was == .none { shown = NSSize(width: 24, height: 24) }
            go(final)
        }
    }

    private func later(_ seconds: TimeInterval, _ act: @escaping (CallIsland) -> Void) {
        let step = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self { act(self) } }
        }
        steps.append(step)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: step)
    }

    /// Into a look on the spring: the words for it come in as it moves,
    /// but for Recording becoming Rec, whose letters stay.
    private func go(_ next: Look) {
        let was = look
        look = next
        isHidden = false
        alphaValue = 1
        if was == .rec(.recording), next == .rec(.rec) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                tail.animator().alphaValue = 0
            }
            move(to: lookSize(next))
            return
        }
        fill()
        sheet.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = markCurve
            sheet.animator().alphaValue = 1
        }
        move(to: lookSize(next))
    }

    /// Answered, with nothing else to say: a quick fade where it is.
    private func vanish() {
        look = .none
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shape == .none else { return }
                self.isHidden = true
                self.alphaValue = 1
                self.jump(to: .zero)
            }
        }
    }

    private func jump(to size: NSSize) {
        link?.invalidate()
        link = nil
        from = size
        to = size
        shown = size
        place()
    }

    private func move(to size: NSSize) {
        guard moves else { return jump(to: size) }
        from = shown == .zero ? size : shown
        to = size
        began = CACurrentMediaTime()
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        place()
    }

    @objc private func step() {
        let t = CACurrentMediaTime() - began
        guard t < spring.settles else {
            jump(to: to)
            return
        }
        let k = CGFloat(spring.at(t))
        shown = NSSize(width: from.width + (to.width - from.width) * k, height: max(1, from.height + (to.height - from.height) * k))
        place()
    }

    /// Where it stands in the window: along the top, 8 down, in the middle,
    /// at the size it shows now; the words pinned to its top.
    func place() {
        guard let host = superview else { return }
        let size = shown
        frame = NSRect(x: ((host.bounds.width - size.width) / 2).rounded(), y: host.bounds.height - 8 - size.height,
                       width: size.width, height: size.height)
        plate.frame = bounds
        let round = min(size.height / 2, Floater.corner)
        plate.cornerRadius = round
        plate.content.layer?.cornerRadius = round
        // Rec keeps its dot and its R, e, c where they are as it draws in;
        // the rest open from the middle.
        let rec: Bool
        if case .rec = look { rec = true } else { rec = false }
        sheet.setFrameOrigin(NSPoint(x: rec ? 0 : ((size.width - sheet.frame.width) / 2).rounded(), y: size.height - sheet.frame.height))
    }

    /// Its size for a window this wide, in the shape it has (not the one it
    /// shows on the way there).
    func size(in width: CGFloat) -> NSSize {
        switch shape {
        case .none: return .zero
        case .rec: return lookSize(.rec(.rec), in: width)
        case .card: return lookSize(.card, in: width)
        case .line: return lookSize(.line, in: width)
        case .list: return lookSize(.list, in: width)
        }
    }

    private func lookSize(_ look: Look, in width: CGFloat? = nil) -> NSSize {
        let width = width ?? superview?.bounds.width ?? 352
        let wide = min(width - 76, narrow ? 224 : 250)
        switch look {
        case .none: return .zero
        case .face: return NSSize(width: 30, height: 30)
        case .rec(.rec): return NSSize(width: 54, height: 24)
        case .rec(.recording): return NSSize(width: 21 + ceil(CallIsland.recWidth("Recording")) + 10, height: 24)
        case .rec(.phrase): return NSSize(width: min(width - 76, 21 + ceil(CallIsland.recWidth(CallIsland.phrase)) + 10), height: 24)
        case .line:
            let words = lineWords.size()
            return NSSize(width: min(wide, narrow ? 200 : 214, 30 + ceil(words.width) + 10 + (news.recording ? 12 : 0)), height: 28)
        case .card: return NSSize(width: wide, height: 84)
        case .list: return NSSize(width: wide, height: 54 + CGFloat(listRows) * 26)
        }
    }

    static let phrase = "This call is being recorded"
    /// One line, cut short with an ellipsis.
    private static let oneLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let recFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static func recWidth(_ words: String) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: recFont]).width
    }

    /// Rows the list has room for: four at most, stopping clear of the row.
    private var listRows: Int {
        max(1, min(news.waiting.count, 4, Int((room - 54) / 26)))
    }

    /// "Alex Morgan wants to join", the name bold.
    private var lineWords: NSAttributedString {
        guard let first = news.waiting.first ?? lastWaiting else { return NSAttributedString() }
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
                                                   .paragraphStyle: CallIsland.oneLine]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white,
                                                    .paragraphStyle: CallIsland.oneLine]
        if news.waiting.count > 1 { return NSAttributedString(string: "\(news.waiting.count) want to join", attributes: bold) }
        let words = NSMutableAttributedString(string: first.name, attributes: bold)
        if !narrow { words.append(NSAttributedString(string: " wants to join", attributes: plain)) }
        return words
    }

    private var many: Bool { news.waiting.count > 1 }

    /// The words of the shape it has, again: the news changed under it.
    private func refill() {
        guard look != .none, look == lookFor(shape) else { return }
        look = lookFor(shape)
        fill()
        move(to: lookSize(look))
        onResize?()
    }

    private func lookFor(_ shape: Shape) -> Look {
        switch shape {
        case .none: return .none
        case .rec: return .rec(.rec)
        case .card: return .card
        case .line: return .line
        case .list: return .list
        }
    }

    /// What the look shows, laid out at its size, from the top down.
    private func fill() {
        let size = lookSize(look)
        sheet.frame.size = size
        faces.forEach { $0.removeFromSuperview() }
        faces = []
        rows.forEach { $0.name.removeFromSuperview(); $0.admit.removeFromSuperview() }
        rows = []
        let first = news.waiting.first ?? lastWaiting
        let top = size.height
        dot.isHidden = !news.recording
        left.isHidden = true
        right.isHidden = true
        subtitle.isHidden = true
        title.isHidden = false
        tail.isHidden = true
        title.textColor = .white
        switch look {
        case .none:
            title.isHidden = true
        case .face:
            title.isHidden = true
            dot.isHidden = true
            if let first { face(first, side: 30, at: .zero) }
        case .rec(let words):
            // The dot 10 in, the words 5 after it, 10 clear at the end.
            dot.frame = NSRect(x: 10, y: 9, width: 6, height: 6)
            dot.isHidden = false
            title.font = CallIsland.recFont
            title.stringValue = words == .phrase ? CallIsland.phrase : "Rec"
            title.frame = NSRect(x: 19, y: 4, width: size.width - 21, height: 16)
            if words != .phrase {
                tail.isHidden = false
                tail.alphaValue = words == .recording ? 1 : 0
                tail.font = CallIsland.recFont
                tail.stringValue = "ording"
                // A label draws 2 in from each side of its frame.
                title.frame = NSRect(x: 19, y: 4, width: ceil(CallIsland.recWidth("Rec")) + 5, height: 16)
                tail.frame = NSRect(x: 19 + CallIsland.recWidth("Rec"), y: 4, width: ceil(CallIsland.recWidth("ording")) + 5, height: 16)
            }
        case .line:
            // Labels draw 2 in from their frames: the words start 6 after
            // the face, as the design has them.
            if let first { face(first, side: 20, at: NSPoint(x: 4, y: 4)) }
            title.attributedStringValue = lineWords
            title.frame = NSRect(x: 28, y: 6, width: size.width - 36 - (news.recording ? 12 : 0), height: 16)
            dot.frame = NSRect(x: size.width - 16, y: 11, width: 6, height: 6)
        case .card:
            // From the top, 10 down: faces, the name and what they want 9
            // after; the buttons 10 in from the sides and 12 up.
            if many {
                for (index, person) in news.waiting.prefix(3).enumerated() {
                    face(person, side: 26, at: NSPoint(x: 12 + CGFloat(index) * 18, y: top - 10 - 28))
                }
            } else if let first {
                face(first, side: 30, at: NSPoint(x: 12, y: top - 10 - 30))
            }
            let textX: CGFloat = many ? 12 + CGFloat(min(news.waiting.count, 3) - 1) * 18 + 26 + 9 : 51
            let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white,
                                                       .paragraphStyle: CallIsland.oneLine]
            let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.white,
                                                        .paragraphStyle: CallIsland.oneLine]
            let name = NSMutableAttributedString(string: first?.name ?? "", attributes: bold)
            if many {
                let others = news.waiting.count - 1
                name.append(NSAttributedString(string: " and \(others) other\(others > 1 ? "s" : "")", attributes: plain))
            }
            title.attributedStringValue = name
            title.frame = NSRect(x: textX - 2, y: top - 25, width: size.width - textX - (news.recording ? 20 : 8), height: 16)
            subtitle.isHidden = false
            subtitle.stringValue = many ? "want to join" : "wants to join"
            subtitle.frame = NSRect(x: textX - 2, y: top - 40, width: size.width - textX - 8, height: 14)
            dot.frame = NSRect(x: size.width - 18, y: top - 12 - 6, width: 6, height: 6)
            let both = !narrow
            let half = both ? ((size.width - 20 - 6) / 2).rounded(.down) : size.width - 20
            if both {
                left.isHidden = false
                CallIsland.titled(left, many ? "View" : "Deny", main: false)
                CallIsland.put(left, NSRect(x: 10, y: 12, width: half, height: 22))
            }
            right.isHidden = false
            CallIsland.titled(right, many ? "Admit All" : "Admit", main: true)
            CallIsland.put(right, NSRect(x: both ? 10 + half + 6 : 10, y: 12, width: half, height: 22))
        case .list:
            // A head 24 tall, a row of 26 for each (the face 22, Admit 20,
            // 10 in from the right), and Deny All and Admit All 8 up.
            title.font = .systemFont(ofSize: 11)
            title.textColor = NSColor(white: 1, alpha: 0.6)
            title.stringValue = "\(news.waiting.count) want to join"
            title.frame = NSRect(x: 10, y: top - 8 - 14, width: size.width - 32, height: 14)
            dot.frame = NSRect(x: size.width - 18, y: top - 15 - 3, width: 6, height: 6)
            for (index, person) in news.waiting.prefix(listRows).enumerated() {
                let y = top - 24 - CGFloat(index + 1) * 26
                let image = face(person, side: 22, at: NSPoint(x: 12, y: y + 2))
                let name = NSTextField(labelWithString: person.name)
                name.font = .systemFont(ofSize: 12)
                name.textColor = .white
                name.lineBreakMode = .byTruncatingTail
                name.frame = NSRect(x: 40, y: y + 5, width: size.width - 40 - 10 - 56 - 6, height: 16)
                sheet.addSubview(name)
                let admit = NSButton()
                CallIsland.pill(admit, main: false)
                CallIsland.titled(admit, "Admit", main: false)
                CallIsland.put(admit, NSRect(x: size.width - 10 - 56, y: y + 3, width: 56, height: 20))
                admit.target = self
                admit.action = #selector(admitOne(_:))
                admit.identifier = NSUserInterfaceItemIdentifier(person.name)
                sheet.addSubview(admit)
                rows.append((image, name, admit))
            }
            let half = ((size.width - 20 - 6) / 2).rounded(.down)
            left.isHidden = false
            CallIsland.titled(left, "Deny All", main: false)
            CallIsland.put(left, NSRect(x: 10, y: 8, width: half, height: 22))
            right.isHidden = false
            CallIsland.titled(right, "Admit All", main: true)
            CallIsland.put(right, NSRect(x: 10 + half + 6, y: 8, width: half, height: 22))
        }
        place()
    }

    /// A face: the page's picture of them, or their initial on a plate
    /// until it comes; ringed in the island's own dark, so faces in a
    /// stack stay apart.
    @discardableResult
    private func face(_ person: CallNews.Person, side: CGFloat, at point: NSPoint) -> NSImageView {
        let view = NSImageView(frame: NSRect(origin: point, size: NSSize(width: side, height: side)))
        view.wantsLayer = true
        view.layer?.cornerRadius = side / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1.5
        view.layer?.borderColor = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 28 / 255, alpha: 0.9).cgColor
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = CallIsland.initial(person.name, side: side)
        if let url = person.face {
            CallIsland.load(url) { [weak view] image in view?.image = image }
        }
        sheet.addSubview(view)
        faces.append(view)
        return view
    }

    private static var pictures: [URL: NSImage] = [:]

    private static func load(_ url: URL, _ done: @escaping (NSImage) -> Void) {
        if let hit = pictures[url] { return done(hit) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pictures[url] = image
                    done(image)
                }
            }
        }.resume()
    }

    /// Their first letter on a soft plate, as Meet shows someone without a
    /// picture.
    static func initial(_ name: String, side: CGFloat) -> NSImage {
        let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(srgbRed: 0.91, green: 0.86, blue: 0.97, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let font = NSFont.systemFont(ofSize: side * 0.42, weight: .medium)
            let words = NSAttributedString(string: letter, attributes: [
                .font: font, .foregroundColor: NSColor(srgbRed: 0.35, green: 0.18, blue: 0.6, alpha: 1),
            ])
            let size = words.size()
            words.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        switch (shape, sender === right) {
        case (.card, true), (.list, true), (.line, true):
            onAsk?(.admit(many ? nil : news.waiting.first?.name))
        case (.card, false):
            if many { reshape(.list) } else { onAsk?(.deny(news.waiting.first?.name)) }
        case (.list, false):
            onAsk?(.deny(nil))
        default: break
        }
    }

    @objc private func admitOne(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onAsk?(.admit(name))
    }

    /// A right-click on the island: everything its buttons do, and Deny,
    /// which a narrow window's card has no room for.
    func askMenu() -> NSMenu? {
        guard !news.waiting.isEmpty else { return nil }
        let menu = NSMenu()
        func line(_ title: String, _ mark: String?, act: @escaping () -> Void) {
            let item = PageMenuItem(title, act: act)
            MenuMark.put(mark, on: item)
            menu.addItem(item)
        }
        if many {
            if shape != .list { line("View", nil) { [weak self] in self?.reshape(.list) } }
            line("Admit All", "yab.person.check") { [weak self] in self?.onAsk?(.admit(nil)) }
            line("Deny All", "yab.person.x") { [weak self] in self?.onAsk?(.deny(nil)) }
        } else if let name = news.waiting.first?.name {
            line("Admit", "yab.person.check") { [weak self] in self?.onAsk?(.admit(name)) }
            line("Deny", "yab.person.x") { [weak self] in self?.onAsk?(.deny(name)) }
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { askMenu() }

    /// For the bench.
    func press(_ name: String) {
        switch name {
        case "admit": pressed(right)
        case "deny", "view", "deny-all": pressed(left)
        default: break
        }
    }

    var benchState: [String: Any] {
        ["shape": "\(shape)", "look": "\(look)", "title": title.isHidden ? "" : title.stringValue,
         "buttons": [left, right].filter { !$0.isHidden }.map(\.title), "rows": rows.map(\.name.stringValue),
         "menu": askMenu()?.items.map(\.title) ?? [], "size": NSStringFromSize(size(in: superview?.bounds.width ?? 352)),
         "radius": plate.cornerRadius]
    }
}

/// The field to answer the chat in, where the message was: one line,
/// Return sends it to everyone, Escape puts it away.
final class CallReply: NSView, NSTextFieldDelegate {
    /// The words sent, as Return sends them.
    var onSend: ((String) -> Void)?
    var onDone: (() -> Void)?

    private let plate = FloatGlass.media(cornerRadius: 14) // design: capsule, half its 28 pt height
    let field = NSTextField()
    private let key = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(plate)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Message everyone", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.45),
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingHead
        field.delegate = self
        plate.content.addSubview(field)
        // Return as the Mac draws it, on a plate: the key that sends.
        // At the words' size, 12, not the plate's: the key a mark, not a button.
        let mark = KeyArt.image("↩")?.copy() as? NSImage
        mark?.size = NSSize(width: 12, height: 12)
        key.image = mark
        // Brighter than a hint: on the dark glass it has to read at a glance.
        key.contentTintColor = NSColor(white: 1, alpha: 0.9)
        key.imageScaling = .scaleNone
        key.wantsLayer = true
        key.layer?.cornerRadius = 6
        key.layer?.backgroundColor = NSColor(white: 1, alpha: 0.24).cgColor
        plate.content.addSubview(key)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        plate.frame = bounds
        plate.cornerRadius = bounds.height / 2
        // The key 4 in from the end, the top and the bottom alike, its
        // corners the field's less those 4, so the two are concentric; the
        // words 11 in, the field's own inset.
        let inset: CGFloat = 4, keyHeight = bounds.height - 2 * inset
        key.frame = NSRect(x: bounds.width - inset - 24, y: inset, width: 24, height: keyHeight)
        key.layer?.cornerRadius = bounds.height / 2 - inset
        field.frame = NSRect(x: 11, y: 6, width: bounds.width - 11 - 34, height: 16)
    }

    /// Open; `after` a message's bubble has come down to be this field, it
    /// shows as the bubble gets here.
    func open(after delay: TimeInterval = 0) {
        isHidden = false
        window?.makeKey()
        window?.makeFirstResponder(field)
        guard delay > 0, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isHidden else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    self.animator().alphaValue = 1
                }
            }
        }
    }

    func close() {
        field.stringValue = ""
        isHidden = true
        alphaValue = 1
        onDone?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let words = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Sent, the field stays for the next line, the thread over it
            // showing it; Return on nothing puts it away.
            guard !words.isEmpty else { close(); return true }
            onSend?(words)
            field.stringValue = ""
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}
