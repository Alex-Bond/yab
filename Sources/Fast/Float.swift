import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything, other tabs, and other apps.
//
// WebKit will not hand a video to the system's picture-in-picture without a
// real click on the page, and nothing the app does counts as one. Chromium is
// looser, which is why this works elsewhere and refused here.
//
// So the engine is not asked. The page itself is moved: everything but the
// video is made invisible, the video is stretched to fill the viewport, and the
// whole web view is lifted out of the window and into a small floating one. The
// video never stops, because it is the same page it always was, it has only
// changed windows.

@MainActor
final class Floater {
    private var panel: Panel?
    private var controls: Controls?
    /// Black, over the page and under the buttons, for while the page in
    /// the window is between documents.
    private var blind: NSView?
    private weak var page: NSView?

    /// Asked to go away. The browser does the bookkeeping and calls back into
    /// `drop`, there is one way this window closes, and it is not this class
    /// quietly tidying up behind everyone's back. Two paths to closing is how
    /// it stayed on screen after the page had already gone home.
    var onClose: (() -> Void)?
    /// The close button or Escape, distinct from the page disappearing.
    var onDismiss: (() -> Void)?
    /// The minimize button: the window goes and the video keeps playing in
    /// its tab, the island taking it in the column (rows 1090, 1038).
    var onMinimize: (() -> Void)?
    /// Bring the window forward and go to the tab it came from.
    var onReturn: (() -> Void)?
    /// Stop or start the video. Answers with whether it is playing now.
    var onPlayPause: ((@escaping (Bool) -> Void) -> Void)?
    /// Whether the tab itself is muted. The control changes the floated
    /// video's sound, and answers with that video's new mute state.
    var onSound: (() -> Bool?)?
    var onMute: ((@escaping (Bool?) -> Void) -> Void)?
    /// Step over the bit you missed, or back to it. Answers once it has.
    var onSkip: ((Double, @escaping () -> Void) -> Void)?
    /// To a point along the video, nought to one: exactly, or roughly, to
    /// the nearest frame that shows at once, while the bar is still being
    /// dragged. Answers once the page has it.
    var onSeek: ((Double, Bool, @escaping () -> Void) -> Void)?
    /// Fetch the video again from where it stands, after it failed or
    /// stuck (Try Again). Answers once the page has been asked.
    var onRetry: ((@escaping () -> Void) -> Void)?
    /// Asked twice a second while the buttons show and the video plays,
    /// once a second otherwise, for where the video is. Always answers,
    /// nil when the page had nothing to say.
    var onProgress: ((@escaping (Playhead?) -> Void) -> Void)?

    /// Where the video is, as the page says.
    struct Playhead {
        var through: Double
        var playing: Bool
        /// Seconds in, and of the whole; a live stream has no whole, 0.
        var time: Double
        var length: Double
        var rate: Double
        /// The picture's own size, 0 until the video knows it.
        var width: Double
        var height: Double
        /// Playing and actually moving: not waiting on the network or a seek.
        var moving: Bool
        /// Muted inside the page, independently of the tab's own mute.
        var muted: Bool
        /// A live stream's stretch, nil for a video (LiveEdge.swift). A
        /// live stream has no length either, so no chapters and no clock.
        var live: LiveEdge.Window?
        /// An advert plays in the video's player (YouTube's says so).
        var ad = false
        /// What the page has fetched around where it is, in seconds: the
        /// stretch it can go to at once. Nil when it has nothing there.
        var loaded: (from: Double, to: Double)?
        /// The video's MediaError code, 0 for none.
        var error = 0

        /// Meant to play, and held up: fetching, or seeking.
        var waiting: Bool { playing && !moving }

        /// From what the page's `where` answers, or nil for anything else.
        init?(_ found: Any?) {
            guard let all = found as? [Any], all.count >= 8 else { return nil }
            let number = all.map { value -> Double in
                let n = (value as? NSNumber)?.doubleValue ?? 0
                return n.isFinite ? n : 0
            }
            through = min(max(number[0], 0), 1)
            playing = (all[1] as? Bool) ?? false
            time = max(0, number[2])
            length = max(0, number[3])
            rate = number[4]
            width = number[5]
            height = number[6]
            moving = (all[7] as? Bool) ?? false
            muted = all.count > 8 ? ((all[8] as? Bool) ?? false) : false
            if all.count > 11, (all[9] as? Bool) == true {
                let window = LiveEdge.Window(start: number[10] >= 0 ? number[10] : nil, edge: max(number[11], time), time: time)
                live = window
                length = 0
                through = window.through
            }
            ad = all.count > 12 ? ((all[12] as? Bool) ?? false) : false
            if all.count > 15 {
                if number[14] > number[13] { loaded = (number[13], number[14]) }
                // A finite page value can still be outside Int's range.
                error = Int(exactly: number[15]) ?? 0
            }
        }
    }
    /// Asked a few times a second, for the subtitles showing now, drawn by
    /// the window itself (`Captions`).
    var onWords: ((@escaping (String) -> Void) -> Void)?
    /// The video's chapters, as the page lists them: YouTube's, or a
    /// <track kind="chapters"> of its own. Asked once a video, not with
    /// every reading. Always answers, none when it had nothing to say.
    var onChapters: ((@escaping ([Chapter]) -> Void) -> Void)?
    /// Plays at this speed; answers with the speed the video has now, nil
    /// when the page said nothing.
    var onRate: ((Double, @escaping (Double?) -> Void) -> Void)?
    /// The video's subtitles: asked (-2), all off (-1) or the one of that
    /// number shown. Answers with what the video has, nil for nothing.
    var onSubtitles: ((Int, @escaping (Subtitles?) -> Void) -> Void)?

    /// The subtitles a video offers and the one showing.
    struct Subtitles: Equatable {
        struct Track: Equatable {
            var name: String
            /// A language's code, "en", "pt-BR"; empty where the page
            /// names its tracks only.
            var code: String
            /// Made from another track by the player, into `code`.
            var translated: Bool
        }
        var tracks: [Track]
        /// The one showing, -1 for none.
        var now: Int
        /// The one in the language the video speaks, -1 if unknown.
        var spoken: Int

        /// From what the page answers: [now, [name, …]] for a video's own
        /// <track>s, [now, [[name, code, kind], …], spoken] for YouTube's.
        init?(_ found: Any?) {
            guard let all = found as? [Any], all.count >= 2, let list = all[1] as? [Any] else { return nil }
            tracks = list.enumerated().map { index, item in
                if let row = item as? [Any] {
                    let name = row.first as? String ?? ""
                    return Track(name: name.isEmpty ? "Track \(index + 1)" : name,
                                 code: row.count > 1 ? row[1] as? String ?? "" : "",
                                 translated: row.count > 2 && row[2] as? String == "translated")
                }
                let name = item as? String ?? ""
                return Track(name: name.isEmpty ? "Track \(index + 1)" : name, code: "", translated: false)
            }
            let current = (all[0] as? NSNumber)?.intValue ?? -1
            now = tracks.indices.contains(current) ? current : -1
            let heard = all.count > 2 ? (all[2] as? NSNumber)?.intValue ?? -1 : -1
            spoken = tracks.indices.contains(heard) ? heard : -1
        }

        init(tracks: [Track], now: Int, spoken: Int) {
            self.tracks = tracks
            self.now = now
            self.spoken = spoken
        }

        /// The few a menu lists first: the spoken language's, those in the
        /// languages this Mac is set to, the translation into the first of
        /// them, and whatever shows now. The rest wait under More Languages.
        func first(languages: [String] = Locale.preferredLanguages) -> [Int] {
            let wanted = languages.map { Self.base($0) }
            var out: [Int] = []
            func add(_ index: Int) { if tracks.indices.contains(index), !out.contains(index) { out.append(index) } }
            add(spoken)
            for code in wanted {
                for (index, track) in tracks.enumerated() where !track.translated && Self.base(track.code) == code { add(index) }
            }
            for (index, track) in tracks.enumerated() where track.translated { add(index) }
            add(now)
            // A page that names its tracks only: all of them, there are few.
            if tracks.allSatisfy({ $0.code.isEmpty }) { return Array(tracks.indices) }
            if out.isEmpty { add(0) }
            return out
        }

        static func base(_ code: String) -> String {
            String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        }
    }

    /// Where a chapter starts, in seconds, and what it is called.
    struct Chapter: Equatable {
        var start: Double
        var title: String

        /// From what the page's `chapters` answers.
        static func list(_ found: Any?) -> [Chapter] {
            guard let all = found as? [Any] else { return [] }
            return all.prefix(500).compactMap { item in
                guard let pair = item as? [Any], pair.count >= 2,
                      let start = (pair[0] as? NSNumber)?.doubleValue, start.isFinite
                else { return nil }
                return Chapter(start: start, title: String((pair[1] as? String ?? "").prefix(200)))
            }
        }

        /// What the bar shows of `list` for a video `length` long: in order,
        /// one to a start, the first at the beginning. Nothing, a bar in one
        /// piece, for fewer than two, and for a list that runs past the end,
        /// which is a list for another video: the film's while its advert
        /// plays, or the last one's while the next one's page comes in.
        static func fitted(_ list: [Chapter], length: Double) -> [Chapter] {
            guard length > 0 else { return [] }
            if list.contains(where: { $0.start < 0 || $0.start >= length }) { return [] }
            var out: [Chapter] = []
            for chapter in list.sorted(by: { $0.start < $1.start }) {
                if let last = out.last, chapter.start - last.start < 0.5 { continue }
                out.append(chapter)
            }
            if let first = out.first, first.start >= 0.5 { out.insert(Chapter(start: 0, title: ""), at: 0) }
            return out.count >= 2 ? out : []
        }

        /// How near a chapter's start, in points along the bar, a click or
        /// the knob is taken to it: a small window's bar has seconds to a
        /// point, and the start of a piece is hard to hit by hand.
        static let reach: CGFloat = 8

        /// The chapter whose start a point `x` along a bar `width` wide is
        /// taken to: the nearest within `reach`, or none.
        static func snapped(_ list: [Chapter], length: Double, width: CGFloat, at x: CGFloat, reach: CGFloat = Chapter.reach) -> Int? {
            guard list.count > 1, length > 0, width > 0 else { return nil }
            var best: (index: Int, off: CGFloat)?
            for (index, chapter) in list.enumerated() {
                let off = abs(width * CGFloat(chapter.start / length) - x)
                if off <= reach, off < best?.off ?? .infinity { best = (index, off) }
            }
            return best?.index
        }
    }

    /// Whether the window says the video is held up, from what the page
    /// says of it: nothing for a short wait, which comes every few minutes
    /// and would only blink; the spinner once it lasts; words once it is
    /// long; and a video that can't play, or hasn't moved for half a
    /// minute, said so with a way to try again.
    struct Hold: Equatable {
        enum Failure: Equatable { case network, decode, format, stuck }
        enum Look: Equatable { case none, waiting, slow, failed(Failure) }

        /// Held up for less than this, nothing shows.
        static let quiet: CFTimeInterval = 0.4
        /// After a step or a seek of one's own, which is waited on anyway.
        static let afterSeek: CFTimeInterval = 0.3
        static let slow: CFTimeInterval = 8
        static let givenUp: CFTimeInterval = 30

        /// Since when it has been held up, and when a reading last found
        /// it so: the spinner needs a reading as late as `quiet` after the
        /// first, so a wait that ended between readings never shows.
        private(set) var since: CFTimeInterval?
        private var seen: CFTimeInterval?
        private var quiet = Hold.quiet
        private var failure: Failure?

        /// A reading of the page: held up (meant to play, not moving), and
        /// the video's error code (MediaError: 2 network, 3 decode, 4
        /// format; 1, stopped by the page, and 0 are none).
        mutating func read(held: Bool, error: Int, at now: CFTimeInterval) {
            failure = [2: .network, 3: .decode, 4: .format][error]
            guard held, failure == nil else {
                since = nil
                seen = nil
                quiet = Hold.quiet
                return
            }
            if since == nil { since = now }
            seen = now
        }

        /// A step or a seek sent from here: what the page says next is
        /// counted from now, and shows sooner.
        mutating func seeked(at now: CFTimeInterval) {
            guard failure == nil else { return }
            since = now
            seen = nil
            quiet = Hold.afterSeek
        }

        /// Tried again: waiting from now, shown at once.
        mutating func retried(at now: CFTimeInterval) {
            failure = nil
            since = now
            seen = now
            quiet = 0
        }

        func look(at now: CFTimeInterval) -> Look {
            if let failure { return .failed(failure) }
            guard let since, let seen, seen - since >= quiet else { return .none }
            let long = now - since
            return long >= Hold.givenUp ? .failed(.stuck) : long >= Hold.slow ? .slow : .waiting
        }

        /// Held up and not yet showing it: when to read the page again to
        /// know, rather than wait for the next tick.
        func confirm(at now: CFTimeInterval) -> CFTimeInterval? {
            guard let since, failure == nil, look(at: now) == .none else { return nil }
            return max(0.1, since + quiet - now)
        }
    }

    /// What is out: a video, or a call (FloatCall.swift), which has its own
    /// buttons, its own place on the screen and no shape to keep.
    enum Kind { case video, call }
    /// Kept after the window closes, for the browser to know what to put back.
    private(set) var kind = Kind.video
    /// When a video went up, for Yab Wrapped's minutes in the window.
    private var liftedAt: Date?
    private var call: CallControls?
    /// The page, at the size it had on the stage, shown smaller: never
    /// made another size, so WebKit lays nothing out again and moves no
    /// video layer, on the way out or home.
    private var lens: Lens?
    /// The page's size on the stage, as it leaves it.
    private var native: NSSize?
    /// A video's shape, width over height, once known: what of the page
    /// the lens shows, the video in the middle of it and not the black
    /// either side.
    private var focus: CGFloat? {
        didSet { lens?.focus = focus }
    }
    /// A call's buttons.
    var onMic: (() -> Void)?
    var onCamera: (() -> Void)?
    var onShare: (() -> Void)?
    var onLeave: (() -> Void)?
    /// A call's devices, as a menu over the microphone's or the camera's
    /// arrow; and what makes its row: your screen shown, a Share to press,
    /// a choice of devices for each.
    var callMenu: ((CallControls.Devices) -> NSMenu?)?
    var callRow: (() -> (presenting: Bool, sharable: Bool, choice: (mic: Bool, camera: Bool)))?
    /// A call's window at a new width, in points, and its buttons up or not:
    /// the stage lays its people out to it (CallStage).
    /// The call's window: its size in points, and the part of the page it
    /// shows, in the page's own points from its top left.
    var onCallSize: ((NSSize, NSRect) -> Void)?
    var onCallNear: ((Bool) -> Void)?
    /// How much of the call window's foot is taken, in points: its row, a
    /// word in its place, the chat's field.
    var onCallBand: ((CGFloat) -> Void)?
    /// What the call window asks of the page: someone let in, a hand, a
    /// reaction, a message (CallNews.swift).
    var onCallAsk: ((CallAsk) -> Void)?
    /// Each tick of a call's window: its news read again.
    var onCallTick: (() -> Void)?
    private var sizing: NSObjectProtocol?
    private var screening: NSObjectProtocol?
    private var screenLayout: [FloatPark.Screen] = []
    /// The call's microphone and camera, as WebKit has them now.
    var callState: (() -> (mic: PageMediaState, camera: PageMediaState))?
    /// Whole minutes left of the call's meeting, its last five only.
    var callLeft: (() -> Int?)?

    private var ticker: Timer?
    private var listening: Timer?
    private var captions: Captions?
    /// Turned off here, for a page with no tracks to turn off: its words
    /// are still read, never drawn.
    private var wordsOff = false
    private var frost: Frost?
    /// A video or call window's corners: the browser window's own
    /// (`Radius.window`), so a picture floating beside it reads as one of
    /// Yab's windows (#239). The corner buttons, 28 across and 6 in, and the
    /// bar's 26 pt capsule sit a little more than 6 from the curve.
    static let corner: CGFloat = Radius.window

    var showing: Bool { panel != nil }

    /// The floating window, for the app's key watcher to leave its keys be.
    static func owns(_ window: NSWindow?) -> Bool { window is Panel }
    /// Handed back to the stage, and waiting for it to take the page. The
    /// window stays up, showing it, until the moment it does.
    private(set) var homing = false
    /// Listening for the window to be on screen, before the page moves in.
    private var seen: NSObjectProtocol?
    /// Whether the page has moved in (`arrive`): until it has, its not
    /// being in the window is its being on its way, not its having left.
    private var arrived = false

    /// Where the window was last, at the size it was, kept across closing it
    /// and quitting. Given back only while a screen still shows most of it:
    /// a display unplugged since would put it nowhere.
    private static var remembered: NSRect? {
        get { recall("float.frame") }
        set { Store.settings.set(newValue.map(NSStringFromRect), forKey: "float.frame") }
    }

    /// A call's, apart: people are sized and put somewhere else than films.
    private static var rememberedCall: NSRect? {
        get { recall("float.call.frame") }
        set { Store.settings.set(newValue.map(NSStringFromRect), forKey: "float.call.frame") }
    }

    private func remember(_ frame: NSRect) {
        if kind == .call { Floater.rememberedCall = frame } else { Floater.remembered = frame }
    }

    private static func recall(_ key: String) -> NSRect? {
        guard let text = Store.settings.string(forKey: key) else { return nil }
        let frame = NSRectFromString(text)
        guard frame.width >= 200, frame.height >= 100 else { return nil }
        let shown = NSScreen.screens.contains {
            let seen = $0.visibleFrame.intersection(frame)
            return seen.width * seen.height > 0.6 * frame.width * frame.height
        }
        return shown ? frame : nil
    }

    /// Quitting with the window up closes nothing, so it is kept then too.
    private var quitting: NSObjectProtocol?

    /// `shape` is the video's own width and height, when the page knew it:
    /// the window is made that shape from the start, so the page is laid
    /// out in it once, not once and then again. `whole`: the view is the
    /// video alone, WebKit's own out of its page (FloatPiP.swift), and
    /// fills the window at its size rather than being shown smaller.
    func lift(_ page: NSView, shape: CGSize? = nil, kind: Kind = .video, whole: Bool = false) {
        guard panel == nil else { return }
        self.page = page
        self.kind = kind
        arrived = false
        liftedAt = kind == .video ? Date() : nil
        mediaMuted = false
        generation += 1

        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Where it was left, or the bottom right of this screen: a call a
        // little smaller than a film, four faces at a glance.
        let fresh = kind == .call ? CGSize(width: 352, height: 198) : CGSize(width: 440, height: 247)
        var spot = (kind == .call ? Floater.rememberedCall : Floater.remembered) ?? NSRect(
            x: screen.maxX - fresh.width - 24,
            y: screen.minY + 24,
            width: fresh.width,
            height: fresh.height
        )
        // The page keeps the size it has on the stage, a call's and a
        // video's alike, and is shown smaller (Lens): made another size, the
        // whole page was laid out again on the way out and again on the way
        // home, and every video layer in it moved. A call's window is the
        // page's shape; a video's is the video's, cut from the middle of
        // the page, where the video is made as large as it fits.
        native = !whole && page.frame.width > 0 && page.frame.height > 0 ? page.frame.size : nil
        if kind == .call, let native {
            let area = NSScreen.screens.first { $0.visibleFrame.intersects(spot) }?.visibleFrame ?? screen
            spot = Floater.fitted(spot, to: native.width / native.height, in: area)
        }
        focus = kind == .video ? shape.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } : nil
        if kind == .video, let shape, shape.width > 0, shape.height > 0 {
            let area = NSScreen.screens.first { $0.visibleFrame.intersects(spot) }?.visibleFrame ?? screen
            spot = Floater.fitted(spot, to: shape.width / shape.height, in: area)
        }
        // Reopen where it was left when free placement is selected.
        if let area = FloatPark.screen(for: spot, in: Floater.screens)?.visible {
            spot.origin = snapsToEdges ? FloatPark.nearest(spot, in: area) : FloatPark.bounded(spot, in: area)
        }
        let size = spot.size

        // The window of the last time, if there was one, kept rather than
        // made again: making a window is a round trip to the window server
        // for its context, 5 to 30 ms of the main thread, more on a busy Mac.
        let panel = Floater.spare ?? Panel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        Floater.spare = nil
        panel.setFrame(spot, display: false)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.aspectRatio = NSSize(width: 0, height: 0)
        panel.sharingType = .readOnly
        // It comes and goes at once: the system's own zoom for a window
        // ordered in and out waits on a fence with the window server.
        panel.animationBehavior = .none
        // Above every ordinary window, this app's and everyone else's, and
        // present on whichever desktop you happen to be looking at. Each
        // new window floats; Keep on Top unticked is that window's alone.
        keepsOnTop = true
        Floater.raise(panel, true)
        // Yab hidden (⌘H) leaves it up, as the system's window stays when
        // the app it came from is hidden.
        panel.canHide = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        if kind == .call {
            // Any shape: the page fills it, cut at the sides or the top and
            // bottom (Lens.fill), and the people are laid out again for it
            // over the part shown (CallStage `size`). Setting increments
            // takes the shape lock off.
            panel.resizeIncrements = NSSize(width: 1, height: 1)
            panel.minSize = NSSize(width: FloatHand.shapeLimits.shortest, height: FloatHand.shapeLimits.shortest)
            // Not in a screen share: yourself, in a window over what you
            // show, would be the call looking at itself. A test world being
            // filmed for a demo keeps it in the film (Store.recording).
            panel.sharingType = Store.recording ? .readOnly : .none
        } else {
            Floater.shape(panel, size.width / size.height)
        }
        quitting = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                if let self, let panel { self.remember(self.resting ?? panel.frame) }
            }
        }

        let ground = Ground(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = Floater.corner
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recognizer on a web view, and a gesture
        // recognizer is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        (page as? WKWebView)?.allowsMagnification = false

        let blind = NSView(frame: ground.bounds)
        blind.autoresizingMask = [.width, .height]
        blind.wantsLayer = true
        blind.layer?.backgroundColor = NSColor.black.cgColor
        blind.isHidden = true
        ground.addSubview(blind)
        self.blind = blind
        do {
            // Over the picture, under the buttons: what it turns into on its
            // way behind a side, blurred and dark (`presentTuck`), a call's
            // as a video's.
            let frost = Frost(frame: ground.bounds)
            frost.autoresizingMask = [.width, .height]
            ground.addSubview(frost)
            self.frost = frost
        }

        let keys: NSView
        if kind == .call {
            let call = CallControls(frame: ground.bounds)
            call.freeShape = true
            call.autoresizingMask = [.width, .height]
            call.onClose = { [weak self] in self?.onDismiss?() }
            call.onReturn = { [weak self] in self?.onReturn?() }
            call.onMic = { [weak self] in self?.onMic?(); self?.refreshCall() }
            call.onCamera = { [weak self] in self?.onCamera?(); self?.refreshCall() }
            call.onShare = { [weak self] in self?.onShare?() }
            call.onLeave = { [weak self] in self?.onLeave?() }
            call.menuFor = { [weak self] which in self?.callMenu?(which) }
            call.onLetGo = { [weak self] at in self?.letGo(at: at) }
            call.onCarry = { [weak self] hand in self?.carry(hand) ?? false }
            call.onTravel = { [weak self] hand in self?.travel(hand) }
            call.onTuck = { [weak self] side in self?.tuck(side) }
            call.onNear = { [weak self] near in self?.onCallNear?(near) }
            call.onBand = { [weak self] taken in self?.onCallBand?(taken) }
            call.onAsk = { [weak self] ask in self?.onCallAsk?(ask) }
            ground.addSubview(call)
            self.call = call
            keys = call
        } else {
            let controls = Controls(frame: ground.bounds)
            controls.autoresizingMask = [.width, .height]
            // Put away or sent home, it goes as it came: blurred and faint.
            controls.onClose = { [weak self] in self?.appear(false) { self?.onDismiss?() } }
            controls.onReturn = { [weak self] in self?.appear(false) { self?.onReturn?() } }
            controls.onMinimize = { [weak self] in self?.appear(false) { self?.onMinimize?() } }
            controls.onPlayPause = { [weak self] in
                self?.onPlayPause? { playing in
                    self?.controls?.playing = playing
                }
            }
            controls.onSkip = { [weak self] seconds in
                self?.seeked()
                self?.onSkip?(seconds) { self?.poll() }
            }
            controls.onRetry = { [weak self] in self?.retry() }
            controls.onSeek = { [weak self] through, exact in self?.seek(through, exact: exact) }
            controls.onMute = { [weak self] in
                guard let self else { return }
                self.onMute? { [weak self] muted in
                    guard let self else { return }
                    if let muted { self.mediaMuted = muted }
                    self.controls?.show(muted: self.soundState())
                    self.poll()
                }
            }
            controls.show(muted: soundState())
            controls.onRate = { [weak self] speed in
                self?.onRate?(speed) { [weak self] now in
                    if let now { self?.controls?.rate = now }
                    self?.poll()
                }
            }
            controls.onSubtitle = { [weak self] choice in self?.subtitle(choice) }
            // Up again after a while out of sight: what it shows is half a
            // second old at most, and read now rather than on the next tick.
            controls.onShow = { [weak self] in self?.poll() }
            controls.onLetGo = { [weak self] at in self?.letGo(at: at) }
            controls.onCarry = { [weak self] hand in self?.carry(hand) ?? false }
            controls.onTravel = { [weak self] hand in self?.travel(hand) }
            controls.onTuck = { [weak self] side in self?.tuck(side) }
            controls.snapToEdges = { [weak self] in self?.snapsToEdges ?? true }
            controls.menuFor = { [weak self] in self?.pictureMenu() }

            let captions = Captions(frame: ground.bounds)
            captions.autoresizingMask = [.width, .height]
            ground.addSubview(captions)
            self.captions = captions
            // Up out of the way of the bar along the bottom while the buttons
            // are showing, as YouTube's go up over its bar.
            controls.onNear = { [weak captions] near in captions?.raised = near }

            ground.addSubview(controls)
            self.controls = controls
            keys = controls
        }

        panel.contentView = ground
        // WebKit's own gesture recognizer can claim a pinch before the
        // covering controls receive magnify(with:). The panel sees the event
        // first and hands it to the window's one sizing handler.
        panel.onMagnify = { [weak self, weak keys] event in
            guard let self else { return }
            if self.parked != nil || self.tuckFraction > 0 || self.lip?.interacting == true { return }
            (keys as? FloatHand)?.magnify(with: event)
        }
        // The controls can receive keys once the pointer makes this
        // nonactivating panel key, without a preparatory click for pinch.
        panel.initialFirstResponder = keys
        panel.makeFirstResponder(keys)
        // Faint at first, for `appear` to bring up.
        if kind == .video, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.alphaValue = 0.05 }
        panel.orderFrontRegardless()
        self.panel = panel
        // Where it was last, or in the corner: it comes up there, from a
        // little smaller, faint and blurred (`appear`).
        if kind == .video { appear(true) }
        screenLayout = Floater.screens
        screening = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        // Into a window that is already on screen, straight from the one it
        // was in, and only once the window server has said it is on screen.
        // A window just ordered in is not visible yet as far as occlusion
        // goes, the answer comes a few frames later, and WebKit reads a page
        // in such a window as hidden: it paused the video, and let it go
        // again when the answer came. That was the stall on the way out.
        // Until then the page goes on playing where it was.
        if panel.occlusionState.contains(.visible) {
            arrive()
        } else {
            seen = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard panel.occlusionState.contains(.visible) else { return }
                    self?.arrive()
                }
            }
            // A window that never hears back still gets its page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.arrive()
            }
        }
        ground.onLoss = { [weak self, weak panel] view in
            guard let self, self.homing, view === self.page else { return }
            // After this turn: the view is still on its way out of here.
            let generation = self.generation
            DispatchQueue.main.async { [weak self, weak view, weak panel] in
                guard let self, let panel, self.homing, self.generation == generation,
                      self.panel === panel, self.page === view else { return }
                self.drop()
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Not moved in yet: brought now. On a busy main thread this
                // timer's first tick can come before the turn that was to
                // bring it (a run loop timer and the main queue's blocks are
                // run in no set order once both are late), and it closed the
                // window for a page that had never arrived: a site's video
                // put out stayed with WebKit half way, the page's
                // requestPictureInPicture() never settled, and every press
                // after did nothing (FloatPiPTests in whole-suite runs, m4).
                guard self.arrived else { return self.arrive() }

                // A window that no longer holds the page has nothing to show
                // and no reason to exist. Something else took the page back,
                // and rather than hunt every path that could, this makes it
                // impossible for the empty black rectangle to outlive it by
                // more than half a second.
                if self.page?.superview !== (self.lens ?? ground) {
                    self.onClose?()
                    return
                }

                // A call has nothing to poll: WebKit answers for the
                // microphone and the camera without asking the page.
                guard self.kind == .video else { return self.refreshCall() }

                // Out of sight, the bar and the times are not drawn, and
                // the page is only asked whether it still plays: a video
                // that stops on its own brings the buttons back. Paused,
                // nothing moves to be read twice a second either.
                self.ticks += 1
                let watched = self.controls?.near == true && self.controls?.playing == true
                // Held up, it is read every tick, to say so and to stop.
                if watched || self.hold.since != nil || self.ticks.isMultiple(of: 2) { self.poll() }
            }
        }
        if kind == .call {
            tellCallSize()
            sizing = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tellCallSize() }
            }
            return refreshCall()
        }
        // Subtitles change with speech, and half a second behind it reads as
        // late; a fifth is under what an eye notices against a mouth.
        listening = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Tucked away, the words aren't shown: the page isn't asked
                // for them five times a second to draw nothing.
                guard let self, !self.homing, self.blind?.isHidden != false, self.parked == nil else { return }
                self.onWords? { [weak self] words in
                    guard let self, self.blind?.isHidden != false else { return }
                    // Words seen put the subtitles button up, for a page
                    // whose player keeps them to itself.
                    if !words.isEmpty { self.controls?.heard = true }
                    self.captions?.text = self.wordsOff ? "" : words
                }
            }
        }
    }

    /// A video's window coming up where it opens, or going away: from 94%
    /// to whole, faint to clear, the picture blurred to sharp, 0.3 s; going,
    /// the same way back, quicker, 0.22 s, and then `done`. Core Animation
    /// on the window's ground, so the window itself stays on screen and
    /// WebKit never reads the page as hidden. Reduce Motion: at once.
    private func appear(_ coming: Bool, then done: (() -> Void)? = nil) {
        guard kind == .video, let panel, let ground = panel.contentView, let layer = ground.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { done?(); return }
        let started = CACurrentMediaTime()
        let duration: CFTimeInterval = coming ? 0.3 : 0.22
        let w = ground.bounds.width / 2, h = ground.bounds.height / 2
        var small = CATransform3DMakeTranslation(w, h, 0)
        small = CATransform3DScale(small, 0.94, 0.94, 1)
        small = CATransform3DTranslate(small, -w, -h, 0)
        let curve = coming ? CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) : CAMediaTimingFunction(name: .easeIn)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: coming ? small : CATransform3DIdentity)
        scale.toValue = NSValue(caTransform3D: coming ? CATransform3DIdentity : small)
        scale.duration = duration
        scale.timingFunction = curve
        scale.fillMode = .both
        scale.isRemovedOnCompletion = coming
        layer.add(scale, forKey: "appear")
        // The window's own alpha, so its shadow comes and goes with it. Never
        // quite nought coming: a window the system reads as unseen is a page
        // WebKit pauses.
        panel.alphaValue = coming ? 0.05 : panel.alphaValue
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve
            panel.animator().alphaValue = coming ? 1 : 0
        }
        if tuckSide == nil {
            // Closing already scales and fades the whole window. Starting
            // a new live blur here adds GPU work to that transaction.
            if coming { frost?.fade(blur: 1, to: 0, over: duration) }
        }
        if DebugLog.pip { DebugLog.note(coming ? "appear-begin" : "close-begin") }
        guard !coming else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel, weak layer] in
            guard let self, let panel, self.panel === panel else { return }
            if DebugLog.pip { DebugLog.note("close-end", ["ms": DebugLog.ms(CACurrentMediaTime() - started)]) }
            done?()
            // Still here after that (nothing took the page): back as it was.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak panel, weak layer] in
                guard let self, let panel, self.panel === panel, !self.homing else { return }
                layer?.removeAnimation(forKey: "appear")
                if self.tuckSide == nil { self.frost?.show(blur: 0, dark: 0) }
                panel.alphaValue = 1
            }
        }
    }

    /// The window's size and the part of the page it shows, to the call's
    /// stage, which lays the people out for that part.
    private func tellCallSize() {
        guard let panel else { return }
        let size = panel.frame.size
        var shown = NSRect(origin: .zero, size: native ?? size)
        if let lens, let native {
            let seen = lens.bounds.intersection(NSRect(origin: .zero, size: native))
            shown = NSRect(x: seen.minX, y: native.height - seen.maxY, width: seen.width, height: seen.height)
        }
        onCallSize?(size, shown)
    }

    /// The page, into the window that is waiting for it. Once.
    private func arrive() {
        if let seen { NotificationCenter.default.removeObserver(seen) }
        seen = nil
        guard let page, let ground = panel?.contentView as? Ground, page.superview !== ground, !homing else { return }
        if let native {
            guard lens == nil || page.superview !== lens else { return }
            let lens = self.lens ?? Lens(frame: ground.bounds, content: native)
            lens.focus = focus
            lens.fill = kind == .call
            lens.autoresizingMask = [.width, .height]
            // The ground's watch, whenever it is set: the page leaving the
            // lens is the page leaving the window.
            lens.onLoss = { [weak ground] view in ground?.onLoss?(view) }
            if lens.superview == nil { ground.addSubview(lens, positioned: .below, relativeTo: blind) }
            self.lens = lens
            // Its own size, as on the stage: moving it here changes nothing
            // WebKit lays out.
            page.autoresizingMask = []
            page.frame = NSRect(origin: .zero, size: native)
            lens.addSubview(page)
            arrived = true
            return
        }
        page.frame = ground.bounds
        page.autoresizingMask = [.width, .height]
        ground.addSubview(page, positioned: .below, relativeTo: blind)
        arrived = true
    }

    // MARK: - where the video is

    private var ticks = 0
    /// A question to the page still out: one at a time, so a page slow to
    /// answer is never asked again behind its own back.
    private var asking = false
    /// Until then, what the page says is from before the last seek and
    /// would pull the bar back to where it was.
    private var settling: CFTimeInterval = 0

    private var askedAt: CFTimeInterval = 0
    /// Which window a question was asked for: an answer that comes back
    /// after it closed, or after another opened, is about nothing here.
    private var generation = 0
    private var mediaMuted = false

    private func soundState() -> Bool? {
        guard kind == .video else { return nil }
        return (onSound?() ?? false) || mediaMuted
    }

    private func poll() {
        // A page that never answered at all, gone or busy, is asked again
        // after a while rather than never.
        guard !asking || CACurrentMediaTime() - askedAt > 2, !homing, let onProgress else { return }
        asking = true
        askedAt = CACurrentMediaTime()
        let asked = generation
        onProgress { [weak self] head in
            guard let self, asked == self.generation else { return }
            self.asking = false
            // Between documents, what the page says is about the next one's
            // first video, as likely an advert as the film.
            guard var head, self.panel != nil, self.blind?.isHidden != false,
                  CACurrentMediaTime() > self.settling
            else { return }
            // Test runs only: the page's video held up, as fetching holds it.
            if Store.testing, self.benchStall { head.moving = false }
            if Store.testing, self.benchFail { head.error = 2 }
            self.controls?.show(head)
            // A live stream says it waits in words of its own (LiveEdge).
            self.hold.read(held: head.waiting && head.live == nil, error: head.error, at: CACurrentMediaTime())
            self.showHold()
            self.mediaMuted = head.muted
            self.controls?.show(muted: self.soundState())
            self.follow(head)
            self.chapter(head)
        }
    }

    // MARK: - chapters

    /// The length the chapters were last asked for, how many times, and
    /// when: a new length is a new video, an advert before the film or the
    /// film after it, or the next one on YouTube.
    private var chaptersFor: (length: Double, tries: Int, at: CFTimeInterval)?
    private var askingChapters = false

    /// Asks once a video, and again a few seconds apart while the page has
    /// none to give: YouTube lists them a while after the video starts.
    /// After that, every so often while the buttons show, for a page that
    /// changed its list, or went on to a video as long as the last.
    private func chapter(_ head: Playhead) {
        guard onChapters != nil, !askingChapters, let controls else { return }
        let now = CACurrentMediaTime()
        var fresh = false
        // A length that moves by less than a second is the same video: a
        // player streaming in pieces says how long it is more exactly as
        // it goes, and the bar would lose its chapters at every word.
        if let was = chaptersFor, abs(was.length - head.length) < 1 {
            if controls.chapters.isEmpty, was.tries < 4 {
                guard now - was.at > 3 else { return }
                chaptersFor = (head.length, was.tries + 1, now)
            } else {
                guard controls.near, now - was.at > 15 else { return }
                chaptersFor = (head.length, was.tries, now)
            }
        } else {
            chaptersFor = (head.length, 1, now)
            controls.chapters = []
            controls.subtitles = nil
            controls.heard = false
            wordsOff = false
            fresh = true
        }
        // The subtitles it has, asked as often as its chapters: YouTube
        // lists both a while after the video starts.
        askSubtitles()
        guard head.length > 0 else { return }
        askingChapters = true
        let asked = generation, length = head.length
        onChapters? { [weak self] list in
            guard let self, asked == self.generation else { return }
            self.askingChapters = false
            // Asked for another video than the one playing now.
            guard let current = self.chaptersFor, abs(current.length - length) < 1 else { return }
            let fitted = Chapter.fitted(list, length: length)
            // Asked again of the same video, a page that has put its list
            // away for a moment, a panel drawn anew, keeps the one it had.
            if fitted.isEmpty, !fresh, self.controls?.chapters.isEmpty == false { return }
            self.controls?.chapters = fitted
        }
    }

    private func askSubtitles() {
        let asked = generation
        onSubtitles?(-2) { [weak self] found in
            guard let self, asked == self.generation, let found else { return }
            self.controls?.subtitles = found
        }
    }

    /// Off (-1) or that track. A page with no tracks to choose from only
    /// has its words drawn here or not.
    private func subtitle(_ choice: Int) {
        guard let controls else { return }
        guard let known = controls.subtitles, !known.tracks.isEmpty else {
            wordsOff = choice < 0
            if wordsOff { captions?.text = "" }
            controls.wordsShown = !wordsOff
            return
        }
        // Shown at once as asked; the page's answer puts it right.
        controls.subtitles = Subtitles(tracks: known.tracks, now: choice, spoken: known.spoken)
        let asked = generation
        onSubtitles?(choice) { [weak self] found in
            guard let self, asked == self.generation else { return }
            if let found { self.controls?.subtitles = found }
            if choice < 0 { self.captions?.text = "" }
        }
    }

    /// Shapes a window may take: a phone's upright video to a cinema's.
    private static func sane(_ ratio: CGFloat) -> CGFloat { min(max(ratio, 0.4), 3) }

    /// A video of another shape than the window: the next one on YouTube,
    /// or the first, when its size came after the window. One resize of
    /// the page, not a stream of them, and never under a hand moving it.
    private func follow(_ head: Playhead) {
        guard let panel, head.width > 0, head.height > 0 else { return }
        // What the lens shows follows the video at once; the window's shape
        // waits for a still hand.
        if focus.map({ abs($0 - head.width / head.height) > 0.001 }) ?? true { focus = head.width / head.height }
        guard controls?.busy == false, parked == nil, glider == nil else { return }
        let ratio = Floater.sane(head.width / head.height)
        let now = panel.frame.width / panel.frame.height
        guard abs(ratio - now) / now > 0.02 else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        Floater.shape(panel, ratio)
        panel.setFrame(Floater.fitted(panel.frame, to: ratio, in: area), display: false)
    }

    /// The window made to keep `ratio` as it is sized, and never so small
    /// that its shorter side is under 146 points, or its longer under 260.
    private static func shape(_ panel: NSPanel, _ ratio: CGFloat) {
        let ratio = sane(ratio)
        panel.aspectRatio = NSSize(width: ratio, height: 1)
        panel.minSize = ratio >= 1
            ? NSSize(width: max(260, 146 * ratio), height: max(260, 146 * ratio) / ratio)
            : NSSize(width: max(260, 146 / ratio) * ratio, height: max(260, 146 / ratio))
    }

    /// `frame` in the shape of `ratio`, the same area it had, so a tall
    /// video takes about as much of the screen as a wide one did. It keeps
    /// to the corner of `area` it was nearest, and inside it.
    static func fitted(_ frame: NSRect, to ratio: CGFloat, in area: NSRect) -> NSRect {
        guard ratio > 0, frame.width > 0, frame.height > 0 else { return frame }
        let ratio = sane(ratio)
        let most = CGSize(width: area.width * 0.85, height: area.height * 0.85)
        var wide = (frame.width * frame.height * ratio).squareRoot()
        wide = min(wide, most.width, most.height * ratio)
        let short: CGFloat = 146, long: CGFloat = 260
        wide = max(wide, ratio >= 1 ? max(long, short * ratio) : max(short, long * ratio))
        let tall = wide / ratio
        var x = frame.midX > area.midX ? frame.maxX - wide : frame.minX
        var y = frame.midY > area.midY ? frame.maxY - tall : frame.minY
        x = min(max(x, area.minX), area.maxX - wide)
        y = min(max(y, area.minY), area.maxY - tall)
        return NSRect(x: x.rounded(), y: y.rounded(), width: wide.rounded(), height: tall.rounded())
    }

    /// Seeks while the bar is dragged go to the page one at a time and at
    /// most ten a second, the latest place winning; a drag sends a mouse
    /// event every frame, and each seek is the page fetching and decoding
    /// from somewhere else in the file. The one on letting go is exact and
    /// always sent.
    private var seeking = false
    private var waitingSeek: Double?
    private var lastSeek: CFTimeInterval = 0

    private var retrying = false
    /// Seeks sent, for the bench.
    private var sent = (rough: 0, exact: 0)
    /// Where the bench's held drag is ("hold"), for its "release".
    private var benchHeld: NSPoint?
    /// Test runs only: every reading taken as a video held up ("stall").
    private var benchStall = false
    /// Test runs only: every reading taken as a video that failed ("fail").
    private var benchFail = false

    // MARK: - held up

    private var hold = Hold()
    /// A reading asked for sooner than the next tick, to know whether a
    /// wait has lasted: one at a time.
    private var confirming = false

    /// What the buttons show of the wait, now; and a reading soon, while a
    /// wait has begun but not yet lasted long enough to say so.
    private func showHold() {
        let now = CACurrentMediaTime()
        controls?.wait = hold.look(at: now)
        guard let after = hold.confirm(at: now), !confirming else { return }
        confirming = true
        let asked = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, asked == self.generation else { return }
            self.confirming = false
            self.poll()
        }
    }

    /// A step or a seek from here: waited on from now, said a little
    /// sooner than a stall.
    private func seeked() {
        hold.seeked(at: CACurrentMediaTime())
        showHold()
    }

    private func retry() {
        hold.retried(at: CACurrentMediaTime())
        showHold()
        let asked = generation
        onRetry? { [weak self] in
            guard let self, asked == self.generation else { return }
            self.poll()
        }
    }

    private func seek(_ through: Double, exact: Bool) {
        settling = CACurrentMediaTime() + 1
        if exact {
            seeked()
            waitingSeek = nil
            send(through, exact: true)
        } else {
            waitingSeek = through
            sendWaiting()
        }
    }

    private func send(_ through: Double, exact: Bool) {
        guard let onSeek else { return }
        seeking = true
        lastSeek = CACurrentMediaTime()
        if exact { sent.exact += 1 } else { sent.rough += 1 }
        let asked = generation
        onSeek(through, !exact) { [weak self] in
            guard let self, asked == self.generation else { return }
            self.seeking = false
            if exact {
                // Where it landed, read now.
                self.settling = 0
                self.poll()
            } else {
                self.sendWaiting()
            }
        }
    }

    private func sendWaiting() {
        guard !seeking, !retrying, let next = waitingSeek else { return }
        let wait = 0.1 - (CACurrentMediaTime() - lastSeek)
        guard wait <= 0 else {
            retrying = true
            let asked = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, asked == self.generation else { return }
                self.retrying = false
                self.sendWaiting()
            }
            return
        }
        waitingSeek = nil
        send(next, exact: false)
    }

    /// Covers the page, or shows it again.
    func cover(_ on: Bool) {
        blind?.isHidden = !on
        // The old document's words have gone with it.
        if on { captions?.text = "" }
    }

    /// The page is going home, to a stage that will take it on its next
    /// update. Until it does, this window goes on showing it: put down first,
    /// it was in no window, hidden, its video paused, and a stage that was
    /// never told to take it back left it there.
    func release() {
        guard panel != nil, !homing else { return }
        homing = true
        // Home, the player draws its own again.
        captions?.text = ""
        (page as? WKWebView)?.allowsMagnification = true
        blurPicture(0)
        // Nobody came for it. Closing the window is what matters.
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak page = self.page, weak panel = self.panel] in
            guard let self, let panel, self.homing, self.generation == generation,
                  self.panel === panel, self.page === page else { return }
            self.drop()
        }
    }

    /// Closes, now. The page, if it is still here, is put down; whoever owns
    /// it takes it back on their next layout.
    func drop() {
        guard let panel else { return }
        if let liftedAt { WrappedLedger.shared.add(.pipMinutes, Date().timeIntervalSince(liftedAt) / 60) }
        liftedAt = nil
        remember(resting ?? panel.frame)
        if let sizing { NotificationCenter.default.removeObserver(sizing) }
        sizing = nil
        if let screening { NotificationCenter.default.removeObserver(screening) }
        screening = nil
        screenLayout = []
        stopGlide()
        blurPicture(0)
        parked = nil
        peeking = false
        lip = nil
        tuckFraction = 0
        tuckSide = nil
        tuckMask = nil
        tuckOut = false
        frost = nil
        call?.stopWatching()
        call?.stopGlide()
        call = nil
        homing = false
        arrived = false
        if let seen { NotificationCenter.default.removeObserver(seen) }
        seen = nil
        if let quitting { NotificationCenter.default.removeObserver(quitting) }
        quitting = nil
        controls?.stopGlide()
        controls?.stopWatching()
        mediaMuted = false
        ticker?.invalidate()
        ticker = nil
        generation += 1
        asking = false
        askingChapters = false
        chaptersFor = nil
        seeking = false
        retrying = false
        waitingSeek = nil
        settling = 0
        hold = Hold()
        confirming = false
        benchFail = false
        listening?.invalidate()
        listening = nil
        captions = nil
        (page as? WKWebView)?.allowsMagnification = true
        if let page, page.superview === panel.contentView || (lens != nil && page.superview === lens) { page.removeFromSuperview() }
        lens?.onLoss = nil
        lens?.removeFromSuperview()
        lens = nil
        native = nil
        focus = nil
        (panel.contentView as? Ground)?.onLoss = nil
        page = nil
        controls = nil
        blind = nil
        // Out of sight now, for nothing but a commit: ordering a window out
        // waits on the window server, up to 90 ms of the main thread on a
        // busy Mac, and right now the page is landing in its tab. The window
        // is ordered out once things are still, and kept for next time.
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.onMagnify = nil
        panel.contentView = nil
        self.panel = nil
        Floater.spare = panel
        let spared = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard Floater.spare === spared else { return }
            spared.orderOut(nil)
        }
    }

    /// The window last closed, kept to be the next one.
    private static var spare: Panel?

    // MARK: - over every window, or among them

    /// Over every window, as it comes up, or among them (Keep on Top
    /// unticked, Dia's toggle): then Yab's own window brought forward or
    /// anyone's covers it, and ⌘` reaches it as any window of the app.
    /// This window's only; the next one floats again.
    private(set) var keepsOnTop = true

    static let snapToEdgesKey = "float.snapToEdges"

    /// Video placement is remembered across openings; calls keep their own behavior.
    var snapsToEdges: Bool {
        kind == .call || (Store.settings.object(forKey: Self.snapToEdgesKey) as? Bool ?? true)
    }

    func snapToEdges(_ on: Bool) {
        guard kind == .video else { return }
        Store.settings.set(on, forKey: Self.snapToEdgesKey)
        stopGlide()
        controls?.stopGlide()
        if on, parked == nil { letGo() }
    }

    func keepOnTop(_ on: Bool) {
        keepsOnTop = on
        placeLevel()
    }

    /// Tucked behind a side, it floats whatever was chosen: under another
    /// window, the tab would be lost there.
    private func placeLevel() {
        guard let panel else { return }
        Floater.raise(panel, keepsOnTop || parked != nil)
    }

    private static func raise(_ panel: Panel, _ above: Bool) {
        panel.level = above ? .floating : .normal
        panel.collectionBehavior = above ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
    }

    /// A right-click on the video: stacking and placement, then ways home.
    private func pictureMenu() -> NSMenu? {
        guard kind == .video, let controls, parked == nil, tuckFraction == 0 else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let top = PageMenuItem("Keep on Top") { [weak self] in
            guard let self else { return }
            self.keepOnTop(!self.keepsOnTop)
        }
        top.state = keepsOnTop ? .on : .off
        MenuMark.put("yab.pip", on: top)
        menu.addItem(top)
        let snap = PageMenuItem("Snap to Edges") { [weak self] in
            guard let self else { return }
            self.snapToEdges(!self.snapsToEdges)
        }
        snap.state = snapsToEdges ? .on : .off
        MenuMark.put("yab.snap", on: snap)
        menu.addItem(snap)
        menu.addItem(.separator())
        let back = PageMenuItem("Back to Tab") { [weak controls] in controls?.onReturn?() }
        MenuMark.put("yab.tab.left", on: back)
        menu.addItem(back)
        let close = PageMenuItem("Close") { [weak controls] in controls?.onClose?() }
        MenuMark.put("yab.x", on: close)
        menu.addItem(close)
        return menu
    }

    // MARK: - a call

    /// The buttons and the strip, in step with WebKit.
    func refreshCall() {
        guard kind == .call, let state = callState?() else { return }
        call?.show(mic: state.mic, camera: state.camera)
        if let row = callRow?() { call?.show(presenting: row.presenting, sharable: row.sharable, choice: row.choice) }
        call?.show(left: callLeft?() ?? nil)
        onCallTick?()
    }

    /// What the call says beyond its people, read from the page.
    func showCallNews(_ news: CallNews) {
        guard kind == .call else { return }
        call?.show(news: news)
        edge(news)
    }

    /// The chat's field opened over the row, to answer a message.
    func openCallReply() { call?.openReply() }

    /// A word over a call's row for a few seconds (CallControls.say).
    func sayCall(_ words: String, use: (() -> Void)? = nil, for seconds: TimeInterval) {
        guard kind == .call else { return }
        call?.say(words, use: use, for: seconds)
    }

    /// For the bench: a call's button, pressed.
    func pressCall(_ name: String) { call?.press(name) }

    /// For the bench: a call's devices' menu, as it would open.
    func callMenuItems(_ which: CallControls.Devices) -> [String] { call?.benchMenu(which) ?? [] }
    /// For the bench: that menu open on the screen for `seconds`.
    func openCallMenu(_ which: CallControls.Devices, seconds: Double) -> Bool {
        guard let call else { return false }
        call.benchOpen(which, seconds: seconds)
        return true
    }

    // MARK: - tucked behind a side of the screen

    // Carried more than a third past the left or right edge, the button
    // still down, or let go of there: tucked with a lip left out. A shorter
    // carry comes back inside.

    /// The side of the screen the window is tucked behind, or nil.
    private(set) var parked: FloatPark.Side? {
        didSet { if (parked == nil) != (oldValue == nil) { placeLevel() } }
    }
    /// Out a little further while the pointer rests on the lip.
    private var peeking = false
    /// A peek the bench asked for, with no pointer there to keep it out.
    private var benchPeek = false
    /// What is left out, and takes every press and gesture while it is.
    private var lip: FloatLip? {
        didSet { if oldValue !== lip { oldValue?.removeFromSuperview() } }
    }
    /// Nothing under a call's chevron, as under a video's
    /// (docs/call-window.md, "At the edge").
    private let lipMarks = FloatEdgeTab.Marks()
    private var tabHeight: CGFloat { FloatEdgeTab.height(for: lipMarks) }
    private var tuckFraction: CGFloat = 0
    private var tuckSide: FloatPark.Side?
    private var tuckMask: CAShapeLayer?
    private var glideTuckFrom: CGFloat = 0
    private var glideTuckTo: CGFloat = 0
    /// What is left out past the edge, a video's and a call's alike: the
    /// tab, all but its last 4 points.
    private var lipWidth: CGFloat { FloatEdgeTab.shown }
    /// Coming out from behind the side rather than going: the picture
    /// clears in another order than it frosted (`TuckLook`).
    private var tuckOut = false
    /// How the picture looks part of the way behind a side, tuned frame by
    /// frame at 240 fps. `p` is how far the window has gone, nought out, one tucked; on
    /// the park spring (`progress`) 0.1 s in is 0.17 of the way.
    ///
    /// Going, from the moment it is let go: the buttons go in the first
    /// 0.1 s, the picture blurs over 0.37 s, the grey comes over it from
    /// 0.12 s to 0.57 s, and the tab comes out of the strip's side between
    /// 0.2 s and 0.35 s. Coming out the grey lifts first and the tab goes
    /// back into the strip, the blur clears from a fifth of the way to
    /// seven tenths, so a hand drawing it out sees it clear as it comes.
    struct TuckLook: Equatable {
        var controls: CGFloat
        var blur: CGFloat
        var dark: CGFloat
        /// The chevron.
        var tab: CGFloat
        /// How far the strip's side has gone in past the tab's root, nought
        /// to one of the tab.
        var reach: CGFloat

        /// Safari's grey over the blur: what is left is 0.358 of the picture
        /// and 33 of 255 of grey.
        static let darkest: CGFloat = 0.642

        static func at(_ p: CGFloat, out: Bool) -> TuckLook {
            func ramp(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
                let t = min(1, max(0, (x - from) / (to - from)))
                return t * t * (3 - 2 * t)
            }
            let p = min(1, max(0, p))
            if !out {
                // The times above on the park spring: 0.1 s is 0.17 of the
                // way, 0.12 s 0.23, 0.2 s 0.44, 0.35 s 0.74, 0.37 s 0.77,
                // 0.57 s 0.93.
                return TuckLook(controls: 1 - ramp(p, 0, 0.17), blur: ramp(p, 0, 0.77),
                                dark: darkest * ramp(p, 0.23, 0.93), tab: ramp(p, 0.44, 0.74),
                                reach: ramp(p, 0.44, 0.74))
            }
            let q = 1 - p
            return TuckLook(controls: p <= 0 ? 1 : 0, blur: 1 - ramp(q, 0.2, 0.7),
                            dark: darkest * (1 - ramp(q, 0, 0.3)), tab: 1 - ramp(q, 0, 0.2),
                            reach: 1 - ramp(q, 0, 0.2))
        }
    }

    /// Mask the presentation, never resize or hide the live WebKit host.
    private func presentTuck(_ fraction: CGFloat) {
        guard let panel, let ground = panel.contentView, let side = tuckSide else { return }
        tuckFraction = min(1, max(0, fraction))
        let p = tuckFraction
        let look = TuckLook.at(p, out: tuckOut)
        let full = ground.bounds
        let tab = trayRect ?? FloatEdgeTab.tabFrame(in: full, side: side, height: tabHeight)
        let inset = look.reach * FloatEdgeTab.visible
        var body = full
        body.size.width -= inset
        if side == .right { body.origin.x += inset }
        // Tucked all the way, only the tab is drawn, and what a peek or the
        // tray can bring out: the rest of the window is past the edge,
        // but a Space sliding in shows what is past the edge, and it showed
        // the picture there for a moment.
        if p >= 1 {
            let room = FloatEdgeTab.nudge + 3 + Floater.corner
            if body.width > room {
                if side == .left { body.origin.x = body.maxX - room }
                body.size.width = room
            }
        }
        // A call's tray out: the window stays behind the side and only the
        // tray shows, the tab grown out to it. The body starts past what is
        // out, behind the edge, so the tray keeps its own height.
        if let tray = trayRect, p >= 1 {
            let past = tray.width - (FloatEdgeTab.width - FloatEdgeTab.visible) + 2
            body = full
            body.size.width = max(1, full.width - past)
            if side == .right { body.origin.x = full.minX + past }
        }
        // The strip and the tab one shape, one picture under one blur and
        // grey: the tab comes and goes by the strip's side moving over it
        // (`reach`).
        let tabbed = look.reach > 0
        let shape = FloatEdgeTab.outline(body: body, tab: tabbed ? tab : nil, side: side, in: full,
                                         corner: Floater.corner, radius: trayRect.map { EdgeTray.radius(height: $0.height) } ?? FloatEdgeTab.radius)
        let mask = tuckMask ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = full
        mask.path = shape
        mask.fillColor = NSColor.white.cgColor
        ground.layer?.mask = p > 0 ? mask : nil
        (ground as? Ground)?.clipRect = p > 0 ? shape.boundingBoxOfPath : nil
        frost?.show(blur: p > 0 ? look.blur : 0, dark: p > 0 ? look.dark : 0)
        blurPicture(p > 0 ? look.blur : 0)
        controls?.alphaValue = look.controls
        captions?.alphaValue = look.controls
        call?.alphaValue = look.controls
        // The buttons' view is the hand's: hidden under a hand that took
        // the window behind the side and still holds it, it could lose the
        // rest of the drag. Faded out, and hidden once let go.
        let away = p >= 1
        controls?.isHidden = away && controls?.busy != true
        captions?.isHidden = p >= 1
        call?.isHidden = away && call?.busy != true
        // With the tray out, its own chevron is the one at the edge.
        lip?.edgeAlpha = trayRect == nil ? look.tab : 0
        CATransaction.commit()
        tuckMask = mask
        // The window's shadow is the shape it has, tucked too: it keeps its
        // shadow and the hairline AppKit rings it with.
        if !panel.hasShadow { panel.hasShadow = true }
        panel.invalidateShadow()
        // A carry can reveal the entire picture before the hand lets go.
        // Keep its original responder attached until the gesture ends.
        if p == 0, parked == nil, lip?.interacting != true {
            lip = nil
            tuckSide = nil
            tuckMask = nil
            tuckOut = false
            controls?.refreshPointer()
            call?.refreshPointer()
            if controls?.playing == false { controls?.wake() }
        }
    }

    /// The picture itself under a Gaussian blur, nought to one of Safari's
    /// 12 points, its edges held so they don't darken: what is out past the
    /// side is the window's edge.
    private var pictureBlur: CGFloat = 0
    private func blurPicture(_ amount: CGFloat) {
        // In twelfths: a new filter each frame of the glide held the render
        // server up, and a twelfth of 12 points of blur is not seen.
        let amount = (min(1, max(0, amount)) * 12).rounded() / 12
        guard let view = lens ?? page, amount != pictureBlur else { return }
        pictureBlur = amount
        view.wantsLayer = true
        guard amount > 0 else {
            view.layer?.filters = nil
            return
        }
        view.layerUsesCoreImageFilters = true
        let gauss = CIFilter(name: "CIGaussianBlur")
        gauss?.setValue(Frost.sigma * amount, forKey: kCIInputRadiusKey)
        // The edges held (so what is out past the side doesn't darken) only
        // at rest: the clamp has no render-server path and is redrawn by
        // Core Image, too slow to do every step of the way.
        guard amount >= 1 else {
            view.layer?.filters = [gauss].compactMap { $0 }
            return
        }
        let clamp = CIFilter(name: "CIAffineClamp")
        clamp?.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
        view.layer?.filters = [clamp, gauss].compactMap { $0 }
    }

    /// A held window follows the hand; its look follows the position.
    /// Only releasing it starts an independent settling animation.
    private func carry(_ hand: NSRect) -> Bool {
        guard panel != nil else { return false }
        stopGlide()
        parked = nil
        return false
    }

    private func travel(_ hand: NSRect) {
        if let progress = FloatPark.tuckProgress(hand, in: Floater.screens, lipWidth: lipWidth, snapToEdges: snapsToEdges) {
            if tuckSide != progress.side || lip == nil { prepareTuck(progress.side) }
            tuckOut = false
            presentTuck(progress.fraction)
        } else if tuckSide != nil {
            presentTuck(0)
        }
    }

    private func carryReveal() {
        guard let panel, let side = tuckSide else { return }
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        let hidden = FloatPark.parked(panel.frame, side, in: area, lipWidth: lipWidth)
        let shown = FloatPark.unparked(panel.frame, side, in: area, snapToEdges: snapsToEdges)
        let span = shown.x - hidden.x
        guard abs(span) > 0 else { return }
        presentTuck(1 - (panel.frame.minX - hidden.x) / span)
    }

    private static var screens: [FloatPark.Screen] {
        NSScreen.screens.map { .init(frame: $0.frame, visible: $0.visibleFrame) }
    }

    /// A removed display or a moved Dock cannot leave the restore tab out
    /// of reach. Refit against the live topology, without touching the page.
    private func screensChanged() {
        let screens = Floater.screens
        if DebugLog.pip { DebugLog.screens() }
        guard screens != screenLayout else { return }
        screenLayout = screens
        guard let panel, let screen = FloatPark.screen(for: panel.frame, in: screens) else { return }
        stopGlide()
        var frame = panel.frame
        let area = screen.visible
        if frame.width > area.width || frame.height > area.height {
            frame = Floater.fitted(frame, to: frame.width / max(1, frame.height), in: area)
        }
        if let side = parked, FloatPark.outer(side, of: screen, for: frame, in: Floater.screens) {
            frame.origin = FloatPark.parked(frame, side, in: area, lipWidth: lipWidth)
            panel.setFrame(frame, display: false)
            peeking = false
            benchPeek = false
            tuckOut = false
            presentTuck(1)
        } else {
            unhide()
            frame.origin = snapsToEdges ? FloatPark.nearest(frame, in: area) : FloatPark.bounded(frame, in: area)
            panel.setFrame(frame, display: false)
        }
    }

    /// A drag has put the window down on the pointer's display: tucked,
    /// snapped to a corner, or left at its free position.
    func letGo(at pointer: NSPoint? = nil) {
        guard let panel else { return }
        let frame = panel.frame
        let outcome = FloatPark.settle(frame, pointer: pointer, in: Floater.screens, snapToEdges: snapsToEdges)
        if DebugLog.pip {
            DebugLog.note("letgo", ["p": pointer.map(DebugLog.point) ?? [], "f": DebugLog.rect(frame), "to": "\(outcome)"])
        }
        switch outcome {
        case .park(let side, let spot): park(side, at: spot)
        case .inside(let spot):
            // Carried wholly out from behind a side: done with the lip now.
            if tuckSide != nil, tuckFraction == 0 { presentTuck(0) }
            glide(to: spot, .inside)
        case .stay where frame.origin != panel.frame.origin: glide(to: frame.origin, .inside)
        case .stay: if tuckSide != nil { presentTuck(0) }
        }
    }

    /// A second outward swipe from an edge hides the window at that edge.
    private func tuck(_ side: FloatPark.Side) {
        if DebugLog.pip { DebugLog.note("tuck", ["side": side.rawValue]) }
        guard let panel, parked == nil else { return }
        let screens = Floater.screens
        guard let screen = FloatPark.screen(for: panel.frame, in: screens),
              FloatPark.outer(side, of: screen, for: panel.frame, in: screens)
        else { return }
        park(side, at: FloatPark.parked(panel.frame, side, in: screen.visible))
    }

    private func park(_ side: FloatPark.Side, at spot: NSPoint) {
        guard let panel else { return }
        parked = side
        peeking = false
        tuckOut = false
        // Nothing but the lip at the edge: a button half on the screen would
        // be a button half pressed, and words across it a sliver of each.
        controls?.stopWatching()
        controls?.fade(to: 0, over: 0.12)
        call?.stopWatching()
        call?.fade(to: 0, over: 0.12)
        prepareTuck(side)
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible
        let target = area.map { FloatPark.parked(panel.frame, side, in: $0, lipWidth: lipWidth) } ?? spot
        if DebugLog.pip { DebugLog.note("park", ["side": side.rawValue, "f": DebugLog.rect(panel.frame), "to": DebugLog.point(target)]) }
        glide(to: target, .park)
    }

    /// Build the edge's presentation without starting its motion.
    private func prepareTuck(_ side: FloatPark.Side) {
        guard let panel, let ground = panel.contentView else { return }
        tuckSide = side
        let lip = self.lip ?? FloatLip(frame: ground.bounds)
        lip.autoresizingMask = [.width, .height]
        lip.side = side
        lip.compact = true
        lip.edgeAlpha = tuckFraction
        lip.marks = lipMarks
        lip.label = kind == .call ? "Restore call" : "Restore video"
        lip.lit = false
        lip.onHover = { [weak self] on in self?.hover(on) }
        lip.onClick = { [weak self] in self?.untuck() }
        lip.onBegin = { [weak self] in
            self?.hovering?.cancel()
            self?.hovering = nil
            self?.stopGlide()
            self?.peeking = false
        }
        lip.onCarry = { [weak self] in
            self?.stopGlide()
            self?.unhide(animated: true)
        }
        lip.onTravel = { [weak self] in self?.carryReveal() }
        lip.onLetGo = { [weak self] in self?.letGo() }
        lip.onAway = { [weak self] in
            guard let self else { return }
            // Fully pulled out already: release the original responder
            // now and settle like a normal carry. A partial pull restores.
            if self.parked == nil, self.tuckFraction == 0 { self.letGo() }
            else { self.untuck() }
        }
        lip.onSlide = { [weak self] up in self?.slide(up: up) }
        if lip.superview !== ground { ground.addSubview(lip) }
        self.lip = lip
    }

    /// Two fingers up or down on a video's tab: along the same edge to the
    /// top or the bottom of the screen, still tucked, on the same spring.
    private func slide(up: Bool) {
        guard let panel, let side = parked, let ground = panel.contentView else { return }
        // The screen the tab is on: the window is nearly all past its edge,
        // and by its frame alone could be read as on another display.
        let tab = FloatEdgeTab.tabFrame(in: ground.bounds, side: side, height: tabHeight).offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let mark = NSPoint(x: side == .right ? tab.minX + 1 : tab.maxX - 1, y: tab.midY)
        guard let area = NSScreen.screens.first(where: { $0.frame.contains(mark) })?.visibleFrame
            ?? FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible else { return }
        let y = up ? area.maxY - FloatPark.margin - panel.frame.height : area.minY + FloatPark.margin
        var spot = FloatPark.parked(panel.frame, side, in: area, lipWidth: lipWidth)
        spot.y = max(area.minY, min(y, area.maxY - panel.frame.height))
        hovering?.cancel()
        peeking = false
        lip?.lit = false
        glide(to: spot, .park)
    }

    /// No longer tucked, where it is: carried out by hand.
    private func unhide(animated: Bool = false) {
        guard parked != nil || tuckSide != nil else { return }
        hovering?.cancel()
        hovering = nil
        parked = nil
        peeking = false
        benchPeek = false
        tuckOut = true
        controls?.isHidden = false
        call?.isHidden = false
        captions?.isHidden = false
        if !animated { presentTuck(0) }
    }

    /// Out again on the same side and at the same height.
    func untuck() {
        // An inward swipe can interrupt the return glide after `parked`
        // has cleared; its release must still finish that same reveal.
        guard let side = parked ?? tuckSide else { return }
        if DebugLog.pip { DebugLog.note("untuck", ["side": side.rawValue]) }
        dropTray()
        let spot = dockSpot(side)
        unhide(animated: true)
        glide(to: spot, .back)
        // A stopped video shows its buttons, as ever.
        if controls?.playing == false { controls?.wake() }
    }

    /// The strip and tab's shape now, mid-animation too: what a change of
    /// it starts from.
    private var shapeNow: CGPath? {
        tuckMask?.presentation()?.path ?? tuckMask?.path
    }

    /// From the shape it had to the one it has now: the window's mask.
    private func reshape(from was: CGPath?, over duration: CFTimeInterval,
                         _ timing: CAMediaTimingFunction, key: String) {
        guard let mask = tuckMask, let old = was else { return }
        let change = CABasicAnimation(keyPath: "path")
        change.fromValue = old
        change.toValue = mask.path
        change.duration = duration
        change.timingFunction = timing
        mask.add(change, forKey: key)
    }

    // MARK: - a tucked call's tray

    // Tucked, a call still says what wants you, at its edge
    // (papers/family-values-motion): the tab is the one surface,
    // grown out from the edge into a tray for someone asking to come in, a
    // message, a hand, and taken back into it; the chevron stays where it
    // is at the screen's edge. Who talks is light along the tab's inner
    // side, a reaction is the chevron for a moment. No marks are added.

    /// The tray's rect in the window while it is out: the mask's shape.
    private var trayRect: NSRect?
    private var tray: EdgeTray?
    private var trayQueue: [EdgeTray.Item] = []
    private var trayTimer: Timer?
    /// Names already brought to the edge, so a knock is said once.
    private var edgeSeen: Set<String> = []
    /// Someone still waits after the tray went back: the tab stays out a
    /// little and knocks every eight seconds.
    private var knocking = false
    private var knockTimer: Timer?

    /// The one asking to come in, for a knock the pointer opens again.
    private var waitingItem: EdgeTray.Item?

    private func edge(_ news: CallNews) {
        guard parked != nil, kind == .call else {
            edgeSeen = Set(news.waiting.map(\.name))
            return
        }
        lip?.light(talking: news.talking, hand: news.handsUp)
        for event in news.events {
            switch event {
            case .react(_, let emoji): lip?.flash(emoji)
            case .message(let name, let words, let face): trayQueue.append(.message(name: name, words: words, face: face))
            case .hand(let name, let face): trayQueue.append(.hand(name: name, face: face))
            }
        }
        let names = Set(news.waiting.map(\.name))
        waitingItem = news.waiting.first.map { .join(name: $0.name, face: $0.face, others: news.waiting.count - 1) }
        if let knock = waitingItem, !names.subtracting(edgeSeen).isEmpty {
            trayQueue.removeAll { if case .join = $0 { return true } else { return false } }
            // Someone asking to come in comes first, in the tray as it is.
            if tray != nil { return showInTray(knock, then: names) }
            trayQueue.insert(knock, at: 0)
        }
        edgeSeen = names
        if names.isEmpty, case .join = tray?.item, tray?.replying != true, tray?.letIn != true { advance() }
        if tray == nil, !trayQueue.isEmpty { openTray(trayQueue.removeFirst()) }
        knock(!names.isEmpty && tray == nil)
    }

    private func showInTray(_ item: EdgeTray.Item, then names: Set<String>) {
        edgeSeen = names
        knock(false)
        if case .join = tray?.item {} else if let shown = tray?.item, tray?.replying != true { trayQueue.insert(shown, at: 0) }
        change(to: item)
    }

    /// The tray's rect in the window: out from the tab's place by its
    /// width, the first line where the tab's middle is, growing down.
    private func trayFrame(_ item: EdgeTray.Item, open: Bool, in bounds: NSRect, side: FloatPark.Side) -> NSRect {
        let size = EdgeTray.size(of: item, open: open)
        let tab = FloatEdgeTab.tabFrame(in: bounds, side: side, height: tabHeight)
        let across = size.width + (FloatEdgeTab.width - FloatEdgeTab.visible)
        let top = tab.midY + EdgeTray.compact / 2
        return NSRect(x: side == .right ? tab.minX : tab.maxX - across, y: top - size.height,
                      width: across, height: size.height)
    }

    /// How much further out than tucked the window comes for the tray in
    /// `rect`: all of the tray past the edge, where the tab shows only
    /// `lipWidth`.
    private func trayOut(_ rect: NSRect) -> CGFloat {
        rect.width - (FloatEdgeTab.width - FloatEdgeTab.visible) - lipWidth
    }

    private func openTray(_ item: EdgeTray.Item, open: Bool = false) {
        guard let panel, let ground = panel.contentView, let side = parked else { return }
        if tray != nil { return change(to: item, open: open) }
        knock(false)
        let rect = trayFrame(item, open: open, in: ground.bounds, side: side)
        let tray = EdgeTray(frame: rect)
        tray.side = side
        tray.show(item)
        tray.open = open
        tray.onAdmit = { [weak self, weak tray] in
            guard let self, let tray, case .join(let name, _, let others)? = tray.item else { return }
            self.onCallAsk?(.admit(others > 0 ? nil : name))
            tray.admitted()
            self.resize(open: false)
            // "joined" long enough to be read, then what comes next.
            self.hold(1.2)
        }
        tray.onDeny = { [weak self, weak tray] in
            guard let self, let tray, case .join(let name, _, _)? = tray.item else { return }
            self.onCallAsk?(.deny(name))
            self.advance()
        }
        tray.onOpen = { [weak self] in self?.untuck() }
        tray.onHover = { [weak self, weak tray] on in
            guard let self, let tray, !tray.replying else { return }
            self.resize(open: on)
            if !on { self.hold(1) }
        }
        tray.onReplying = { [weak self] in
            self?.trayTimer?.invalidate()
            self?.panel?.makeKey()
        }
        tray.onSend = { [weak self, weak tray] words in
            guard let self else { return }
            self.onCallAsk?(.send(words))
            tray?.endReply()
            self.resize(open: false)
            self.hold(0.3)
        }
        ground.addSubview(tray)
        self.tray = tray
        // The tab's shape grows into the tray's as the window comes out by
        // the tray's width: from the edge, the chevron where it was.
        let was = shapeNow
        trayRect = rect
        lip?.edgeAlpha = 0
        presentTuck(tuckFraction)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduce { reshape(from: was, over: 0.24, CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1), key: "tray") }
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        glide(to: FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: trayOut(rect)), .peek)
        // The words a beat after the shape, from the edge's side.
        tray.alphaValue = reduce ? 1 : 0
        if !reduce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak tray] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    tray?.animator().alphaValue = 1
                }
            }
        }
        hold(Self.holdTime(item))
    }

    /// A message four seconds, a hand three, a knock six.
    private static func holdTime(_ item: EdgeTray.Item) -> TimeInterval {
        switch item { case .join: return 6; case .message: return 4; case .hand: return 3 }
    }

    /// Next after `seconds`, unless the pointer is on it or a reply is
    /// being written.
    private func hold(_ seconds: TimeInterval) {
        trayTimer?.invalidate()
        trayTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tray = self.tray, let panel = self.panel else { return }
                let at = tray.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                if tray.replying || tray.bounds.contains(at) { return self.hold(1) }
                self.advance()
            }
        }
    }

    /// The next thing waiting, in the same tray, or back into the tab.
    private func advance() {
        if !trayQueue.isEmpty { return change(to: trayQueue.removeFirst()) }
        closeTray()
    }

    /// One tray from one thing to the next: the shape takes the new size
    /// in a step, the words cross where they are.
    private func change(to item: EdgeTray.Item, open: Bool = false) {
        guard let tray else { return openTray(item, open: open) }
        tray.endReply()
        tray.show(item)
        resize(open: open, item: item)
        hold(Self.holdTime(item))
    }

    /// The tray's shape to its size for `open`, in one step.
    private func resize(open: Bool, item: EdgeTray.Item? = nil) {
        guard let tray, let panel, let ground = panel.contentView, let side = parked,
              let item = item ?? tray.item else { return }
        let rect = trayFrame(item, open: open && item.opens, in: ground.bounds, side: side)
        tray.open = open && item.opens
        guard rect != trayRect else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let was = shapeNow
        trayRect = rect
        presentTuck(tuckFraction)
        let step = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        if !reduce { reshape(from: was, over: 0.22, step, key: "tray") }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.22
            context.timingFunction = step
            tray.animator().frame = rect
        }
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        glide(to: FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: trayOut(rect)), .peek)
    }

    /// Back into the tab, quicker than it came: the words first, then the
    /// shape and the window together.
    private func closeTray() {
        trayTimer?.invalidate()
        trayTimer = nil
        guard let tray, let panel, let side = parked else { return dropTray() }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.08
            tray.animator().alphaValue = 0
        }
        let was = shapeNow
        trayRect = nil
        presentTuck(tuckFraction)
        if !reduce { reshape(from: was, over: 0.16, CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1), key: "tray") }
        lip?.edgeAlpha = 1
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        glide(to: FloatPark.parked(panel.frame, side, in: area, lipWidth: lipWidth), .peek)
        self.tray = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.18)) { [weak self, weak tray] in
            tray?.removeFromSuperview()
            guard let self, self.tray == nil else { return }
            if !self.edgeSeen.isEmpty { self.knock(true) }
            if !self.trayQueue.isEmpty { self.openTray(self.trayQueue.removeFirst()) }
        }
    }

    /// The tray gone at once: the window is coming out.
    private func dropTray() {
        trayTimer?.invalidate()
        trayTimer = nil
        tray?.removeFromSuperview()
        tray = nil
        trayRect = nil
        trayQueue = []
        knock(false)
        lip?.edgeAlpha = tuckFraction
    }

    /// Someone waits and nobody answered: out by the nudge's 6 points, and
    /// two quick knocks every eight seconds, until they are let in or go.
    /// The pointer on it brings the tray back with Deny and Admit.
    private func knock(_ on: Bool) {
        guard on != knocking else { return }
        knocking = on
        knockTimer?.invalidate()
        knockTimer = nil
        guard let panel, let side = parked else { return }
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        guard on else {
            if tray == nil { glide(to: FloatPark.parked(panel.frame, side, in: area, lipWidth: lipWidth), .peek) }
            return
        }
        glide(to: FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: FloatEdgeTab.nudge), .nudge)
        knockTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.knockTwice() }
        }
    }

    private func knockTwice() {
        guard knocking, let panel, let side = parked else { return }
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        let out = FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: FloatEdgeTab.nudge)
        let knocked = FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: FloatEdgeTab.nudge + 3)
        for (delay, spot) in [(0.0, knocked), (0.11, out), (0.22, knocked), (0.33, out)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.knocking, self.tray == nil else { return }
                self.glide(to: spot, .nudge)
            }
        }
    }

    /// For the bench: the tray at the edge.
    var trayBench: [String: Any] { tray?.benchState ?? [:] }

    /// The nearest visible position for a tucked window.
    private func dockSpot(_ side: FloatPark.Side) -> NSPoint {
        guard let panel else { return .zero }
        let screens = Floater.screens
        let frame = panel.frame
        let area = FloatPark.screen(for: frame, in: screens)?.visible ?? frame
        return FloatPark.unparked(frame, side, in: area, snapToEdges: snapsToEdges)
    }

    /// The pointer on the lip, or off it, as the tracking area says. The
    /// window moves under a still pointer as it peeks, and AppKit then says
    /// it left and came back, which sent it in and out and in: an exit
    /// counts only with the pointer really outside. And a pointer passing
    /// along the screen's edge, to the Dock or another display, doesn't
    /// bring it out: it has to rest a tenth of a second.
    private var hovering: DispatchWorkItem?

    private func hover(_ on: Bool) {
        // A peek the bench holds out has no pointer on it to leave; the
        // tray, out, is its own.
        guard let panel, parked != nil, !benchPeek, tray == nil else { return }
        if knocking {
            if on, let waiting = waitingItem { openTray(waiting, open: true) }
            return
        }
        hovering?.cancel()
        hovering = nil
        // The pointer on it lights the chevron and nothing moves, as
        // Safari's: no peek out under the pointer.
        _ = panel
        guard on || !pointerOn() else { return }
        lip?.lit = on
    }

    private func peek(_ on: Bool) {
        guard let panel, let side = parked, on != peeking else { return }
        peeking = on
        let area = FloatPark.screen(for: panel.frame, in: Floater.screens)?.visible ?? panel.frame
        let spot = on ? FloatPark.peeked(panel.frame, side, in: area, lipWidth: lipWidth, by: FloatEdgeTab.nudge)
            : FloatPark.parked(panel.frame, side, in: area, lipWidth: lipWidth)
        glide(to: spot, .nudge)
    }

    /// The pointer on what is out: a video's tab, or a call's window.
    private func pointerOn() -> Bool {
        guard let panel else { return false }
        guard let ground = panel.contentView, let side = tuckSide else {
            return panel.frame.contains(NSEvent.mouseLocation)
        }
        let tab = FloatEdgeTab.tabFrame(in: ground.bounds, side: side, height: tabHeight)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        return tab.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    /// Where the window is, or, tucked away, where it will come back to:
    /// what is kept for the next time. Nil when that's where it is.
    private var resting: NSRect? {
        guard let panel, let side = parked else { return nil }
        return NSRect(origin: dockSpot(side), size: panel.frame.size)
    }

    // MARK: - gliding

    /// A frame at a time off the display's own refresh, 120 a second on a
    /// ProMotion screen, each placed for when it will be on the screen and
    /// on whole pixels. Out of hiding and back in from an edge on a
    /// critically damped spring; into hiding and peeking out, eased to a
    /// stop, going quicker than coming back (papers/family-values-motion).
    enum Motion { case park, back, peek, inside, nudge }

    /// How far along a glide of this kind is `t` seconds in, and whether
    /// it is over.
    ///
    /// Safari's picture in picture moves on one spring going behind a side
    /// and back out: critically damped, ω ≈ 7.5 (half the way in 0.22 s,
    /// 0.8 in 0.4 s, still by about 0.8 s), read off a 240 fps recording
    /// frame by frame.
    static func progress(_ kind: Motion, _ t: CGFloat) -> (CGFloat, Bool) {
        func spring(_ omega: CGFloat, over end: CGFloat) -> (CGFloat, Bool) {
            t >= end ? (1, true) : (1 - (1 + omega * t) * exp(-omega * t), false)
        }
        func eased(over end: CGFloat) -> (CGFloat, Bool) {
            t >= end ? (1, true) : (1 - pow(1 - t / end, 3), false)
        }
        switch kind {
        case .park, .back: return spring(7.5, over: 1.4)
        case .inside: return spring(26, over: 0.4)
        case .peek: return eased(over: 0.15)
        // A video's tab under the pointer: out and a touch past, back, still
        // by 0.3 s, a tug that says it can be pulled.
        case .nudge:
            guard t < 0.3 else { return (1, true) }
            let zeta: CGFloat = 0.8, omega: CGFloat = 32
            let damped = omega * sqrt(1 - zeta * zeta)
            let decay = exp(-zeta * omega * t)
            return (1 - decay * (cos(damped * t) + zeta / sqrt(1 - zeta * zeta) * sin(damped * t)), false)
        }
    }

    private var glider: Glider?
    /// Frames drawn in the last glide, for the bench.
    private(set) var lastGlide: [String: Any] = [:]

    private func glide(to target: NSPoint, _ kind: Motion) {
        guard let panel, let ground = panel.contentView else { return }
        stopGlide()
        glideTuckFrom = tuckFraction
        glideTuckTo = kind == .park ? 1 : (kind == .peek || kind == .nudge ? tuckFraction : 0)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(target)
            presentTuck(glideTuckTo)
            return
        }
        let glider = Glider(from: panel.frame.origin, to: target, kind: kind)
        if DebugLog.pip {
            DebugLog.note("glide", ["kind": "\(kind)", "from": DebugLog.point(panel.frame.origin), "to": DebugLog.point(target),
                                    "look": [Double(glideTuckFrom), Double(glideTuckTo)]])
        }
        glider.step = { [weak self] link in self?.glideStep(link) ?? true }
        glider.start(on: ground)
        self.glider = glider
    }

    /// One frame; true once it is over.
    private func glideStep(_ link: CADisplayLink) -> Bool {
        guard let panel, let g = glider else { return true }
        g.frames += 1
        if DebugLog.pip { g.count(link) }
        var (p, done) = Floater.progress(g.kind, CGFloat(link.targetTimestamp - g.start))
        // A spring's tail runs on under half a pixel from where it ends:
        // nothing to draw, so it ends there.
        let scale = panel.backingScaleFactor
        let span = max(abs(g.to.x - g.from.x), abs(g.to.y - g.from.y))
        let visualSpan = max(span, abs(glideTuckTo - glideTuckFrom) * panel.frame.height)
        // A nudge passes its place on purpose: it runs its whole time.
        if g.kind != .nudge, (1 - p) * visualSpan * scale < 0.5 { (p, done) = (1, true) }
        let spot = NSPoint(
            x: ((g.from.x + (g.to.x - g.from.x) * p) * scale).rounded() / scale,
            y: ((g.from.y + (g.to.y - g.from.y) * p) * scale).rounded() / scale
        )
        if spot != panel.frame.origin { panel.setFrameOrigin(spot) }
        let fraction = g.kind == .park
            ? FloatPark.tuckProgress(panel.frame, in: Floater.screens, lipWidth: lipWidth, snapToEdges: snapsToEdges)?.fraction
            : nil
        presentTuck(fraction ?? (glideTuckFrom + (glideTuckTo - glideTuckFrom) * p))
        if done {
            lastGlide = ["kind": "\(g.kind)", "frames": g.frames, "ms": ((CACurrentMediaTime() - g.start) * 1000).rounded()]
            if DebugLog.pip {
                DebugLog.note("glided", ["kind": "\(g.kind)", "frames": g.frames, "ms": DebugLog.ms(CACurrentMediaTime() - g.start),
                                         "worst_ms": DebugLog.ms(g.worst), "late": g.late,
                                         "frame_ms": DebugLog.ms(link.targetTimestamp - link.timestamp),
                                         "f": DebugLog.rect(panel.frame), "tucked": parked?.rawValue ?? "",
                                         "look": Double(tuckFraction)])
            }
            stopGlide(interrupted: false)
            // Out on a peek with the pointer gone meanwhile: back in.
            if g.kind == .peek || g.kind == .nudge, peeking, !benchPeek, !pointerOn() {
                lip?.lit = false
                peek(false)
            }
        }
        return done
    }

    private func stopGlide(interrupted: Bool = true) {
        if let glider, interrupted, DebugLog.pip {
            DebugLog.note("glide-cut", ["kind": "\(glider.kind)", "frames": glider.frames,
                                        "ms": DebugLog.ms(CACurrentMediaTime() - glider.start), "worst_ms": DebugLog.ms(glider.worst),
                                        "late": glider.late, "frame_ms": DebugLog.ms(glider.frameInterval),
                                        "f": DebugLog.rect(panel?.frame ?? .zero)])
        }
        glider?.stop()
        glider = nil
    }

    // MARK: - bench

    /// How often the page in the window has been made another size, each
    /// one a relayout of the whole page in WebKit.
    var resizes: Int { (panel?.contentView as? Ground)?.resizes ?? 0 }

    /// What `./bench float` reads, and the pointer and keys it hands the
    /// window: made-up events given straight to it, never the real pointer,
    /// which belongs to someone using the Mac. Points are the window's own,
    /// from its bottom left.
    func bench(_ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        let settle = { (after: Double) in
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? after)) {
                answer(self.benchState())
            }
        }
        // Tucking, for a video and a call alike.
        if let panel {
            let x = request["x"] as? Double ?? 0, y = request["y"] as? Double ?? 0
            let press = { (type: NSEvent.EventType) in
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
                )
            }
            switch request["action"] as? String ?? "state" {
            case "place":
                // The window's origin carried to (x, y) and let go.
                stopGlide()
                if parked != nil { unhide() }
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                letGo()
                return settle(0.3)
            case "tuck":
                // Most of the way past the right edge, as a drag would leave it:
                // a right edge with no screen past it, the one the window is on
                // or, on a Mac with screens side by side (the farm's test
                // screens), the last of the row, where a window tucks.
                let here = (panel.screen ?? NSScreen.main)?.frame ?? panel.frame
                let beside = { (screen: CGRect) in
                    NSScreen.screens.contains { abs($0.frame.minX - screen.maxX) < 1 && $0.frame.minY < screen.maxY && $0.frame.maxY > screen.minY }
                }
                var area = here
                while beside(area), let next = NSScreen.screens.first(where: { abs($0.frame.minX - area.maxX) < 1 && $0.frame.minY < area.maxY && $0.frame.maxY > area.minY }) {
                    area = next.frame
                }
                stopGlide()
                let y = min(max(panel.frame.minY, area.minY), area.maxY - panel.frame.height)
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width * 0.3, y: y))
                letGo()
                return settle(0.4)
            case "untuck":
                untuck()
                return settle(0.4)
            case "carry":
                // The hand carrying the window's origin to (x, y), the
                // button still down; "letgo" puts it down, the pointer at
                // (px, py) when given, as a mouse lets go.
                let hand = NSRect(origin: NSPoint(x: x, y: y), size: panel.frame.size)
                if !carry(hand) { panel.setFrameOrigin(hand.origin) }
                travel(panel.frame)
                return settle(0.05)
            case "letgo":
                letGo(at: (request["px"] as? Double).map { NSPoint(x: $0, y: request["py"] as? Double ?? 0) })
                return settle(0.3)
            case "tap" where parked != nil, "click" where parked != nil:
                // Pressed and let go on the lip, handed straight to it: the
                // window doesn't become key, so nothing typed on this Mac
                // meanwhile goes to it.
                if let lip, let down = press(.leftMouseDown), let up = press(.leftMouseUp) {
                    lip.mouseDown(with: down)
                    lip.mouseUp(with: up)
                }
                return settle(0.3)
            case "flick" where parked != nil:
                // Two fingers flicked away from the side it is behind.
                let way = x
                if parked == .right ? way < 0 : way > 0 { untuck() }
                return settle(0.4)
            // A tucked call's tray: the pointer on it or off it, a press on
            // Admit or Deny, Reply with words sent from the edge.
            case "tray-enter" where tray != nil, "tray-exit" where tray != nil:
                let on = request["action"] as? String == "tray-enter"
                tray?.lit = on
                resize(open: on)
                if !on { hold(1) }
                return settle(0.4)
            case "tray-enter" where knocking:
                if let waiting = waitingItem { openTray(waiting, open: true) }
                return settle(0.4)
            case "tray-admit", "tray-deny", "tray-reply":
                let action = String((request["action"] as? String ?? "").dropFirst(5))
                tray?.bench(action, words: request["button"] as? String ?? "")
                return settle(0.4)
            case "enter" where parked != nil:
                benchPeek = true
                lip?.lit = true
                peek(true)
                return settle(0.3)
            case "exit" where parked != nil:
                benchPeek = false
                lip?.lit = false
                peek(false)
                return settle(0.3)
            default: break
            }
        }
        if let panel, call != nil {
            switch request["action"] as? String ?? "state" {
            case "press": pressCall(request["button"] as? String ?? "")
            // A click on the picture at (x, y), from the top left: a message
            // there opens the chat's field.
            case "tap": call?.tapped(NSPoint(x: request["x"] as? Double ?? 0, y: (call?.bounds.height ?? 0) - (request["y"] as? Double ?? 0)))
            // Words typed into the chat's field and sent, as Return would.
            case "reply": call?.benchReply(request["button"] as? String ?? "")
            // The buttons up, as the pointer brings them, or away.
            case "near": call?.poke()
            case "away": call?.fade(to: 0, over: 0)
            case "flick":
                // Two fingers flicked this way (x, y), as the video's window.
                call?.flick(CGVector(dx: request["x"] as? Double ?? 0, dy: request["y"] as? Double ?? 0))
            case "shape":
                // The call's window at this width and height (x, y), any shape
                // within the limits, its top right corner kept.
                let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
                let corner = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
                panel.setFrame(FloatHand.freely(NSSize(width: request["x"] as? Double ?? 352, height: request["y"] as? Double ?? 198),
                                                around: corner, in: area), display: false)
            case "width":
                // The call's window at this width, its shape kept.
                let wide = max(panel.minSize.width, request["x"] as? Double ?? panel.frame.width)
                let tall = wide * panel.frame.height / panel.frame.width
                panel.setFrame(NSRect(x: panel.frame.maxX - wide, y: panel.frame.minY, width: wide, height: tall), display: false)
            // For a screenshot of it, a call's window being kept out of them;
            // and deaf to the real pointer, which belongs to whoever is at
            // the Mac, while a probe is driving it.
            case "shareable":
                panel.sharingType = .readOnly
                panel.ignoresMouseEvents = true
            default: break
            }
            return DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 0.4)) {
                answer(self.benchState())
            }
        }
        guard let panel, let controls else { return answer(["error": "no floating window"]) }
        let x = request["x"] as? Double ?? 0, y = request["y"] as? Double ?? 0
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint, count: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: at, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        switch request["action"] as? String ?? "state" {
        case "enter":
            if let event = NSEvent.enterExitEvent(
                with: .mouseEntered, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ) { controls.mouseEntered(with: event) }
        case "exit":
            // Probes have no real pointer: leaving an idle window is
            // explicit, while a carry's tracking exit can still be inside.
            if !controls.busy { controls.benchHover(false) }
            if let event = NSEvent.enterExitEvent(
                with: .mouseExited, location: NSPoint(x: -50, y: -50), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ) { controls.mouseExited(with: event) }
        case "move":
            if let event = mouse(.mouseMoved, NSPoint(x: x, y: y)) { controls.mouseMoved(with: event) }
        case "width":
            // The window at this width, its shape kept, as a pinch leaves it.
            let wide = max(panel.minSize.width, x)
            let tall = wide * panel.frame.height / panel.frame.width
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: wide, height: tall), display: false)
        case "clock":
            return answer(["clock": Controls.Scrubber.clock(x)])
        case "flick":
            // Two fingers flicked this way (x, y), flicks on or not.
            controls.flick(CGVector(dx: x, dy: y))
        case "hit":
            let view = panel.contentView?.superview?.hitTest(NSPoint(x: x, y: y))
            return answer(["hit": view.map { "\(type(of: $0))" } ?? "nothing"])
        case "click":
            // The up first, in the queue: a button's press waits for it.
            // "nth": one press only, counted as that press of a run.
            let at = NSPoint(x: x, y: y), count = request["count"] as? Int ?? 1
            let nth = request["nth"] as? Bool ?? false
            for n in (nth ? count : 1)...count {
                if let up = mouse(.leftMouseUp, at, count: n) { NSApp.postEvent(up, atStart: false) }
                if let down = mouse(.leftMouseDown, at, count: n) { panel.sendEvent(down) }
            }
        case "drag":
            // Down, a step every frame to (x2, y2), up.
            let from = NSPoint(x: x, y: y)
            let to = NSPoint(x: request["x2"] as? Double ?? x, y: request["y2"] as? Double ?? y)
            let steps = max(1, request["steps"] as? Int ?? 30)
            if let down = mouse(.leftMouseDown, from) { panel.sendEvent(down) }
            // When each step came: a main thread held up shows as a gap.
            var times = [CACurrentMediaTime()]
            let spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            func step(_ n: Int) {
                times.append(CACurrentMediaTime())
                let t = CGFloat(n) / CGFloat(steps)
                let at = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                if n < steps {
                    if let drag = mouse(.leftMouseDragged, at) { panel.sendEvent(drag) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    if let up = mouse(.leftMouseUp, at) { panel.sendEvent(up) }
                    let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
                    let took = ((times.last ?? 0) - (times.first ?? 0)) * 1000
                    let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - spent) / 1e6
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        answer(self.benchState().merging([
                            "drag_ms": took.rounded(), "worst_step_ms": (gaps.max() ?? 0).rounded(),
                            "drag_cpu_ms": (cpu * 10).rounded() / 10,
                        ]) { a, _ in a })
                    }
                }
            }
            step(1)
            return
        case "hold":
            // Down, and dragged to (x2, y2), still held: the bar as it is
            // mid-drag, its tip up. "release" lets go there.
            let to = NSPoint(x: request["x2"] as? Double ?? x, y: request["y2"] as? Double ?? y)
            if let down = mouse(.leftMouseDown, NSPoint(x: x, y: y)) { panel.sendEvent(down) }
            if let drag = mouse(.leftMouseDragged, to) { panel.sendEvent(drag) }
            benchHeld = to
        case "stall", "unstall":
            // Test runs only: the video held up, as fetching holds it, or
            // moving again.
            benchStall = Store.testing && request["action"] as? String == "stall"
        case "fail", "unfail":
            // Test runs only: the video failed, as a lost network fails it.
            benchFail = Store.testing && request["action"] as? String == "fail"
        case "menu":
            // The right-click menu as it would open: titles and ticks.
            let items = (pictureMenu()?.items ?? []).filter { !$0.isSeparatorItem }
            return answer(["items": items.map { ["title": $0.title, "on": $0.state == .on] }])
        case "top":
            // Keep on Top, as the menu sets it: x 1 on, 0 off.
            keepOnTop((request["x"] as? Double ?? 1) != 0)
        case "snap":
            snapToEdges((request["x"] as? Double ?? 1) != 0)
        case "release":
            if let up = mouse(.leftMouseUp, benchHeld ?? NSPoint(x: x, y: y)) { panel.sendEvent(up) }
            benchHeld = nil
        case "speed":
            // As the speed menu would: x is the speed.
            controls.benchRate(request["x"] as? Double ?? 1)
        case "subtitle":
            // As the subtitles menu would: x is the track, -1 off.
            controls.benchSubtitle((request["x"] as? NSNumber)?.intValue ?? -1)
        case "key", "appkey":
            // "appkey" goes through the app's own event queue, past its key
            // watcher, as a key pressed on the window would.
            let keys: [String: (UInt16, String)] = [
                "space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
                "escape": (53, "\u{1B}"), "return": (36, "\r"),
                "c": (8, "c"), "comma": (43, ","), "period": (47, "."),
            ]
            guard let (code, chars) = keys[request["key"] as? String ?? ""],
                  let event = NSEvent.keyEvent(
                      with: .keyDown, location: .zero, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                      context: nil, characters: chars, charactersIgnoringModifiers: chars,
                      isARepeat: request["repeat"] as? Bool ?? false, keyCode: code
                  )
            else { return answer(["error": "key is space, left, right, escape, return, c, comma or period"]) }
            if request["action"] as? String == "appkey" {
                NSApp.postEvent(event, atStart: false)
            } else {
                controls.keyDown(with: event)
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (request["settle"] as? Double ?? 0.3)) {
            answer(self.benchState())
        }
    }

    private func benchState() -> [String: Any] {
        if let panel, let call {
            let frame = panel.frame
            return call.benchState().merging([
                "showing": true, "kind": "call", "window": panel.windowNumber,
                "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
                "key": panel.isKeyWindow, "tray": trayBench, "knocking": knocking,
            ]) { a, _ in a }.merging(tuckState) { a, _ in a }
        }
        guard let panel, let controls else { return ["showing": false] }
        let frame = panel.frame
        // The page's own size, and what of it the lens shows, in the page's
        // points: the part the window is made of.
        let pageSize: [Double] = page.map { [Double($0.frame.width), Double($0.frame.height)] } ?? []
        let shown: [Double] = lens.map { lens -> [Double] in
            let b = lens.bounds
            return [Double(b.minX), Double(b.minY), Double(b.width), Double(b.height)]
        } ?? []
        return controls.benchState().merging([
            "showing": true,
            "window": panel.windowNumber,
            "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
            "aspect": Double(panel.aspectRatio.width / max(1, panel.aspectRatio.height)),
            "resizes": resizes,
            "page": pageSize,
            "lens": shown,
            "key": panel.isKeyWindow,
            "level": panel.level.rawValue, "on_top": keepsOnTop,
            "snap_to_edges": snapsToEdges,
            "in_cycle": panel.collectionBehavior.contains(.participatesInCycle),
            "seeks": ["rough": sent.rough, "exact": sent.exact],
            "captions_text": captions?.text ?? "",
            "captions_hidden": captions?.isHidden == true || tuckFraction > 0.99,
        ]) { a, _ in a }.merging(tuckState) { a, _ in a }
    }

    private var tuckState: [String: Any] {
        let look = TuckLook.at(tuckFraction, out: tuckOut)
        return [
            "parked": parked?.rawValue ?? "", "tucked": parked != nil, "lip": lip != nil,
            "lip_glyph": lip?.glyph ?? "",
            "lip_marks": lip.map { $0.marks.shown.map(\.symbol) } ?? [], "lip_lit": lip?.lit ?? false, "lip_budded": lip?.budded ?? 0, "lip_turn_us": lip?.turnCost ?? 0,
            "peeking": peeking, "home": parked.map { _ in [Double(resting?.minX ?? 0), Double(resting?.minY ?? 0)] } ?? [],
            "gliding": glider != nil, "last_glide": lastGlide,
            "tuck_fraction": Double(tuckFraction),
            "tuck_look": [look.controls, look.blur, look.dark, look.tab, look.reach].map { Double($0) },
            "edge_tab_alpha": Double(lip?.edgeAlpha ?? 0),
            "occlusion_visible": panel?.occlusionState.contains(.visible) ?? false,
            "lip_ax_role": lip?.axRole ?? "",
            "lip_ax_label": lip?.axLabel ?? "",
            "lip_rect": lip.map { view in
                let r = view.tabRect
                return [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            } ?? [],
            "clip_rect": (panel?.contentView as? Ground)?.clipRect.map { r in [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] } ?? [],
        ]
    }

    /// What a small window of video needs, and nothing else: a way out, a way
    /// back, a way to stop it, a way to step over the bit you missed, and a
    /// bar to go anywhere in it.
    ///
    /// Out of sight until the pointer moves over the window, and up while
    /// it stays anywhere on the picture or its controls.
    private final class Controls: FloatHand {
        var onPlayPause: (() -> Void)?
        var onSkip: ((Double) -> Void)?
        var onMute: (() -> Void)?
        var onSeek: ((Double, Bool) -> Void)?
        var onRate: ((Double) -> Void)?
        /// Subtitles off (-1) or that track on.
        var onSubtitle: ((Int) -> Void)?
        var onRetry: (() -> Void)?
        /// The window's right-click menu (`Floater.pictureMenu`).
        var menuFor: (() -> NSMenu?)?

        /// The video held up, as the window says it (`Floater.Hold`): the
        /// spinner in the pause button, words under it, or the failure.
        var wait: Floater.Hold.Look = .none {
            didSet { if wait != oldValue { showWait() } }
        }
        private var spinning: Bool { wait == .waiting || wait == .slow }
        private var failed: Bool { if case .failed = wait { return true } else { return false } }

        /// The speed the video plays at, in words on its button: "1×",
        /// light once it isn't 1.
        var rate: Double = 1 {
            didSet { if abs(rate - oldValue) > 0.001 { showRate() } }
        }
        /// What the video offers; nil until the page has said.
        var subtitles: Floater.Subtitles? {
            didSet { if subtitles != oldValue { showSubtitles() } }
        }
        /// Words were drawn from this video's page.
        var heard = false {
            didSet { if heard != oldValue { showSubtitles() } }
        }
        /// For a page with no tracks: its words drawn or not.
        var wordsShown = true {
            didSet { if wordsShown != oldValue { showSubtitles() } }
        }
        /// The track last turned on here, for C to bring back.
        private var lastTrack: Int?
        private var live = false {
            didSet { if live != oldValue { showRate() } }
        }

        var playing = true {
            didSet {
                guard playing != oldValue else { return }
                playMark.set(!playing, now: window?.isVisible != true)
                pause.setAccessibilityLabel(playing ? "Pause" : "Play")
                // Paused or played, the buttons come up, and go again as
                // ever: paused, the picture is left bare.
                poke()
            }
        }

        private let close = FloatButton()
        /// Beside the close button, in its stroke: the window goes, the
        /// video plays on in its tab and the island takes it.
        private let minimize = FloatButton()
        var onMinimize: (() -> Void)?
        private let back = FloatButton()
        private let pause = FloatButton()
        private let rewind = FloatButton()
        private let forward = FloatButton()
        private let sound = FloatButton()
        /// Left of the sound, as the call's: the speed in words, then the
        /// subtitles' bubble, the call's own.
        private let speed = FloatButton()
        private let words = FloatButton()
        private var glass: [ObjectIdentifier: FloatGlass] = [:]
        private lazy var playMark = Turn(on: pause, "pause.fill", "play.fill", size: 20)
        private lazy var waitMark = WaitMark(on: pause)
        /// Under the spinner once a wait is long.
        private let slowWords = NSTextField(labelWithString: "Slow connection")
        /// Over the picture when the video can't play: what happened, and
        /// a way to try again, in the middle where play was.
        private let failure = CALayer()
        private let failTitle = NSTextField(labelWithString: "Can\u{2019}t play this video")
        private let failWhy = NSTextField(labelWithString: "")
        private let retry = FloatButton()
        private lazy var backMark = SkipMark(on: rewind, forward: false, size: 16)
        private lazy var forwardMark = SkipMark(on: forward, forward: true, size: 16)
        /// The bar's own glass, a capsule along the bottom with the times
        /// in it, as the system's picture in picture has it.
        private let bar = FloatGlass.media(cornerRadius: 13) // design: a capsule, half its 26 pt height
        private lazy var speaker = SpeakerMark(on: sound, size: 12)
        /// Whether the page's sound can be silenced from here, and is.
        private var muted: Bool? {
            didSet { if muted != oldValue { showSound(now: oldValue == nil || window?.isVisible != true) } }
        }
        /// How far a run of presses has gone, over the button pressed, once
        /// it is more than one: "−30", "+45".
        private let tally = NSView()
        private let tallyWords = NSTextField(labelWithString: "")
        private var run: (way: Double, seconds: Double, at: CFTimeInterval)?
        private var tallyGoes: Timer?
        private let scrubber = Scrubber()
        /// What else goes on in a live stream, where a title's second line
        /// would be: "Ad · muted" while an advert plays inside it,
        /// "Catching up…" while it waits at its edge (LiveEdge.subtitle).
        private let note = NSTextField(labelWithString: "")
        /// The video's chapters, for the bar.
        var chapters: [Floater.Chapter] {
            get { scrubber.chapters }
            set { scrubber.chapters = newValue }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            dress(close, "xmark", 11, round: 14, action: #selector(pressedClose))
            dress(minimize, "minus", 11, round: 14, action: #selector(pressedMinimize))
            dress(back, "pip.exit", 12, round: 14, action: #selector(pressedReturn))
            dress(rewind, "gobackward.15", 16, round: 19, action: #selector(pressedRewind))
            dress(pause, "pause.fill", 20, round: 26, action: #selector(pressedPause))
            dress(forward, "goforward.15", 16, round: 19, action: #selector(pressedForward))
            dress(sound, "speaker.wave.2.fill", 12, round: 14, action: #selector(pressedSound))
            dress(speed, "xmark", 12, round: 14, action: #selector(pressedSpeed))
            speed.image = nil
            speed.imagePosition = .noImage
            dress(words, "captions.bubble", 15, round: 14, action: #selector(pressedWords))
            dress(retry, "xmark", 12, round: 13, action: #selector(pressedRetry))
            retry.image = nil
            retry.imagePosition = .noImage
            retry.attributedTitle = NSAttributedString(string: "Try Again", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            retry.isHidden = true
            surface(retry).isHidden = true
            speed.keyTip("Slower\t<\nFaster\t>", side: .above)
            words.keyTip("Subtitles\tC", side: .above)
            showRate()
            showSubtitles()
            // Drawn by their marks, which move.
            for button in [pause, rewind, forward, sound] { button.image = nil }
            playMark.set(false, now: true)
            _ = (backMark, forwardMark)
            sound.isHidden = true
            close.setAccessibilityLabel("Close and pause")
            back.setAccessibilityLabel("Return video to tab and continue playing")
            close.keyTip("Close and pause", side: .above)
            minimize.setAccessibilityLabel("Minimize and keep playing")
            minimize.keyTip("Minimize and keep playing", side: .above)
            back.keyTip("Return to tab and continue playing", side: .above)
            rewind.setAccessibilityLabel("Back 15 seconds")
            forward.setAccessibilityLabel("Forward 15 seconds")
            pause.setAccessibilityLabel("Pause")

            tallyWords.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            tallyWords.textColor = .white
            tallyWords.alignment = .center
            tally.addSubview(tallyWords)
            tally.wantsLayer = true
            tally.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.55).cgColor
            tally.layer?.cornerRadius = 6
            tally.alphaValue = 0
            addSubview(tally)
            note.font = .systemFont(ofSize: 12, weight: .semibold)
            note.textColor = .white
            note.lineBreakMode = .byTruncatingTail
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            note.shadow = shadow
            addSubview(note)
            for (label, size, weight, alpha) in [(slowWords, 12.0, NSFont.Weight.semibold, 1.0), (failTitle, 13, .semibold, 1), (failWhy, 11.5, .medium, 0.72)] {
                label.font = .systemFont(ofSize: size, weight: weight)
                label.textColor = NSColor(white: 1, alpha: alpha)
                label.alignment = .center
                label.lineBreakMode = .byTruncatingTail
                label.shadow = shadow
                label.isHidden = true
                addSubview(label)
            }
            failure.backgroundColor = NSColor.black.cgColor
            failure.opacity = 0.45
            failure.isHidden = true
            failure.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.insertSublayer(failure, at: 0)

            scrubber.onSeek = { [weak self] through, exact in
                self?.onSeek?(through, exact)
                if exact { self?.poke() }
            }
            addSubview(bar)
            addSubview(scrubber)
            faded.forEach { $0.alphaValue = 0 }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var buttons: [NSButton] {
            (muted == nil ? [close, minimize, back, rewind, pause, forward] : [close, minimize, back, sound, rewind, pause, forward])
                + [speed, words].filter { !$0.isHidden }
        }
        /// Paused or playing, every button goes with the pointer and leaves
        /// the bare picture. Held up,
        /// the pause button stays, its spinner turning.
        override var faded: [NSView] { (spinning ? buttons.filter { $0 !== pause } : buttons).map { surface($0) } + [bar, scrubber, note] }
        override var pressable: [NSView] { buttons }
        override func reach(_ point: NSPoint) -> NSView? {
            scrubber.canSeek && scrubber.frame.insetBy(dx: 0, dy: -4).contains(point) ? scrubber : nil
        }
        override var engaged: Bool { scrubber.dragging }
        override var staysOnHover: Bool { true }
        override func didFade(_ up: Bool) {
            guard !up else { return }
            endRun()
            scrubber.hovered = false
            scrubber.park()
        }

        /// 52 across, in the middle; it never changes size.
        private func placePause() {
            let side: CGFloat = 52
            place(pause, at: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
            playMark.layout()
        }

        /// Out of sight, a click only brings the buttons up; the spinner
        /// left on a held video is the one thing it presses.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            if spinning, !isHidden, box(pause).insetBy(dx: 5, dy: 5).contains(inside), !atCorner(inside) {
                return pause
            }
            if failed, !isHidden, box(retry).contains(inside) { return retry }
            return super.hitTest(point)
        }
        /// Twice, anywhere but a button or the corner: play or pause, as in
        /// every player.
        override func doubleClicked() { pressedPause() }

        /// A held arrow goes on stepping; a held Space doesn't flicker
        /// between play and pause.
        override func key(_ event: NSEvent, once: Bool) -> Bool {
            switch event.keyCode {
            case 123: pressedRewind()
            case 124: pressedForward()
            case 49: if once { pressedPause() }
            // M, as the layout types it (Hotkey.readings).
            case _ where Hotkey(event)?.key == "m":
                if once, muted != nil { pressedSound() }
            // < and >, as YouTube's, and the same keys without ⇧; C for
            // subtitles. By place too, on a layout that types no ASCII there.
            case _ where Self.reads(event, [",", "<"], at: 43): if once { step(-1) }
            case _ where Self.reads(event, [".", ">"], at: 47): if once { step(1) }
            case _ where Self.reads(event, ["c"], at: 8): if once { toggleSubtitles() }
            default: return false
            }
            return true
        }

        private func dress(
            _ button: NSButton,
            _ symbol: String,
            _ size: CGFloat,
            round: CGFloat,
            action: Selector
        ) {
            button.image = glyph(symbol, size)
            button.contentTintColor = .white
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.wantsLayer = true
            button.layer?.cornerRadius = round
            // The glass is outside the button. Shadow only its white marks
            // so fine rewind strokes remain readable over bright video.
            button.layer?.shadowColor = NSColor.black.cgColor
            button.layer?.shadowOpacity = 0.55
            button.layer?.shadowRadius = 1
            button.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
            let material = FloatGlass.media(cornerRadius: round)
            material.content.addSubview(button)
            glass[ObjectIdentifier(button)] = material
            addSubview(material)
        }

        private func surface(_ button: NSButton) -> NSView { glass[ObjectIdentifier(button)] ?? button }
        private func box(_ button: NSButton) -> NSRect { convert(button.bounds, from: button) }
        private func place(_ button: NSButton, at frame: NSRect) {
            guard let material = glass[ObjectIdentifier(button)] else { button.frame = frame; return }
            material.frame = frame
            material.cornerRadius = frame.height / 2
            button.frame = NSRect(origin: .zero, size: frame.size)
        }

        private func glyph(_ name: String, _ size: CGFloat) -> NSImage? {
            Glyphs.image(name, size: size)
        }

        /// Where the video is, drawn while the buttons show. Out of sight,
        /// nothing is drawn: the bar's run is stopped too, so a hidden bar
        /// costs the render server nothing either.
        func show(_ head: Floater.Playhead) {
            playing = head.playing
            live = head.live != nil
            // An advert is run fast by the blocker (YouTube.swift); that
            // speed isn't the video's.
            if !head.ad, head.rate > 0 { rate = head.rate }
            if near { scrubber.show(head) } else { scrubber.park() }
            // A live stream: 15 seconds on only when behind, back only
            // where it keeps a stretch; dimmed and deaf otherwise.
            able(rewind, backMark, scrubber.rewindable)
            able(forward, forwardMark, scrubber.forwardable)
            let said = scrubber.isLive
                ? LiveEdge.subtitle(ad: head.ad, muted: head.muted, waiting: head.waiting, atEdge: scrubber.held) ?? "" : ""
            if note.stringValue != said {
                note.stringValue = said
                placeNote()
            }
        }

        /// Along the top, right of the close and minimize buttons and short
        /// of the ones on the right, as wide as its words, at once as they
        /// change.
        private func placeNote() {
            let size = note.intrinsicContentSize
            let end = row.map { box($0).minX }.min().map { $0 - 8 } ?? box(back).minX - 8
            let wide = ceil(size.width) + 4
            let start = box(minimize).maxX + 10
            note.frame = NSRect(x: start, y: (box(close).midY - size.height / 2).rounded(),
                                width: max(0, min(wide, end - start)), height: size.height)
        }

        private func able(_ button: FloatButton, _ mark: SkipMark, _ on: Bool) {
            guard button.isEnabled != on else { return }
            button.isEnabled = on
            mark.dim(!on)
        }

        /// The tab's sound: silenced or not, or nil where Fast can't
        /// silence a page, and the button isn't there.
        func show(muted: Bool?) { self.muted = muted }

        private func showSound(now: Bool) {
            sound.isHidden = muted == nil
            surface(sound).isHidden = muted == nil
            surface(sound).alphaValue = near ? 1 : 0
            guard let muted else { return }
            speaker.set(muted: muted, now: now)
            sound.setAccessibilityLabel(muted ? "Unmute" : "Mute")
        }

        /// A press of back or forward: the arrow turns, and a second press
        /// the same way within a second shows how far the run has gone.
        private func skipped(_ seconds: Double) {
            (seconds < 0 ? backMark : forwardMark).turn()
            let now = CACurrentMediaTime()
            let way = seconds < 0 ? -1.0 : 1.0
            if let run, run.way == way, now - run.at < 1 {
                self.run = (way, run.seconds + abs(seconds), now)
            } else {
                run = (way, abs(seconds), now)
            }
            guard let run, run.seconds > abs(seconds) else { return hideTally() }
            tallyWords.stringValue = (way < 0 ? "\u{2212}" : "+") + String(Int(run.seconds))
            placeTally()
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if tally.alphaValue == 0 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = still ? 0 : 0.12
                    tally.animator().alphaValue = 1
                }
            } else if !still {
                // Each step further, the plate bumps: 1.25 at a third of
                // the way and back, so a held arrow reads as counting.
                bump(tally)
            }
            tallyGoes?.invalidate()
            tallyGoes = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.endRun() }
            }
        }

        private func bump(_ view: NSView) {
            guard let layer = view.layer else { return }
            let w = view.bounds.width / 2, h = view.bounds.height / 2
            func scaled(_ factor: CGFloat) -> NSValue {
                var t = CATransform3DMakeTranslation(w, h, 0)
                t = CATransform3DScale(t, factor, factor, 1)
                return NSValue(caTransform3D: CATransform3DTranslate(t, -w, -h, 0))
            }
            let pop = CAKeyframeAnimation(keyPath: "transform")
            pop.values = [scaled(1), scaled(1.25), scaled(1)]
            pop.keyTimes = [0, 0.35, 1]
            pop.timingFunctions = [markCurve, markCurve]
            pop.duration = 0.24
            layer.add(pop, forKey: "bump")
        }

        private func endRun() {
            run = nil
            tallyGoes?.invalidate()
            tallyGoes = nil
            hideTally()
        }

        private func hideTally() {
            guard tally.alphaValue > 0 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                tally.animator().alphaValue = 0
            }
        }

        /// Over the button of the run, its middle the button's.
        private func placeTally() {
            guard let run else { return }
            let over = run.way < 0 ? rewind : forward
            let size = tallyWords.intrinsicContentSize
            let across = (size.width + 12).rounded(), tall: CGFloat = 18
            tally.frame = NSRect(x: (box(over).midX - across / 2).rounded(), y: box(over).maxY + 6, width: across, height: tall)
            tallyWords.frame = NSRect(x: 0, y: ((tall - size.height) / 2).rounded(), width: across, height: size.height)
        }

        override func layout() {
            super.layout()
            // As the system's picture in picture lays them out: the corners'
            // buttons 28 across, 6 in; play 52 and the steps 38 either side
            // of it, 61 between middles; the bar a capsule 26 high, 6 in.
            place(close, at: NSRect(x: 6, y: bounds.height - 34, width: 28, height: 28))
            // Minimize beside it, 6 apart, as the row on the right.
            place(minimize, at: NSRect(x: 40, y: bounds.height - 34, width: 28, height: 28))
            place(back, at: NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 28, height: 28))

            let middle = (bounds.midY - 26).rounded()
            place(pause, at: NSRect(x: (bounds.midX - 26).rounded(), y: middle, width: 52, height: 52))
            place(rewind, at: NSRect(x: (bounds.midX - 61 - 19).rounded(), y: middle + 7, width: 38, height: 38))
            place(forward, at: NSRect(x: (bounds.midX + 61 - 19).rounded(), y: middle + 7, width: 38, height: 38))
            placeWait()
            // Leftward from the way back to the tab, as the call's: the
            // sound, the subtitles, the speed, 6 apart.
            reveal(speed, !live && bounds.width >= 240)
            var edge = box(back).minX
            for button in row.dropFirst() {
                let wide = button === speed ? speedWidth : 28
                edge -= 6 + wide
                place(button, at: NSRect(x: edge, y: bounds.height - 34, width: wide, height: 28))
            }
            playMark.layout()
            waitMark.layout()
            backMark.layout()
            forwardMark.layout()
            speaker.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            placePause()
            CATransaction.commit()
            placeTally()

            placeNote()

            // Along the bottom, in its capsule.
            bar.frame = NSRect(x: 6, y: 6, width: max(0, bounds.width - 12), height: 26)
            bar.cornerRadius = 13
            scrubber.frame = NSRect(x: 16, y: 9, width: max(0, bounds.width - 32), height: 20)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let at = convert(event.locationInWindow, from: nil)
            scrubber.hovered = near && scrubber.frame.insetBy(dx: 0, dy: -4).contains(at)
            scrubber.point(scrubber.hovered ? at.x - scrubber.frame.minX : nil, option: event.modifierFlags.contains(.option))
        }

        override func mouseExited(with event: NSEvent) {
            guard !pointerIsInside else { return }
            scrubber.hovered = false
            super.mouseExited(with: event)
        }

        func benchState() -> [String: Any] {
            scrubber.benchState().merging([
                "near": near, "shown": Double(surface(close).alphaValue), "playing": playing,
                "glass_native": glass.values.allSatisfy { $0.usesLiquidGlass },
                "glass_class": glass.values.first?.usesLiquidGlass == true ? "NSGlassEffectView" : "NSVisualEffectView",
                "button_frames": Dictionary(uniqueKeysWithValues: [("close", close), ("minimize", minimize), ("return", back), ("pause", pause), ("rewind", rewind), ("forward", forward), ("sound", sound)].map { name, button in
                    let r = box(button)
                    return (name, [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)])
                }),
                "muted": muted.map { $0 ? "yes" : "no" } ?? "none", "hovered_buttons": buttons.filter { ($0 as? FloatButton)?.benchLit == true }.count, "tally": tally.alphaValue > 0 ? tallyWords.stringValue : "",
                "first": window?.firstResponder === self, "waiting": waiting,
                "wait": waitName, "spinner": waitMark.running, "pause_alpha": Double(surface(pause).alphaValue),
                "slow_words": !slowWords.isHidden, "fail_words": failure.isHidden ? "" : failTitle.stringValue + " " + failWhy.stringValue,
                "retry_frame": retryFrame,
                "subtitle": note.stringValue, "forward_enabled": forward.isEnabled, "rewind_enabled": rewind.isEnabled,
            ]) { a, _ in a }.merging(benchSpeed()) { a, _ in a }
        }

        @objc private func pressedClose() { onClose?() }
        @objc private func pressedMinimize() { onMinimize?() }
        @objc private func pressedReturn() { onReturn?() }

        /// A right-click anywhere on the window, buttons too: its menu, not
        /// the page's under it.
        override func menu(for event: NSEvent) -> NSMenu? { menuFor?() }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            menuClosed()
        }

        // A press, by button or key, is something happening: the wait for
        // stillness starts over from it.
        // Not at a live stream's edge, or in one that keeps nothing: the
        // arrow keys too (`able`).
        @objc private func pressedRewind() { poke(); guard rewind.isEnabled else { return }; skipped(-15); onSkip?(-15) }
        @objc private func pressedForward() { poke(); guard forward.isEnabled else { return }; skipped(15); onSkip?(15) }
        @objc private func pressedSound() {
            poke()
            onMute?()
        }

        // MARK: Speed and subtitles

        private static func reads(_ event: NSEvent, _ keys: Set<String>, at code: UInt16) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            if Hotkey.readings(event).contains(where: { keys.contains($0.key) }) { return true }
            let typed = event.charactersIgnoringModifiers ?? ""
            return event.keyCode == code && !typed.isEmpty && !typed.unicodeScalars.allSatisfy(\.isASCII)
        }

        /// The buttons along the top right, from the right: back to the
        /// tab, then those shown of sound, subtitles and speed.
        private var row: [NSButton] { [back, sound, words, speed].filter { !$0.isHidden } }

        private static let speeds = Floater.speeds
        private static func said(_ rate: Double) -> String { Floater.said(rate) }

        /// Round at 1×, as wide as its words past that: "1.25×" doesn't fit
        /// in 28.
        private var speedWidth: CGFloat {
            max(28, ceil(speed.attributedTitle.size().width) + 16)
        }

        /// Plain glass at every speed: the words already say it, and light
        /// glass read as a switch turned on.
        private func showRate() {
            // A live stream plays at the edge, and a narrow window has no
            // room: the keys still work.
            let shown = !live && bounds.width >= 240
            speed.attributedTitle = NSAttributedString(string: Self.said(rate), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            speed.setAccessibilityLabel("Speed, \(Self.said(rate))")
            reveal(speed, shown)
            needsLayout = true
        }

        private var subtitlesOn: Bool {
            guard let subtitles, !subtitles.tracks.isEmpty else { return heard && wordsShown }
            return subtitles.now >= 0
        }

        private func showSubtitles() {
            let on = subtitlesOn
            words.contentTintColor = on ? Self.ink : .white
            glass[ObjectIdentifier(words)]?.tintColor = on ? Self.light : nil
            words.setAccessibilityLabel(on ? "Subtitles, on" : "Subtitles, off")
            reveal(words, subtitles?.tracks.isEmpty == false || heard)
            needsLayout = true
        }

        /// In the row or out of it; one coming in takes the others' alpha.
        private func reveal(_ button: NSButton, _ shown: Bool) {
            guard button.isHidden == shown else { return }
            button.isHidden = !shown
            surface(button).isHidden = !shown
            if shown { surface(button).alphaValue = surface(close).alphaValue }
        }

        /// A switch that is on and light, as the call's: dark on white.
        private static let light = NSColor(white: 1, alpha: 0.94)
        private static let ink = NSColor(white: 0.07, alpha: 1)

        @objc private func pressedSpeed() {
            poke()
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: "Speed"))
            for each in Self.speeds {
                let item = NSMenuItem(title: Self.said(each), action: #selector(chose(speed:)), keyEquivalent: "")
                item.target = self
                item.representedObject = each
                item.state = abs(each - rate) < 0.001 ? .on : .off
                menu.addItem(item)
            }
            pop(menu, under: speed)
        }

        @objc private func chose(speed item: NSMenuItem) {
            guard let each = item.representedObject as? Double else { return }
            set(rate: each)
        }

        private func set(rate each: Double) {
            poke()
            rate = each
            onRate?(each)
        }

        /// One step along `speeds`, slower or faster, from where it is.
        private func step(_ way: Int) {
            guard let next = Floater.speed(after: rate, way: way) else { return }
            set(rate: next)
        }

        @objc private func pressedWords() {
            poke()
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: "Subtitles"))
            let off = NSMenuItem(title: "Off", action: #selector(chose(subtitle:)), keyEquivalent: "c")
            off.keyEquivalentModifierMask = []
            off.target = self
            off.tag = -1
            off.state = subtitlesOn ? .off : .on
            menu.addItem(off)
            guard let subtitles, !subtitles.tracks.isEmpty else {
                // Only the page's own words, drawn or not.
                let on = NSMenuItem(title: "On", action: #selector(chose(subtitle:)), keyEquivalent: "")
                on.target = self
                on.tag = 0
                on.state = subtitlesOn ? .on : .off
                menu.addItem(on)
                return pop(menu, under: words)
            }
            func item(_ index: Int) -> NSMenuItem {
                let track = subtitles.tracks[index]
                let made = NSMenuItem(title: track.translated ? "\(track.name) · translated" : track.name,
                                      action: #selector(chose(subtitle:)), keyEquivalent: "")
                made.target = self
                made.tag = index
                made.state = subtitles.now == index ? .on : .off
                return made
            }
            let first = subtitles.first()
            first.forEach { menu.addItem(item($0)) }
            let rest = subtitles.tracks.indices.filter { !first.contains($0) }
            if !rest.isEmpty {
                let more = NSMenuItem(title: "More Languages", action: nil, keyEquivalent: "")
                let list = NSMenu()
                rest.forEach { list.addItem(item($0)) }
                more.submenu = list
                menu.addItem(.separator())
                menu.addItem(more)
            }
            pop(menu, under: words)
        }

        func benchRate(_ each: Double) { set(rate: each) }

        private func benchSpeed() -> [String: Any] {
            let names: [String] = (subtitles?.tracks ?? []).map { $0.translated ? $0.name + " · translated" : $0.name }
            let first: [Int] = subtitles?.first() ?? []
            var out: [String: Any] = ["rate": rate, "speed_shown": !speed.isHidden, "speed_title": speed.attributedTitle.string]
            out["subtitles_shown"] = !words.isHidden
            out["subtitles_on"] = subtitlesOn
            out["subtitle_tracks"] = names
            out["subtitle_now"] = subtitles?.now ?? -1
            out["subtitles_first"] = first
            return out
        }
        func benchSubtitle(_ choice: Int) {
            if choice < 0, !subtitlesOn { return }
            if subtitles?.tracks.isEmpty != false, choice >= 0 { return choose(0) }
            choose(choice)
        }

        @objc private func chose(subtitle item: NSMenuItem) {
            choose(item.tag)
        }

        private func choose(_ choice: Int) {
            poke()
            if choice >= 0 { lastTrack = choice }
            onSubtitle?(choice)
        }

        /// C: off if on; on, the last turned on here or the spoken one's.
        private func toggleSubtitles() {
            guard subtitles?.tracks.isEmpty == false || heard else { return }
            if subtitlesOn { return choose(-1) }
            let tracks = subtitles?.tracks ?? []
            if tracks.isEmpty { return choose(0) }
            let back = lastTrack.flatMap { tracks.indices.contains($0) ? $0 : nil }
            choose(back ?? subtitles?.first().first ?? 0)
        }

        /// Under its button, right edges together, dark as the glass is;
        /// the buttons stay while it is open, their timer waits on the run
        /// loop the menu holds.
        private func pop(_ menu: NSMenu, under button: NSButton) {
            menu.appearance = NSAppearance(named: .darkAqua)
            menu.autoenablesItems = false
            let frame = box(button)
            let at = NSPoint(x: max(6, frame.maxX - menu.size.width), y: frame.minY - 6)
            menu.popUp(positioning: nil, at: at, in: self)
        }
        @objc private func pressedPause() {
            poke()
            playing.toggle()
            onPlayPause?()
        }
        @objc private func pressedRetry() { onRetry?() }

        private var waitName: String {
            switch wait {
            case .none: return "none"
            case .waiting: return "waiting"
            case .slow: return "slow"
            case .failed(let reason): return "failed \(reason)"
            }
        }
        private var retryFrame: [Double] {
            guard !retry.isHidden else { return [] }
            let r = box(retry)
            return [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
        }

        /// The spinner where pause was, words under it once long, or the
        /// failure over the middle. Out of sight, the pause button stays
        /// while it turns, and goes with it.
        private func showWait() {
            let spin = spinning, failed = self.failed
            playMark.veil(spin)
            waitMark.run(spin)
            pause.setAccessibilityValue(spin ? "Loading" : nil)
            slowWords.isHidden = wait != .slow
            var why = ""
            if case .failed(let reason) = wait {
                switch reason {
                case .network: why = "The connection was lost."
                case .decode: why = "The video is damaged."
                case .format: why = "This format isn\u{2019}t supported."
                case .stuck: why = "It stopped loading."
                }
            }
            failWhy.stringValue = why
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            failure.isHidden = !failed
            CATransaction.commit()
            [failTitle, failWhy].forEach { $0.isHidden = !failed }
            retry.isHidden = !failed
            surface(retry).isHidden = !failed
            for button in [rewind, pause, forward] { surface(button).isHidden = failed }
            if !near {
                let shown: CGFloat = spin ? 1 : 0
                if surface(pause).alphaValue != shown {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                        surface(pause).animator().alphaValue = shown
                    }
                }
            }
            needsLayout = true
        }

        /// The words under the pause button; the failure's in the middle,
        /// Try Again under them.
        private func placeWait() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            failure.frame = bounds
            CATransaction.commit()
            let most = max(0, bounds.width - 40)
            let slow = slowWords.intrinsicContentSize
            slowWords.frame = NSRect(x: ((bounds.width - min(most, slow.width + 4)) / 2).rounded(), y: box(pause).minY - 8 - slow.height,
                                     width: min(most, slow.width + 4), height: slow.height)
            let title = failTitle.intrinsicContentSize, why = failWhy.intrinsicContentSize
            let button = NSSize(width: ceil(retry.attributedTitle.size().width) + 26, height: 26)
            let tall = title.height + 3 + why.height + 10 + button.height
            var y = (bounds.midY + tall / 2).rounded()
            y -= title.height
            failTitle.frame = NSRect(x: 20, y: y, width: max(0, bounds.width - 40), height: title.height)
            y -= 3 + why.height
            failWhy.frame = NSRect(x: 20, y: y, width: max(0, bounds.width - 40), height: why.height)
            y -= 10 + button.height
            place(retry, at: NSRect(x: ((bounds.width - button.width) / 2).rounded(), y: y, width: button.width, height: button.height))
        }

        /// The bar along the bottom, how far through, the time gone and the
        /// whole, and a place to click or drag to go anywhere in the video.
        ///
        /// Layers only, above the page and never part of it. Between one
        /// reading of the page and the next the bar runs on the render
        /// server, set going at the rate the video plays: the main thread
        /// touches it when the page says something the run did not already
        /// show, and redraws the time gone once a second, only while it can
        /// be seen.
        final class Scrubber: NSView {
            var onSeek: ((Double, Bool) -> Void)?
            /// The pointer is on the bar: thicker, with a knob.
            var hovered = false {
                didSet { if hovered != oldValue { thicken() } }
            }
            private(set) var dragging = false
            /// A live stream goes only where it keeps something, and one
            /// that doesn't say how far back that is has nowhere to go.
            var canSeek: Bool { hasBar }
            private var hasBar: Bool { length > 0 || stream?.spans == true }
            /// A live stream's stretch, as last read: the bar runs over it,
            /// and where the whole would be the words say Live, or how far
            /// behind (LiveEdge.swift).
            private var stream: LiveEdge.Window?
            /// A live stream is held up, fetching or seeking: no longer
            /// moving on with its edge, through no step of anyone's.
            private var waiting = false
            /// It was at the edge when it last moved: a wait there is still
            /// Live, not a minute behind and counting.
            private(set) var held = false
            /// A line under the words, there while they are the way back to
            /// the edge.
            private let link = CALayer()
            /// The words were the way back when last written: a drag keeps
            /// them, and their line with them, until it is let go.
            private var linked = false

            var isLive: Bool { stream != nil }
            /// Behind, with a way back: the words go to the edge, and 15
            /// seconds on is somewhere to go. Any video has both.
            var goesLive: Bool { stream.map { $0.goesLive && !(waiting && held) } ?? false }
            var forwardable: Bool { stream == nil ? true : goesLive }
            var rewindable: Bool { stream?.spans ?? true }

            /// The video's chapters: the bar in a piece to each, with a
            /// gap between, and the one under the pointer named over it.
            var chapters: [Floater.Chapter] = [] {
                didSet {
                    guard chapters != oldValue else { return }
                    // The piece that was lit may not be there any more.
                    lit = nil
                    needsLayout = true
                }
            }

            /// A piece of the bar to a chapter, each with its own track and
            /// a window onto the one fill: every piece holds a copy of the
            /// fill, all laid and run alike, and shows the part of it that
            /// falls inside it. Clipped to a plain rectangle, which the
            /// render server does as it draws, where a mask cut with the
            /// gaps would be drawn off screen and again every frame the bar
            /// runs.
            private struct Piece {
                let track = CALayer()
                let clip = CALayer()
                /// What the page has fetched, lighter than the track,
                /// under the fill.
                let loaded = CALayer()
                let fill = CALayer()
            }
            private var pieces: [Piece] = []
            /// Where each piece starts and ends along the bar, nought to
            /// one, as last laid.
            private var spans: [(from: Double, to: Double)] = [(0, 1)]
            /// The piece under the pointer, or being dragged through.
            private var lit: Int?
            private let knob = CALayer()
            /// The chapter whose start the pointer or the knob is near
            /// enough to be taken to (`Chapter.snapped`); none with ⌥ held.
            private(set) var snapped: Int?
            /// On the start the pointer would land on, while it is near one.
            private let mark = CALayer()
            /// The stretch the page has fetched around where it plays,
            /// nought to one.
            private var loaded: (from: Double, to: Double)?
            /// The time gone and the whole, drawn from pictures of their
            /// digits: the time gone changes every second it plays and on
            /// every step of a drag (`Clock`).
            private let elapsed = Clock(font: Scrubber.font, alpha: 0.92)
            private let total = Clock(font: Scrubber.font, alpha: 0.62)
            /// Over the pointer on the bar: the chapter's name and the time
            /// at that point.
            private let bubble = CALayer()
            private let bubbleTitle = CATextLayer()
            private let bubbleTime = Clock(font: Scrubber.timeFont, alpha: 0.7)
            private var bubbleSaid = ("", "")
            private var bubbleRoom: CGFloat = 0
            private var bubbleWords: (text: String, width: CGFloat) = ("", 0)
            /// Where the pointer is along the row, while it is on the bar.
            private var pointer: CGFloat?
            private var length: Double = 0
            private var through: Double = 0
            /// What the bar was last set running from, to tell a reading it
            /// already shows from one it doesn't.
            private var run: (through: Double, at: CFTimeInterval, perSecond: Double)?
            private var timeText = ""
            private var lengthText = ""
            /// Room kept for the words on either side of the bar: the two
            /// clocks', the same, or for a live stream none on the left and
            /// the widest of its words on the right.
            private var room: (left: CGFloat, right: CGFloat) = (0, 0)

            private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            private static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            private static let still: [String: CAAction] = [
                "position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                "cornerRadius": NSNull(), "maskedCorners": NSNull(), "opacity": NSNull(),
            ]
            /// Between one chapter's piece and the next.
            private static let gap: CGFloat = 2
            /// A piece narrower than this has no gap of its own and goes in
            /// with the one before: forty chapters in a small window would
            /// be a dotted line.
            private static let narrowest: CGFloat = 4

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true
                knob.backgroundColor = NSColor.white.cgColor
                knob.opacity = 0
                knob.shadowColor = NSColor.black.cgColor
                knob.shadowOpacity = 0.4
                knob.shadowRadius = 1.5
                knob.shadowOffset = CGSize(width: 0, height: -1)
                knob.actions = Scrubber.still
                bubble.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
                bubble.cornerRadius = 7
                bubble.isHidden = true
                bubble.actions = Scrubber.still
                bubbleTitle.alignmentMode = .center
                bubbleTitle.isWrapped = false
                bubbleTitle.foregroundColor = NSColor.white.cgColor
                bubbleTitle.actions = Scrubber.still
                bubble.addSublayer(bubbleTitle)
                bubble.addSublayer(bubbleTime)
                mark.backgroundColor = NSColor.white.cgColor
                mark.cornerRadius = 1
                mark.shadowColor = NSColor.black.cgColor
                mark.shadowOpacity = 0.35
                mark.shadowRadius = 1
                mark.shadowOffset = .zero
                mark.isHidden = true
                mark.actions = Scrubber.still
                ensure(1)
                // Nothing to show until the page says how long the video is:
                // a live stream reports no length, which is the length it
                // starts with, so it would never be told to hide them.
                [knob, elapsed, total].forEach {
                    $0.isHidden = true
                    layer?.addSublayer($0)
                }
                link.backgroundColor = NSColor(white: 1, alpha: 0.45).cgColor
                link.isHidden = true
                link.actions = Scrubber.still
                layer?.addSublayer(link)
                layer?.addSublayer(mark)
                layer?.addSublayer(bubble)
                thicken(animated: false)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError() }

            /// As many pieces as there are to lay, made or put away.
            private func ensure(_ count: Int) {
                while pieces.count < count {
                    let piece = Piece()
                    piece.track.backgroundColor = NSColor(white: 1, alpha: 0.26).cgColor
                    piece.fill.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
                    piece.fill.anchorPoint = CGPoint(x: 0, y: 0.5)
                    piece.loaded.backgroundColor = NSColor(white: 1, alpha: 0.3).cgColor
                    piece.loaded.anchorPoint = CGPoint(x: 0, y: 0.5)
                    piece.clip.masksToBounds = true
                    [piece.track, piece.clip, piece.loaded, piece.fill].forEach { $0.actions = Scrubber.still }
                    piece.clip.addSublayer(piece.loaded)
                    piece.clip.addSublayer(piece.fill)
                    piece.track.isHidden = !hasBar
                    piece.clip.isHidden = !hasBar
                    // Under the knob, which stays on top.
                    layer?.insertSublayer(piece.track, at: UInt32(pieces.count * 2))
                    layer?.insertSublayer(piece.clip, at: UInt32(pieces.count * 2 + 1))
                    pieces.append(piece)
                }
                while pieces.count > count {
                    let piece = pieces.removeLast()
                    piece.track.removeFromSuperlayer()
                    piece.clip.removeFromSuperlayer()
                }
            }

            override func viewDidChangeBackingProperties() {
                super.viewDidChangeBackingProperties()
                let scale = window?.backingScaleFactor ?? 2
                bubbleTitle.contentsScale = scale
                [elapsed, total, bubbleTime].forEach { $0.scale = scale }
            }

            /// "1:24", "2:11:40".
            static func clock(_ seconds: Double) -> String {
                // Clamped before it is made a whole number, which traps past
                // Int.max: a hundred hours is more than any video that isn't
                // a stream, and a stream shows no clock.
                let all = seconds.isFinite ? Int(min(max(seconds, 0), 360_000)) : 0
                let hours = all / 3600, minutes = all / 60 % 60, rest = all % 60
                return hours > 0
                    ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                    : String(format: "%d:%02d", minutes, rest)
            }

            private func say(_ text: String, on label: CATextLayer, in font: NSFont = Scrubber.font) {
                label.string = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: label.foregroundColor.map { NSColor(cgColor: $0) ?? .white } ?? .white,
                ])
            }

            func show(_ head: Floater.Playhead) {
                // An advert inside a live stream: the stream's words and
                // bar stay as they were, the advert's own times are no
                // part of it.
                if head.ad, stream != nil { return }
                if let live = head.live {
                    // A live stream: no clock, its words where the whole
                    // would be, and a bar only over a stretch it keeps.
                    let fresh = stream?.spans != live.spans || length != 0
                    stream = live
                    length = 0
                    waiting = head.waiting
                    if !waiting { held = live.atEdge }
                    if fresh { restyle() }
                    // Dragged, the words keep what they said until it is
                    // let go; the tip over the pointer says where it goes.
                    guard !dragging else { return }
                    word(live.words(waiting: waiting, wasLive: held))
                    if live.spans { place(waiting && held ? 1 : live.through, running: 0) }
                    return
                }
                waiting = false
                held = false
                if stream != nil || length != head.length {
                    stream = nil
                    length = head.length
                    loaded = nil
                    restyle()
                }
                guard !dragging, length > 0 else { return }
                let fetched = head.loaded.map { (from: max(0, $0.from / length), to: min(1, $0.to / length)) }
                if fetched.map({ $0.from }) != loaded.map({ $0.from }) || fetched.map({ $0.to }) != loaded.map({ $0.to }) {
                    loaded = fetched
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layLoaded()
                    CATransaction.commit()
                }
                tell(head.time)
                // Runs only while the picture really moves: a video waiting
                // on the network would otherwise have its bar run ahead of
                // it and snap back.
                let perSecond = head.moving ? head.rate / length : 0
                place(head.through, running: perSecond)
            }

            /// What shows for a new video, or a live stream: a video with no
            /// length, nothing to go to and no clock to read, has no bar,
            /// knob or times at all.
            private func restyle() {
                ([knob] + pieces.flatMap { [$0.track, $0.clip] }).forEach { $0.isHidden = !hasBar }
                elapsed.isHidden = length <= 0
                total.isHidden = length <= 0 && stream == nil
                if !hasBar, dragging { dragging = false }
                if stream != nil {
                    word(stream?.words(waiting: waiting, wasLive: held) ?? "Live", anew: true)
                    return
                }
                let text = length > 0 ? Scrubber.clock(length) : ""
                lengthText = text
                total.show(text)
                // Room for the longer of the two, digits all the same
                // width, so the bar keeps still as the time counts up.
                let widest = (text.isEmpty ? "0:00" : text).replacingOccurrences(of: "[0-9]", with: "0", options: .regularExpression)
                let wide = Scrubber.width(widest)
                room = (wide, wide)
                needsLayout = true
            }

            /// A live stream's words, Live or how far behind, where the
            /// whole would be. The room for them is kept for the widest
            /// in minutes, so the bar keeps still as they change.
            private func word(_ text: String, anew: Bool = false) {
                linked = goesLive
                underline()
                guard anew || text != lengthText else { return }
                lengthText = text
                total.show(text)
                // Against the right edge as drawn now: "45s behind" and
                // "1m behind" are not as wide, and the room may stay.
                total.frame = CGRect(x: bounds.width - total.width, y: total.frame.minY, width: total.width, height: total.frame.height)
                underline()
                let wide = max(Scrubber.width(LiveEdge.widest), Scrubber.width(text))
                if room != (0, wide) {
                    room = (0, wide)
                    needsLayout = true
                } else if anew {
                    needsLayout = true
                }
            }

            /// The line under the words while they are the way back to the
            /// edge: as wide as they are drawn, just under their baseline.
            /// Never hover's to change: it is there or not by where the
            /// stream plays.
            private func underline() {
                let on = linked && stream != nil && !total.isHidden
                link.isHidden = !on
                guard on else { return }
                link.frame = CGRect(x: bounds.width - total.width, y: total.frame.minY + 0.5, width: total.width, height: 1)
            }

            private static func width(_ text: String) -> CGFloat {
                ceil((text as NSString).size(withAttributes: [.font: Scrubber.font]).width)
            }

            /// The time gone, redrawn only when the second it shows changes.
            private func tell(_ seconds: Double) {
                let text = Scrubber.clock(seconds)
                guard text != timeText else { return }
                timeText = text
                elapsed.show(text)
            }

            /// Stops the bar where it is, while nobody can see it.
            func park() {
                guard let run else { return }
                through = min(1, run.through + (CACurrentMediaTime() - run.at) * run.perSecond)
                self.run = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                stop()
                lay()
                CATransaction.commit()
            }

            private func stop() {
                pieces.forEach { $0.fill.removeAnimation(forKey: "run") }
                knob.removeAnimation(forKey: "run")
            }

            private var bar: (x: CGFloat, width: CGFloat) {
                // 8 between the bar and the words on either side of it.
                let x = room.left > 0 ? room.left + 8 : 0
                let right = room.right > 0 ? room.right + 8 : 0
                return (x, max(0, bounds.width - x - right))
            }

            private func place(_ value: Double, running speed: Double) {
                // Under a point a second, a long film in a small window, a
                // run would have the window composited every frame for a
                // bar that visibly moves every few seconds: it is stepped
                // by the readings instead, each a point or so on.
                let perSecond = speed * Double(bar.width) >= 1 ? speed : 0
                let now = CACurrentMediaTime()
                // Already there, near enough: the run shows it, leave it be.
                if let run, run.perSecond == perSecond {
                    let shown = min(1, run.through + (now - run.at) * run.perSecond)
                    if abs(shown - value) * Double(bar.width) < 0.75 { return }
                }
                through = max(0, min(1, value))
                run = (through, now, perSecond)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                stop()
                lay()
                if perSecond > 0, through < 1 {
                    // To the end, at the speed the video goes: a new
                    // reading only corrects it. Only the pieces still to
                    // fill are run; the ones behind are full already.
                    let seconds = (1 - through) / perSecond
                    let (x, width) = bar
                    var runs: [(CALayer, String, CGFloat, CGFloat)] = [(knob, "position.x", x + width * CGFloat(through), x + width)]
                    for (piece, span) in zip(pieces, spans) where span.to > through {
                        runs.append((piece.fill, "bounds.size.width", width * CGFloat(through), width))
                    }
                    for (layer, path, from, to) in runs {
                        let go = CABasicAnimation(keyPath: path)
                        go.fromValue = from
                        go.toValue = to
                        go.duration = seconds
                        go.timingFunction = CAMediaTimingFunction(name: .linear)
                        go.fillMode = .forwards
                        go.isRemovedOnCompletion = false
                        layer.add(go, forKey: "run")
                    }
                }
                CATransaction.commit()
            }

            private var thickness: CGFloat { hovered || dragging ? 5 : 3 }
            /// The piece under the pointer stands out of the rest, as
            /// YouTube's does; with one piece there is nothing to stand
            /// out from.
            private func thickness(of index: Int) -> CGFloat {
                index == lit && (hovered || dragging) && pieces.count > 1 ? 7 : thickness
            }

            /// Where the pieces go along a bar `width` wide: one to a
            /// chapter, a narrow one in with the one before, and the first,
            /// when narrow, in with the next.
            private func cut(_ width: CGFloat) -> [(from: Double, to: Double)] {
                guard chapters.count > 1, length > 0, width > 0 else { return [(0, 1)] }
                var out: [(from: Double, to: Double)] = []
                for (i, chapter) in chapters.enumerated() {
                    let from = chapter.start / length
                    let to = i + 1 < chapters.count ? chapters[i + 1].start / length : 1
                    if !out.isEmpty, CGFloat(to - from) * width < Scrubber.narrowest {
                        out[out.count - 1].to = to
                    } else {
                        out.append((from, to))
                    }
                }
                if out.count > 1, CGFloat(out[0].to - out[0].from) * width < Scrubber.narrowest {
                    out[1].from = 0
                    out.removeFirst()
                }
                return out
            }

            /// Puts every layer where `through` and the thickness say.
            private func lay() {
                let (x, width) = bar
                let mid = bounds.midY
                spans = cut(width)
                ensure(spans.count)
                let t = thickness
                for (i, (piece, span)) in zip(pieces, spans).enumerated() {
                    let own = thickness(of: i)
                    let left = x + width * CGFloat(span.from) + (span.from > 0 ? Scrubber.gap / 2 : 0)
                    let right = x + width * CGFloat(span.to) - (span.to < 1 ? Scrubber.gap / 2 : 0)
                    let frame = CGRect(x: left, y: mid - own / 2, width: max(0, right - left), height: own)
                    piece.track.frame = frame
                    piece.track.cornerRadius = t / 2
                    // Round only at the bar's two ends: inside it, a piece
                    // meets the gap square, as YouTube's do.
                    var corners: CACornerMask = []
                    if span.from <= 0 { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
                    if span.to >= 1 { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
                    piece.track.maskedCorners = corners
                    // The clip's own origin is the bar's start at its
                    // middle, so every copy of the fill lies at the same
                    // point in each, and a thicker piece grows about it.
                    piece.clip.position = CGPoint(x: frame.midX, y: mid)
                    piece.clip.bounds = CGRect(x: left - x, y: -own / 2, width: frame.width, height: own)
                    piece.fill.bounds = CGRect(x: 0, y: 0, width: width * CGFloat(through), height: own)
                    piece.fill.position = .zero
                    piece.fill.cornerRadius = own / 2
                }
                layLoaded()
                let side: CGFloat = dragging ? 13 : 11
                knob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                knob.cornerRadius = side / 2
                knob.shadowPath = CGPath(ellipseIn: knob.bounds, transform: nil)
                knob.position = CGPoint(x: x + width * CGFloat(through), y: mid)
                let line = ceil(Scrubber.font.ascender - Scrubber.font.descender)
                // The digits' middle on the bar's: a line's box sits them
                // high by 2.5 points, which read as a thicker gap under them.
                let words = ((mid - line / 2 - 2.5) * 2).rounded() / 2
                elapsed.frame = CGRect(x: 0, y: words, width: room.left, height: line)
                total.frame = CGRect(x: bounds.width - total.width, y: words, width: total.width, height: line)
                underline()
                placeMark()
                name()
            }

            /// What the page has fetched, in every piece as the fill is, at
            /// the piece's height; nothing for a live stream.
            private func layLoaded() {
                let width = bar.width
                for piece in pieces {
                    let own = piece.clip.bounds.height
                    guard let loaded, stream == nil, loaded.to > loaded.from else {
                        piece.loaded.isHidden = true
                        continue
                    }
                    piece.loaded.isHidden = false
                    piece.loaded.bounds = CGRect(x: 0, y: 0, width: width * CGFloat(loaded.to - loaded.from), height: own)
                    piece.loaded.position = CGPoint(x: width * CGFloat(loaded.from), y: 0)
                    piece.loaded.cornerRadius = own / 2
                }
            }

            /// Only what a drag moves: the fill in every piece, the knob, and
            /// the name over it. The pieces themselves stay where they are.
            private func follow() {
                let (x, width) = bar
                for piece in pieces {
                    piece.fill.bounds.size.width = width * CGFloat(through)
                }
                knob.position.x = x + width * CGFloat(through)
                name()
            }

            /// The piece at a point along the row.
            private func piece(at point: CGFloat) -> Int? {
                let (x, width) = bar
                guard width > 0, spans.count > 1 else { return nil }
                let at = Double((point - x) / width)
                return spans.firstIndex { at < $0.to } ?? spans.count - 1
            }

            /// Where along the bar the name is for: the pointer over it, or
            /// the knob while it is dragged.
            private var named: Double? {
                let (x, width) = bar
                // A live stream's tip is for a drag only: how far behind
                // it would land.
                if stream != nil { return dragging && width > 0 ? through : nil }
                guard chapters.count > 1, width > 0, length > 0 else { return nil }
                if dragging { return through }
                guard hovered, let pointer else { return nil }
                if let snapped, chapters.indices.contains(snapped) { return chapters[snapped].start / length }
                return max(0, min(1, Double((pointer - x) / width)))
            }

            /// The chapter whose start a point along the row is taken to:
            /// none in a live stream, or with ⌥ held, which goes exactly
            /// where it is.
            private func snap(_ at: CGFloat?, option: Bool) -> Int? {
                guard let at, stream == nil, !option, length > 0 else { return nil }
                let (x, width) = bar
                return Floater.Chapter.snapped(chapters, length: length, width: width, at: at - x)
            }

            private func startX(_ index: Int) -> CGFloat {
                bar.x + bar.width * CGFloat(chapters[index].start / length)
            }

            /// The line on the start the pointer would land on: there while
            /// the pointer is near one, not while the knob is held.
            private func placeMark() {
                guard hovered, !dragging, hasBar, let snapped, chapters.indices.contains(snapped) else {
                    mark.isHidden = true
                    return
                }
                mark.frame = CGRect(x: (startX(snapped) * 2).rounded() / 2 - 1, y: bounds.midY - 6.5, width: 2, height: 13)
                mark.isHidden = false
            }

            /// The chapter at that point and the time there, over it.
            /// Drawn anew only when the words change; moved, otherwise.
            private func name() {
                guard let at = named, let host = superview else {
                    bubble.isHidden = true
                    return
                }
                let start = stream == nil ? snapped.flatMap { chapters.indices.contains($0) ? $0 : nil } : nil
                let seconds = start.map { chapters[$0].start } ?? at * length
                let title = stream != nil ? "" : start.map { chapters[$0].title } ?? chapters.last { $0.start <= seconds }?.title ?? ""
                let time = stream?.tip(at: at) ?? Scrubber.clock(seconds)
                let titleLine = ceil(Scrubber.titleFont.ascender - Scrubber.titleFont.descender)
                let timeLine = ceil(Scrubber.timeFont.ascender - Scrubber.timeFont.descender)
                // Never wider than the window leaves room for, and a name
                // that doesn't fit cut short where it runs out.
                let most = min(220, max(40, host.bounds.width - 16)) - 16
                // The name changes at a chapter's edge, the time with nearly
                // every move: each is drawn again only when it changes.
                if bubbleSaid.0 != title || bubbleRoom != most {
                    bubbleRoom = most
                    bubbleWords = Scrubber.cut(title, to: most, in: Scrubber.titleFont)
                    say(bubbleWords.text, on: bubbleTitle, in: Scrubber.titleFont)
                    bubbleTitle.isHidden = title.isEmpty
                }
                bubbleSaid = (title, time)
                bubbleTime.show(time)
                let clockWidth = bubbleTime.width
                let wide = max(bubbleWords.width, clockWidth) + 16
                let tall = (title.isEmpty ? 0 : titleLine) + timeLine + 6
                let (x, width) = bar
                let center = x + width * CGFloat(at)
                // Kept inside the window, whose edges lie outside the row.
                let lowest = 8 - frame.minX, highest = host.bounds.width - 8 - frame.minX - wide
                let left = min(max(center - wide / 2, lowest), max(lowest, highest))
                bubble.frame = CGRect(x: left.rounded(), y: bounds.maxY + 4, width: wide, height: tall)
                bubbleTime.frame = CGRect(x: ((wide - clockWidth) / 2).rounded(), y: 3, width: clockWidth, height: timeLine)
                bubbleTitle.frame = CGRect(x: 8, y: 3 + timeLine, width: wide - 16, height: titleLine)
                bubble.isHidden = false
            }

            /// `text` as it fits in `width`: whole, or cut at a word's
            /// letter and ended with an ellipsis. CATextLayer's own
            /// truncation draws nothing at all for a string with attributes.
            static func cut(_ text: String, to width: CGFloat, in font: NSFont) -> (text: String, width: CGFloat) {
                let measure = { (s: String) in ceil((s as NSString).size(withAttributes: [.font: font]).width) }
                let whole = measure(text)
                guard whole > width else { return (text, whole) }
                let letters = Array(text)
                var low = 0, high = letters.count
                while low < high {
                    let mid = (low + high + 1) / 2
                    if measure(String(letters[..<mid]).trimmingCharacters(in: .whitespaces) + "\u{2026}") <= width { low = mid } else { high = mid - 1 }
                }
                let short = String(letters[..<low]).trimmingCharacters(in: .whitespaces) + "\u{2026}"
                return (short, measure(short))
            }

            /// The pointer moved along the row, or off it: nil.
            ///
            /// In the pass's own transaction, not one of its own: a
            /// transaction begun and ended here, with none open around it,
            /// is sent to the render server there and then, a second commit
            /// for every move of the pointer. The layers here have no
            /// implicit animations to turn off.
            func point(_ x: CGFloat?, option: Bool = false) {
                pointer = x
                if !dragging { snapped = snap(x, option: option) }
                let now = (snapped.map { startX($0) + 0.5 } ?? x).flatMap(piece(at:))
                if now != lit, !dragging {
                    let was = lit
                    lit = now
                    grow([was, now].compactMap { $0 })
                }
                placeMark()
                name()
            }

            /// Pieces to their thickness now, over a tenth of a second:
            /// their track, their window and its copy of the fill.
            private func grow(_ indices: [Int]) {
                let quick = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let was = indices.filter { $0 < pieces.count }.map { (index: $0, bounds: pieces[$0].clip.bounds) }
                lay()
                guard quick else { return }
                for (i, from) in was {
                    let piece = pieces[i]
                    add(piece.clip, "bounds", from, piece.clip.bounds)
                    add(piece.track, "bounds.size.height", from.height, piece.track.bounds.height)
                    add(piece.fill, "bounds.size.height", from.height, piece.fill.bounds.height)
                    add(piece.fill, "cornerRadius", from.height / 2, piece.fill.cornerRadius)
                    add(piece.loaded, "bounds.size.height", from.height, piece.loaded.bounds.height)
                }
            }

            /// Thicker under the pointer, a knob to hold; thin again after.
            /// A tenth of a second, and at once with Reduce Motion.
            private func thicken(animated: Bool = true) {
                let quick = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if !hovered, !dragging {
                    pointer = nil
                    snapped = nil
                }
                let was = (pieces.map(\.clip.bounds), knob.bounds.width, pieces.first?.track.cornerRadius ?? 1.5)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                lay()
                if quick {
                    // By hand, each part on its own key: the width of the
                    // fill is the bar's run, and must not be touched.
                    for (piece, from) in zip(pieces, was.0) {
                        add(piece.clip, "bounds", from, piece.clip.bounds)
                        add(piece.track, "bounds.size.height", from.height, piece.track.bounds.height)
                        add(piece.track, "cornerRadius", was.2, piece.track.cornerRadius)
                        add(piece.fill, "bounds.size.height", from.height, piece.fill.bounds.height)
                        add(piece.fill, "cornerRadius", from.height / 2, piece.fill.cornerRadius)
                        add(piece.loaded, "bounds.size.height", from.height, piece.loaded.bounds.height)
                    }
                    add(knob, "bounds.size.width", was.1, knob.bounds.width)
                    add(knob, "bounds.size.height", was.1, knob.bounds.width)
                    add(knob, "cornerRadius", was.1 / 2, knob.bounds.width / 2)
                }
                let shown: Float = hovered || dragging ? 1 : 0
                if quick { add(knob, "opacity", knob.opacity, shown) }
                knob.opacity = shown
                CATransaction.commit()
            }

            private func add(_ layer: CALayer, _ path: String, _ from: Any, _ to: Any) {
                let change = CABasicAnimation(keyPath: path)
                change.fromValue = from
                change.toValue = to
                change.duration = 0.12
                change.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(change, forKey: path)
            }

            override func layout() {
                super.layout()
                // A new width: the run starts over from where it has got to.
                let was = run
                park()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                lay()
                CATransaction.commit()
                if let was { place(through, running: was.perSecond) }
            }

            // MARK: - going somewhere

            /// The window floats over another app's, and is seldom key: the
            /// first click on the bar goes somewhere, not only into focus.
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

            override func mouseDown(with event: NSEvent) {
                guard canSeek else { return }
                // A live stream's words, right of the bar: the way back to
                // the edge while behind, nothing at it.
                if let stream, convert(event.locationInWindow, from: nil).x > bar.x + bar.width + 4 {
                    if goesLive { goLive(stream) }
                    return
                }
                dragging = true
                thicken()
                drag(event, exact: false)
            }

            override func mouseDragged(with event: NSEvent) {
                guard dragging else { return }
                drag(event, exact: false)
            }

            override func mouseUp(with event: NSEvent) {
                guard dragging else { return }
                dragging = false
                drag(event, exact: true)
                thicken()
            }

            /// The bar and the time gone go with the pointer at once; the
            /// page follows as fast as it can.
            private func drag(_ event: NSEvent, exact: Bool) {
                let (x, width) = bar
                guard width > 0 else { return }
                let at = convert(event.locationInWindow, from: nil).x
                // Near a chapter's start, the knob is taken to it, and a
                // trackpad says so once as it gets there.
                let near = snap(at, option: event.modifierFlags.contains(.option))
                if near != snapped {
                    snapped = near
                    if near != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                }
                let value = near.map { chapters[$0].start / length } ?? max(0, min(1, Double((at - x) / width)))
                run = nil
                through = value
                pointer = at
                // In the pass's own transaction, as `point` is; the layers
                // have no implicit animations to turn off.
                stop()
                // The piece being dragged through stands out, as the one
                // under a still pointer does.
                let now = piece(at: near.map { startX($0) + 0.5 } ?? at)
                placeMark()
                if now != lit {
                    let was = lit
                    lit = now
                    grow([was, now].compactMap { $0 })
                } else {
                    follow()
                }
                if let stream {
                    // The edge itself from a little short of it on. How far
                    // behind it lands is the tip's to say while dragged,
                    // and the words' once let go.
                    if exact {
                        held = stream.behind(at: value) < LiveEdge.near
                        word(stream.tip(at: value))
                    }
                    onSeek?(stream.snapped(value), exact)
                    return
                }
                tell(value * length)
                onSeek?(value, exact)
            }

            /// Back to the edge: the bar to its end and the words Live at
            /// once, the page after.
            private func goLive(_ stream: LiveEdge.Window) {
                var there = stream
                there.time = stream.edge
                self.stream = there
                held = true
                place(1, running: 0)
                word("Live")
                onSeek?(1, true)
            }

            func benchState() -> [String: Any] {
                let fill = pieces.first?.fill
                let shown = (fill?.presentation()?.bounds.width ?? fill?.bounds.width ?? 0) / max(1, bar.width)
                return [
                    "elapsed": timeText, "total": lengthText, "through": through,
                    "live": stream != nil, "behind": stream?.behind ?? 0, "live_start": stream?.start ?? -1,
                    "live_edge": stream?.edge ?? 0, "time": stream?.time ?? 0, "seekable": canSeek,
                    "goes_live": goesLive, "underlined": !link.isHidden, "live_waiting": waiting, "held": held,
                    "tip": stream != nil && !bubble.isHidden ? bubbleSaid.1 : "",
                    "bar_shown": Double(shown), "running": fill?.animation(forKey: "run") != nil,
                    "thickness": Double(thickness), "hovered": hovered, "dragging": dragging,
                    "row": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
                    "bar": [frame.minX + bar.x, frame.minY, bar.width].map { Double($0) },
                    "words": [frame.minX + bounds.width - total.width, frame.minY, total.width, frame.height].map { Double($0) },
                    "chapters": chapters.count, "pieces": spans.count,
                    "spans": spans.map { [($0.from * 1000).rounded() / 1000, ($0.to * 1000).rounded() / 1000] },
                    "lit": lit ?? -1, "lit_thickness": lit.flatMap { $0 < pieces.count ? Double(pieces[$0].clip.bounds.height) : nil } ?? 0,
                    "named": bubble.isHidden ? "" : "\(bubbleSaid.0) \(bubbleSaid.1)",
                    "bubble": bubble.isHidden ? [] : [bubble.frame.minX + frame.minX, bubble.frame.minY + frame.minY,
                                                      bubble.frame.width, bubble.frame.height].map { Double($0) },
                    "running_pieces": pieces.filter { $0.fill.animation(forKey: "run") != nil }.count,
                    "snapped": snapped ?? -1,
                    "mark": mark.isHidden ? [] : [frame.minX + mark.frame.midX, frame.minY + mark.frame.midY].map { Double($0) },
                    "loaded": loaded.map { [($0.from * 1000).rounded() / 1000, ($0.to * 1000).rounded() / 1000] } ?? [],
                    "loaded_shown": pieces.contains { !$0.loaded.isHidden },
                ]
            }
        }

        /// A time, "1:24", drawn from pictures of its characters made once:
        /// a new time is a picture handed to a layer, where a text layer
        /// given a new string lays it out and throws a typesetter away,
        /// which under a pointer running along the bar was most of what
        /// the main thread did.
        final class Clock: CALayer {
            private let font: NSFont
            private let alpha: CGFloat
            private var said = ""
            private var marks: [CALayer] = []
            private var drawn: [Character: (image: CGImage, width: CGFloat)] = [:]
            /// How wide the time now showing is, in points.
            private(set) var width: CGFloat = 0
            var scale: CGFloat = 2 {
                didSet {
                    guard scale != oldValue else { return }
                    drawn = [:]
                    let was = said
                    said = ""
                    show(was)
                }
            }

            init(font: NSFont, alpha: CGFloat) {
                self.font = font
                self.alpha = alpha
                super.init()
                actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            }

            override init(layer: Any) {
                let other = layer as? Clock
                font = other?.font ?? .systemFont(ofSize: 10)
                alpha = other?.alpha ?? 1
                super.init(layer: layer)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError() }

            private func picture(_ character: Character) -> (image: CGImage, width: CGFloat)? {
                if let made = drawn[character] { return made }
                let text = NSAttributedString(string: String(character), attributes: [
                    .font: font, .foregroundColor: NSColor(white: 1, alpha: alpha),
                ])
                let size = text.size()
                let height = ceil(font.ascender - font.descender)
                let pixels = (w: max(1, Int(ceil(size.width * scale))), h: max(1, Int(ceil(height * scale))))
                guard let context = CGContext(
                    data: nil, width: pixels.w, height: pixels.h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return nil }
                context.scaleBy(x: scale, y: scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                text.draw(at: NSPoint(x: 0, y: -font.descender))
                NSGraphicsContext.restoreGraphicsState()
                guard let image = context.makeImage() else { return nil }
                let made = (image, size.width)
                drawn[character] = made
                return made
            }

            func show(_ text: String) {
                guard text != said else { return }
                said = text
                let characters = Array(text)
                while marks.count < characters.count {
                    let mark = CALayer()
                    mark.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
                    mark.contentsGravity = .resize
                    addSublayer(mark)
                    marks.append(mark)
                }
                let height = ceil(font.ascender - font.descender)
                var x: CGFloat = 0
                for (i, mark) in marks.enumerated() {
                    guard i < characters.count, let made = picture(characters[i]) else {
                        mark.isHidden = true
                        continue
                    }
                    mark.isHidden = false
                    if (mark.contents as AnyObject?) !== made.image { mark.contents = made.image }
                    mark.contentsScale = scale
                    mark.frame = CGRect(x: x, y: 0, width: CGFloat(made.image.width) / scale, height: height)
                    x += made.width
                }
                width = ceil(x)
            }
        }
    }
}

/// The subtitles, drawn by the window the way YouTube draws them: white
/// words, a line to a dark box, low and centered over the picture. The
/// player's own come out laid out for a player many times this size, tiny
/// or without their boxes, and each site's in its own style; these are the
/// same everywhere, and sized to the window as it is pinched and dragged.
private final class Captions: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    /// Lifted clear of the bar along the bottom, while the buttons show.
    var raised = false {
        didSet {
            guard raised != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                animator().setFrameOrigin(NSPoint(x: 0, y: raised ? lift : 0))
            }
        }
    }

    /// Enough for the words' foot to sit above the bar's row, the top of
    /// which is 28 points up.
    private var lift: CGFloat { max(6, 34 - foot) }
    private var foot: CGFloat { max(8, (bounds.height * 0.06).rounded()) }

    /// Past this many lines, the latest are shown: the words being said,
    /// not the start of a sentence that ran long.
    private let most = 2

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        // Sized to the window: a pinch redraws the words at the new size.
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        guard !text.isEmpty, bounds.height > 0 else { return }
        let tall = bounds.height
        // YouTube's own measure is a little under a twentieth of the
        // player's height; a floor keeps a small window legible, a ceiling
        // keeps a large one from shouting.
        var size = min(26, max(11, (tall / 19).rounded()))
        let across = (bounds.width * 0.9).rounded()
        // A player breaks its lines where it means them to break. One that
        // only just doesn't fit is made a little smaller, rather than leave
        // its last word alone on a line of its own; one that is a paragraph
        // wraps at the size it has.
        let widest = text.split(separator: "\n").map {
            (String($0) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width
        }.max() ?? 0
        if widest > across, widest < across * 1.4 { size = max(10, (size * across / widest).rounded(.down)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.12
        let words = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])

        let storage = NSTextStorage(attributedString: words)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: across, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        // Every line, as laid out: its band, and the part of it the words
        // take, which is what gets a box.
        typealias Line = (band: NSRect, inked: NSRect, glyphs: NSRange)
        func lay(_ width: CGFloat) -> [Line] {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            var lines: [Line] = []
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { band, _, _, glyphs, _ in
                // The space or line break a line ends on takes no box.
                var inked = glyphs
                while inked.length > 0 {
                    let character = layout.characterIndexForGlyph(at: NSMaxRange(inked) - 1)
                    let unit = (storage.string as NSString).character(at: character)
                    guard let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                    inked.length -= 1
                }
                guard inked.length > 0 else { return }
                lines.append((band, layout.boundingRect(forGlyphRange: inked, in: container), inked))
            }
            return lines
        }
        var lines = lay(across)
        // A player's two lines that wrap past the limit: as one run of
        // words they keep to it, or lose the fewest.
        if lines.count > most, text.contains("\n") {
            _ = storage.mutableString.replaceOccurrences(of: "\n", with: " ", options: [], range: NSRange(location: 0, length: storage.length))
            lines = lay(across)
        }
        // Wrapped, the lines are evened out: as narrow as the words go
        // without needing another line, so a paragraph doesn't end on one
        // word left alone under two full lines.
        if lines.count > 1 {
            let count = lines.count
            var low: CGFloat = across / CGFloat(count), high = across
            while high - low > 4 {
                let middle = ((low + high) / 2).rounded()
                if lay(middle).count > count { low = middle } else { high = middle }
            }
            lines = lay(high)
        }
        let shown = Array(lines.suffix(most))
        guard let first = shown.first, let last = shown.last else { return }

        // The block's foot a little above the window's, as YouTube keeps it.
        let block = last.band.maxY - first.band.minY
        let origin = NSPoint(
            x: ((bounds.width - container.size.width) / 2).rounded(),
            y: (tall - foot - block - first.band.minY).rounded()
        )

        // One box a line, touching the next and never overlapping it, so
        // two lines don't make a darker seam where they meet.
        let pad = (size * 0.32).rounded()
        let round = max(2, (size * 0.14).rounded())
        NSColor(white: 0.03, alpha: 0.75).setFill()
        for line in shown {
            let box = NSRect(
                x: origin.x + line.inked.minX - pad,
                y: origin.y + line.band.minY,
                width: line.inked.width + pad * 2,
                height: line.band.height
            )
            NSBezierPath(roundedRect: box, xRadius: round, yRadius: round).fill()
        }
        for line in shown {
            layout.drawGlyphs(forGlyphRange: line.glyphs, at: origin)
        }
    }
}

/// A video minimized out of the floating window plays on in its tab, and
/// Picture in Picture automatically leaves it there until you come back to
/// that tab: leaving it again floats it as before (rows 1090, 1038).
/// Floating it by hand, the island's Float Video or ⇧⌘P, ends the hold too.
struct MinimizeHold: Equatable {
    /// The tab whose video was minimized, while the hold lasts.
    private(set) var tab: UUID?
    /// Its tab came in front again since: the next leave floats it.
    private(set) var back = false

    /// Minimized now. Its tab may be in front, the window out because
    /// Yab was left: that is not coming back to it.
    mutating func minimized(_ id: UUID) {
        tab = id
        back = false
    }

    /// The tab in front now, in Yab.
    mutating func shown(_ id: UUID?) {
        if let tab, id == tab { back = true }
    }

    /// Floated by hand: no hold.
    mutating func forget() {
        tab = nil
        back = false
    }

    /// Whether Picture in Picture automatically may take this tab's video
    /// out now. Its tab left after you came back to it: yes, and the hold
    /// is over.
    mutating func allowsAuto(_ id: UUID?) -> Bool {
        guard let tab, let id, id == tab else { return true }
        guard back else { return false }
        forget()
        return true
    }
}

/// Sites whose players keep the established automatic PiP policy.
enum Players {
    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
        // Its videos, films and live rooms, and the international site
        // (row 1111).
        ("bilibili.com", nil), ("bilibili.tv", nil),
    ]

    /// A coarse gate before asking the page. Isolate checks the actual
    /// video, including its user start and played time on unlisted sites.
    @MainActor static func follows(_ tab: Tab) -> Bool {
        knows(tab.address) || tab.noisy
    }

    /// Isolate's automatic modes: the established policy on listed sites,
    /// a user-started video with three seconds of play everywhere else.
    static func automaticPolicy(_ url: URL?) -> Double { knows(url) ? 1 : 2 }

    static func knows(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        // A test's local player page counts as a site to watch on
        // (evals/float-away): real sites don't always play on a farm Mac.
        if Store.testing, let extra = ProcessInfo.processInfo.environment["YAB_TEST_PLAYER"],
           "\(host):\(url.port ?? 80)" == extra { return true }
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// A glide's frames, off the display's own refresh.
@MainActor
private final class Glider: NSObject {
    let from: NSPoint, kind: Floater.Motion
    /// Where it ends; a glide out to a hand still carrying follows it.
    var to: NSPoint
    let start = CACurrentMediaTime()
    var frames = 0
    /// A debug build's count: the longest wait between two frames, and how
    /// many came late (`count`).
    private(set) var worst: CFTimeInterval = 0
    private(set) var late = 0
    private(set) var frameInterval: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    /// One frame; true once the glide is over.
    var step: ((CADisplayLink) -> Bool)?
    private var link: CADisplayLink?

    init(from: NSPoint, to: NSPoint, kind: Floater.Motion) {
        self.from = from
        self.to = to
        self.kind = kind
    }

    func count(_ link: CADisplayLink) {
        frameInterval = link.targetTimestamp - link.timestamp
        if last > 0 {
            let gap = link.timestamp - last
            worst = max(worst, gap)
            if gap > (link.targetTimestamp - link.timestamp) * 1.5 { late += 1 }
        }
        last = link.timestamp
    }

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if step?(link) ?? true { stop() }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

/// What is left out of the window tucked behind a side of the screen, a
/// video's or a call's alike: the system's dark tab with a chevron
/// (`FloatEdgeTab`), a call's with what it has to say under the chevron:
/// muted, on camera, showing the screen. Over the whole window, not only
/// the tab, it takes every press and gesture while the window is tucked:
/// the buttons under it are away, and a peek's click must not reach the
/// page.
private final class FloatLip: NSView {
    private let edge = FloatEdgeTab()
    /// Always the tab now; kept for the bench's word.
    var compact = true { didSet { needsLayout = true; edge.isHidden = !compact } }
    var edgeAlpha: CGFloat = 0 { didSet { edge.alphaValue = edgeAlpha } }
    var side = FloatPark.Side.right { didSet { needsLayout = true } }
    /// A call's state under the chevron; none for a video.
    var marks = FloatEdgeTab.Marks() {
        didSet {
            guard marks != oldValue else { return }
            if marks.muted, !oldValue.muted { budded += 1 }
            edge.marks = marks
            // The tab grows or shrinks to what it says, on the same curve
            // as the marks.
            let frame = FloatEdgeTab.tabFrame(in: bounds, side: side, width: FloatEdgeTab.width,
                                              height: FloatEdgeTab.height(for: marks))
            if window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                    edge.animator().frame = frame
                }
            } else {
                edge.frame = frame
            }
            updateTrackingAreas()
        }
    }
    var label: String {
        get { edge.accessibilityLabel() ?? "" }
        set { edge.setAccessibilityLabel(newValue) }
    }
    /// The pointer on it: the chevron a shade brighter, at once.
    var lit = false { didSet { if lit != oldValue { needsLayout = true } } }
    /// Mutings seen, for the bench.
    private(set) var budded = 0
    let turnCost: Double = 0
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    /// Stop a hover peek before the fingers take over the window's motion.
    var onBegin: (() -> Void)?
    /// Being carried out by hand, from the first move.
    var onCarry: (() -> Void)?
    var onLetGo: (() -> Void)?
    /// Two fingers pulled the lip inward far enough to reveal the window.
    var onAway: (() -> Void)?
    var onTravel: (() -> Void)?
    /// Two fingers up (true) or down along the edge.
    var onSlide: ((Bool) -> Void)?

    /// Who talks, a hand waiting: light along the tab's inner side.
    func light(talking: Bool, hand: Bool) { edge.light(talking: talking, hand: hand) }
    /// A reaction in the chevron's place for a moment.
    func flash(_ emoji: String) { edge.flash(emoji) }

    /// What it shows, for the bench.
    var glyph: String { side == .right ? "chevron.left" : "chevron.right" }
    var axRole: String { edge.accessibilityRole()?.rawValue ?? "" }
    var axLabel: String { edge.accessibilityLabel() ?? "" }
    var tabRect: NSRect { edge.frame }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        edge.onRestore = { [weak self] in self?.onClick?() }
        addSubview(edge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        edge.frame = FloatEdgeTab.tabFrame(in: bounds, side: side, width: FloatEdgeTab.width,
                                           height: FloatEdgeTab.height(for: marks))
        edge.side = side
        edge.lit = lit
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        if compact, let area = (superview as? Ground)?.clipRect, !area.contains(local) { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: compact ? edge.frame : bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    private var holding = false
    var interacting: Bool { holding || swipeOrigin != nil }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { if !holding { onHover?(false) } }

    // A click lets it out; a drag carries it out by hand, and letting go
    // decides again, as for any carry.
    private var grab = NSPoint.zero
    private var origin = NSPoint.zero
    private var carried = false
    /// A video's tab drawn up or down along the edge: it stays tucked and
    /// goes where the hand takes it, as the system's does.
    private var sliding = false

    override func mouseDown(with event: NSEvent) {
        if DebugLog.pip { DebugLog.note("lip-down", ["p": DebugLog.point(NSEvent.mouseLocation), "f": DebugLog.rect(window?.frame ?? .zero)]) }
        holding = true
        carried = false
        sliding = false
        grab = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        origin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, holding else { return }
        let now = window.convertPoint(toScreen: event.locationInWindow)
        let dx = now.x - grab.x, dy = now.y - grab.y
        // A tremble on the lip is still a click.
        guard carried || sliding || hypot(dx, dy) >= 3 else { return }
        if !carried, !sliding {
            if compact, abs(dy) > abs(dx) {
                sliding = true
                onBegin?()
            } else {
                carried = true
                onCarry?()
            }
        }
        if sliding {
            var y = origin.y + dy
            if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
                y = min(max(y, area.minY), area.maxY - window.frame.height)
            }
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: y.rounded()))
            return
        }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        onTravel?()
    }

    override func mouseUp(with event: NSEvent) {
        let was = holding
        holding = false
        guard was else { return }
        if DebugLog.pip {
            DebugLog.note("lip-up", ["p": DebugLog.point(NSEvent.mouseLocation), "f": DebugLog.rect(window?.frame ?? .zero),
                                     "carried": carried, "sliding": sliding])
        }
        if sliding { sliding = false; return }
        if carried {
            let inward = ((window?.frame.minX ?? origin.x) - origin.x) * (side == .right ? -1 : 1)
            // A short inward pull means restore, just as an inward swipe.
            // Requiring most of the picture to cross the edge made it tuck
            // again after an otherwise successful pull of the tab.
            if inward > 20 { onAway?() } else { onLetGo?() }
        } else { onClick?() }
    }

    /// The picture follows two fingers inward from the lip. On release it
    /// completes the reveal beside that same edge, or returns to the lip.
    private var swipe: CGFloat = 0
    private var swipeOrigin: CGFloat?
    /// Up and down so far, and whether this swipe is one along the edge.
    private var rise: CGFloat = 0
    private var along = false
    private let following = SwipeFollow()

    private func follow(_ on: Bool) {
        following.stop()
        guard on else { return }
        following.start(local: { [weak self] event in
            guard let self else { return event }
            // A fresh gesture belongs to its actual target, even if the
            // previous one lost its release. Do not swallow another page's scroll.
            if event.phase.contains(.began) {
                self.finishSwipe()
                return event
            }
            self.scroll(with: event)
            return nil
        }, global: { [weak self] event in
            guard let self else { return }
            if event.phase.contains(.began) { self.finishSwipe(); return }
            self.scroll(with: event)
        })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { follow(false) }
    }

    override func scrollWheel(with event: NSEvent) {
        // The local monitor consumes followed events before dispatch.
        scroll(with: event)
    }

    private func finishSwipe() {
        guard swipeOrigin != nil else { return }
        let vertical = along
        let up = rise > 0
        let reveal = swipe > 20
        if DebugLog.pip {
            DebugLog.note("lip-swipe", ["swipe": Double(swipe), "reveal": reveal, "along": vertical,
                                       "f": DebugLog.rect(window?.frame ?? .zero)])
        }
        // Clear ownership before the callback can remove this view.
        swipe = 0
        swipeOrigin = nil
        along = false
        follow(false)
        if vertical { onSlide?(up) }
        else if reveal { onAway?() }
        else { onLetGo?() }
    }

    private func scroll(with event: NSEvent) {
        guard let window, event.momentumPhase == [] else { return }
        // An ordinary wheel does not start an interaction on the video tab.
        if compact, event.phase == [] { return }
        let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) || swipeOrigin == nil {
            if swipeOrigin != nil { finishSwipe() }
            swipe = 0
            rise = 0
            along = false
            swipeOrigin = window.frame.minX
            onBegin?()
            follow(event.phase != [])
            if DebugLog.pip { DebugLog.note("lip-swipe-begin", ["f": DebugLog.rect(window.frame)]) }
        }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        if compact {
            rise += -sign * event.scrollingDeltaY
            if !along, swipe < 8, abs(rise) > 12, abs(rise) > abs(event.scrollingDeltaX) * 2 { along = true }
        }
        if !along {
            let inward = sign * event.scrollingDeltaX * (side == .right ? -1 : 1)
            swipe = max(0, swipe + inward)
            if let area = (window.screen ?? NSScreen.main)?.visibleFrame, let origin = swipeOrigin {
                let dock = FloatPark.unparked(window.frame, side, in: area)
                let distance = abs(dock.x - origin)
                let x = origin + (side == .right ? -1 : 1) * min(swipe, distance)
                window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
                onTravel?()
            }
        }
        following.hush()
        if lifted || event.phase == [] { finishSwipe() }
        else { following.wait { [weak self] in self?.finishSwipe() } }
    }
}

/// The window's black ground, which says when the page leaves it.
private final class Ground: NSView {
    var clipRect: NSRect?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let clipRect, !clipRect.contains(local) { return nil }
        return super.hitTest(point)
    }
    var onLoss: ((NSView) -> Void)?
    /// Sizes the page has been given here, for the bench.
    private(set) var resizes = 0

    override func setFrameSize(_ size: NSSize) {
        if size != frame.size { resizes += 1 }
        super.setFrameSize(size)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onLoss?(subview)
    }
}

/// A floated page, shown at the window's size while it stays its own: the
/// bounds are the page's size, fitted in and centered, so AppKit scales what
/// is drawn and the page is never made another size. A call's page is shown
/// whole; a video's, only the video: the page makes it as large as its
/// window lets it and centers it, so of the page the lens shows the middle,
/// in the video's shape, the black bars either side left out.
private final class Lens: NSView {
    let content: NSSize
    var onLoss: ((NSView) -> Void)?
    /// The video's width over its height, nil to show the whole page.
    var focus: CGFloat? {
        didSet { if focus != oldValue { fit() } }
    }
    /// Filled rather than fitted: the page cut at the sides or the top and
    /// bottom, never bars (a call, its stage laid out for what shows).
    var fill = false {
        didSet { if fill != oldValue { fit() } }
    }

    init(frame: NSRect, content: NSSize) {
        self.content = content
        super.init(frame: frame)
        wantsLayer = true
        fit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        fit()
    }

    private func fit() {
        guard frame.width > 0, frame.height > 0, content.width > 0, content.height > 0 else { return }
        // The part of the page to show: the video, as object-fit:contain
        // lays it in the page, or the page.
        var shown = content
        if let focus, focus > 0 {
            shown = focus > content.width / content.height
                ? NSSize(width: content.width, height: content.width / focus)
                : NSSize(width: content.height * focus, height: content.height)
        }
        let scale = fill ? max(frame.width / shown.width, frame.height / shown.height)
            : min(frame.width / shown.width, frame.height / shown.height)
        let seen = NSSize(width: frame.width / scale, height: frame.height / scale)
        bounds = NSRect(x: -(seen.width - content.width) / 2, y: -(seen.height - content.height) / 2,
                        width: seen.width, height: seen.height)
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onLoss?(subview)
    }
}

/// A panel that takes key status without bringing the whole app forward.
///
/// Borderless windows refuse to become key by default, and a window that never
/// becomes key is a window the system stops routing gestures to.
private final class Panel: NSPanel {
    /// With another app in front, only a press makes it key, and what the
    /// press set off (a call's reply field) just after: never a hover, a
    /// video event or a timer, which would take the keys typed into that
    /// app (register 1665).
    override var canBecomeKey: Bool {
        NSApp.isActive || ProcessInfo.processInfo.systemUptime - pressed < 1
    }
    override var canBecomeMain: Bool { false }
    var onMagnify: ((NSEvent) -> Void)?
    private var pressed: TimeInterval = -.infinity

    override func sendEvent(_ event: NSEvent) {
        if event.type == .magnify, let onMagnify {
            onMagnify(event)
            return
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp].contains(event.type) {
            pressed = ProcessInfo.processInfo.systemUptime
        }
        // Among other windows (Keep on Top off), a press brings it forward,
        // as a press on any window does; a nonactivating panel isn't by
        // itself while Yab is behind.
        if level == .normal, event.type == .leftMouseDown || event.type == .rightMouseDown { orderFrontRegardless() }
        super.sendEvent(event)
    }
}

/// What finds the video and puts everything else out of the way, in every
/// frame of the page, not only the top one.
///
/// A film on somebody else's site is almost always someone else's player in a
/// frame of its own: YouTube, Vimeo, a streaming service's embed. The top
/// document cannot see into a frame from another site, and a script evaluated
/// from here runs only in the top one. So the script is put into every frame
/// as it loads, and the frames talk to each other the only way a page may
/// across sites, by message, each one to the frame it contains. The top
/// document asks its frames where the biggest playing video is; the frame
/// that has it, or has a frame that has it, is told to float it; every frame
/// on the way down makes the frame below it the whole of its window.
///
/// It lives in a world of its own: the page cannot see it, call it or
/// overwrite it, and the messages carry a key the page never learns.
extension Floater {
    /// The speeds the menu offers, and < and > step along.
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// "1×", "1.25×": the speed as people say it.
    static func said(_ rate: Double) -> String {
        let hundredths = (rate * 100).rounded()
        guard hundredths.isFinite else { return "1×" }
        // Formatting a page's whole-number rate must not narrow it to Int.
        let text = hundredths.truncatingRemainder(dividingBy: 100) == 0 ? String(format: "%.0f", hundredths / 100)
            : hundredths.truncatingRemainder(dividingBy: 10) == 0 ? String(format: "%.1f", hundredths / 100)
            : String(format: "%.2f", hundredths / 100)
        return text + "×"
    }

    /// The next speed along `speeds` from `rate`, faster (way > 0) or
    /// slower; nil past either end. A speed between two steps goes to the
    /// nearer step that way.
    static func speed(after rate: Double, way: Int) -> Double? {
        way > 0 ? speeds.first { $0 > rate + 0.001 } : speeds.last { $0 < rate - 0.001 }
    }

    /// YouTube keeps its subtitles in its player, not in <track>s, and
    /// the player's methods live in the page's own world, so this runs
    /// there (callAsyncJavaScript in .page, with choice, wanted and
    /// wantedName). The list comes from the player's answer, which has it
    /// whether subtitles are on or not; the one shown from the player's
    /// option. Into the language this Mac is set to, when the video has
    /// none in it, YouTube translates: one more entry at the end. Answers
    /// [now, [[name, code, kind], …], spoken], as Subtitles reads it.
    static let youTubeSubtitles = """
    var p = document.getElementById('movie_player');
    if (!p || typeof p.getPlayerResponse !== 'function' || typeof p.setOption !== 'function') return null;
    var renderer = ((p.getPlayerResponse() || {}).captions || {}).playerCaptionsTracklistRenderer || {};
    var tracks = renderer.captionTracks || [];
    var named = function (n) { n = n || {}; return n.simpleText || (n.runs || []).map(function (r) { return r.text; }).join(''); };
    var base = function (code) { return String(code || '').toLowerCase().split('-')[0]; };
    var into = (renderer.translationLanguages || []).filter(function (l) { return l.languageCode === wanted; })[0];
    var translates = !!into && tracks.length > 0 && !tracks.some(function (t) { return base(t.languageCode) === wanted; });
    var list = tracks.map(function (t) { return [named(t.name) || t.languageCode, t.languageCode, t.kind || '']; });
    if (translates) list.push([wantedName, wanted, 'translated']);
    var audio = (renderer.audioTracks || [])[renderer.defaultAudioTrackIndex || 0] || {};
    var spoken = typeof audio.defaultCaptionTrackIndex === 'number' ? audio.defaultCaptionTrackIndex : -1;
    if (spoken < 0) tracks.forEach(function (t, i) { if (spoken < 0 && t.kind === 'asr') spoken = i; });
    var showing = function () {
      var now = {};
      try { now = p.getOption('captions', 'track') || {}; } catch (e) {}
      if (!now.languageCode) return -1;
      if (now.translationLanguage && now.translationLanguage.languageCode) {
        return translates && now.translationLanguage.languageCode === wanted ? list.length - 1 : -1;
      }
      for (var i = 0; i < tracks.length; i++) {
        if (tracks[i].languageCode === now.languageCode && (tracks[i].kind || '') === (now.kind || '')) return i;
      }
      return -1;
    };
    if (choice === -1) {
      try { p.setOption('captions', 'track', {}); } catch (e) {}
      try { p.unloadModule('captions'); } catch (e) {}
    } else if (choice >= 0 && choice < list.length) {
      try { p.loadModule('captions'); } catch (e) {}
      var pick = list[choice];
      if (pick[2] === 'translated') {
        var from = tracks[spoken >= 0 && spoken < tracks.length ? spoken : 0];
        p.setOption('captions', 'track', { languageCode: from.languageCode, kind: from.kind || '',
          translationLanguage: { languageCode: wanted, languageName: wantedName } });
      } else {
        p.setOption('captions', 'track', { languageCode: pick[1], kind: pick[2] });
      }
      await new Promise(function (done) { setTimeout(done, 300); });
    }
    return [showing(), list, spoken];
    """
}

enum Isolate {
    @MainActor static var world: WKContentWorld { PageWorld.named("float").contentWorld }
    private static let key = UUID().uuidString

    /// For every frame of every page, at the start of each document.
    @MainActor static var script: WKUserScript {
        WKUserScript(
            source: PageScript.load("pip-placeholder") + "\n" + source.replacingOccurrences(of: "__KEY__", with: key),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        )
    }

    /// Whether `on` floated something: it answers ["floating", width,
    /// height], the video's own size, 0 by 0 until it knows it.
    static func floated(_ answer: Any?) -> Bool {
        (answer as? [Any])?.first as? String == "floating"
    }

    static func shape(_ answer: Any?) -> CGSize? {
        guard let all = answer as? [Any], all.count >= 3,
              let width = (all[1] as? NSNumber)?.doubleValue, let height = (all[2] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        // A finite pair can still overflow or underflow when used as a ratio.
        let aspect = width / height
        guard aspect.isFinite, aspect > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Calls one of the script's verbs in the top document and answers with
    /// what it came back with, or nil, a page the script never reached, a
    /// page that has gone.
    @MainActor static func run(_ verb: String, _ argument: Double = 0, on web: any PageScriptTarget, _ answer: ((Any?) -> Void)? = nil) {
        web.call(
            "var f = window.__yabFloat; return f ? await f[verb](argument) : null;",
            arguments: ["verb": verb, "argument": argument], in: .named("float")
        ) { result in
            if case .success(let value) = result { answer?(value) } else { answer?(nil) }
        }
    }

    private static let source = """
    (function () {
      if (window.__yabFloat) return;
      var KEY = '__KEY__';

      // A box made the whole of the window. position:fixed alone was not
      // enough: fixed is fixed to the window only while nothing around it has
      // a transform, a filter or a containment of its own, a player in a
      // modal that slid in does, and otherwise to that box, which, with the
      // video gone from its flow, has no height and clips it to nothing. The
      // black window. And where nothing around it did, WebKit still drew the
      // picture where its old box had been. So every box on the way out to
      // the body is made the window too.
      var WHOLE = [
        'position:fixed !important; inset:0 !important; margin:0 !important;',
        'width:100vw !important; height:100vh !important;',
        'min-width:0 !important; min-height:0 !important;',
        'max-width:none !important; max-height:none !important;',
        'transform:none !important; translate:none !important;',
        'scale:none !important; rotate:none !important;',
        'filter:none !important; backdrop-filter:none !important;',
        'perspective:none !important; contain:none !important;',
        'content-visibility:visible !important; will-change:auto !important;',
        'clip-path:none !important; mask:none !important; opacity:1 !important;',
        'visibility:visible !important; border:0 !important;'
      ].join('');
      // Where the players people watch with subtitles keep them: YouTube,
      // Netflix, Prime Video, Disney+, and the video.js and Plyr players
      // much of the rest of the web is built on.
      var CAPTIONS = [
        '.ytp-caption-window-container', '.player-timedtext',
        '.atvwebplayersdk-captions-overlay', '.dss-subtitle-renderer-wrapper',
        '.vjs-text-track-display', '.plyr__captions'
      ];
      var RULES = [
        '[data-yab-around] {', WHOLE,
        'display:block !important; padding:0 !important;',
        'overflow:visible !important; background:transparent !important;',
        'z-index:2147483646 !important}',
        // What else sits in those boxes, the player's own buttons, a poster,
        // a title, stays out of sight.
        '[data-yab-around] > :not([data-yab-around]):not([data-yab-float]) {',
        'visibility:hidden !important}',
        '[data-yab-float] {', WHOLE,
        'object-fit:contain !important; background:#000 !important;',
        'z-index:2147483647 !important}',
        // The player's own subtitles are laid out for the player it had, and
        // in a window this small they come out tiny, or bare, their boxes
        // lost with the player around them. The window draws them itself
        // (Floater.Captions), from the words read here, so the player's are
        // kept laid out and readable but never seen: opacity, not
        // visibility, which innerText would read as no words at all. The
        // :not(#…) matches everything and weighs as an id, so this outranks
        // the hiding rule above, !important against !important.
        CAPTIONS.map(function (c) { return '[data-yab-around] ' + c + ':not(#yab-none)'; }).join(',') + ' {',
        'visibility:visible !important; opacity:0 !important}',
        // And the engine's own, for a video with a <track> of its own.
        'video[data-yab-float]::-webkit-media-text-track-container { display:none !important}',
        // The player's own controls would sit under ours, and two sets of
        // buttons on one small window is one set too many.
        'video[data-yab-float]::-webkit-media-controls { display:none !important}'
      ];
      var PAGE = [
        'html.yab-floating, html.yab-floating body {',
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.yab-floating body > * { visibility:hidden !important }'
      ].join('') + RULES.join('').replace(/(^|\\})\\s*\\[/g, '$1html.yab-floating [')
        .replace(/(^|\\})\\s*video\\[/g, '$1html.yab-floating video[');
      // Inside a shadow root the page's sheet does not reach; the same rules
      // go in there, with the root's own top level as the thing to hide.
      var SHADE = RULES.join('') +
        ':host > :not([data-yab-around]):not([data-yab-float]) { visibility:hidden !important }';

      var target = null, marked = [], sheets = [], watch = null, busy = false;
      var waiting = {}, count = 0;

      // Open shadow roots too: a player built as a web component keeps its
      // video there, where querySelectorAll from the document never looks.
      function roots() {
        var all = [document];
        for (var i = 0; i < all.length; i++) {
          var els = all[i].querySelectorAll('*');
          for (var j = 0; j < els.length; j++) {
            if (els[j].shadowRoot) all.push(els[j].shadowRoot);
          }
        }
        return all;
      }
      function each(selector) {
        var out = [], rs = roots();
        for (var i = 0; i < rs.length; i++) {
          var found = rs[i].querySelectorAll(selector);
          for (var j = 0; j < found.length; j++) out.push(found[j]);
        }
        return out;
      }
      function area(el) {
        var box = el.getBoundingClientRect();
        return box.width * box.height;
      }
      function playing(v) { return !v.paused && !v.ended && v.readyState >= 2; }

      function played(v) {
        var ranges = v.played, seconds = 0;
        if (ranges) for (var i = 0; i < ranges.length; i++) seconds += ranges.end(i) - ranges.start(i);
        return seconds;
      }

      // Only input in this document can start its video. Remember the
      // start, not sticky activation or a click after autoplay began.
      var starts = new WeakMap(), listening = new WeakSet(), lastInput = -Infinity;
      function input(event) {
        if (!event.isTrusted) return;
        lastInput = Date.now();
        // Media events do not cross shadow roots. A composed press reaches
        // us first, before a player's handler starts its shadow video.
        var path = event.composedPath ? event.composedPath() : [];
        path.forEach(function (node) { if (node.nodeType === 11) listen(node); });
      }
      function playback(event) {
        var v = event.target;
        if (!event.isTrusted || !v || v.tagName !== 'VIDEO') return;
        if (event.type !== 'play') { starts.delete(v); return; }
        if (starts.has(v)) return;
        var activation = window.navigator && window.navigator.userActivation;
        var since = Date.now() - lastInput;
        if ((activation && activation.isActive) || (since >= 0 && since <= 1000)) {
          starts.set(v, played(v));
        }
      }
      function listen(root) {
        if (!root.addEventListener || listening.has(root)) return;
        listening.add(root);
        if (window.__yabPiPPlacard) window.__yabPiPPlacard.listen(root);
        ['pointerdown', 'click', 'keydown'].forEach(function (kind) { root.addEventListener(kind, input, true); });
        ['play', 'emptied', 'loadstart', 'ended'].forEach(function (kind) { root.addEventListener(kind, playback, true); });
      }
      listen(document);

      // Automatic PiP follows a film, not a muted hover preview. Played
      // ranges count actual playback, even after a seek to a later time.
      function follows(v, automatic) {
        if (v.muted || v.volume === 0) return false;
        if (/(^|\\.)youtube(?:-nocookie)?\\.com$/.test(location.hostname) || location.hostname === 'youtu.be') {
          if (v.closest('ytd-video-preview, ytd-video-preview-renderer, #inline-preview-player')) return false;
          var player = v.closest('#movie_player');
          if (!player || player.querySelector('video') !== v) return false;
        }
        var seconds = played(v);
        return automatic === 2 ? starts.has(v) && seconds - starts.get(v) >= 3 : seconds >= 1;
      }
      function candidate(v, automatic) {
        return v.isConnected && playing(v) && area(v) > 0 && (!automatic || follows(v, automatic));
      }

      function fullscreen() {
        return !!(document.fullscreenElement || document.webkitFullscreenElement ||
          each('video').some(function (v) { return v.webkitDisplayingFullscreen; }));
      }

      // Asks the frame inside one of this document's frame elements, and
      // waits a little for the answer. A frame that never answers, the
      // script never reached it, it is still loading, is a frame with
      // nothing in it.
      function ask(frame, verb, argument, patience) {
        return new Promise(function (resolve, reject) {
          var win = frame && frame.contentWindow;
          if (!win) { reject(); return; }
          var id = ++count + ':' + Math.random();
          var late = setTimeout(function () { delete waiting[id]; reject(); }, patience);
          waiting[id] = function (value) { clearTimeout(late); delete waiting[id]; resolve(value); };
          win.postMessage({ yabFloat: KEY, verb: verb, argument: argument, id: id }, '*');
        });
      }

      // A press asks for a video even when none plays: one paused, or
      // loaded and not started yet. Big
      // enough to be the thing watched, not an icon or a hidden preview.
      function resting(v) {
        var box = v.getBoundingClientRect();
        return v.isConnected && v.readyState >= 1 && box.width >= 160 && box.height >= 90;
      }
      // Which of two videos a press means: one the person started, then one
      // with sound, then the bigger. The biggest alone took a muted
      // background loop over the film playing beside it.
      function rank(v) {
        return (starts.has(v) ? 2 : 0) + (!v.muted && v.volume > 0 ? 1 : 0);
      }
      function better(a, b) {
        return b.area > 0 && (b.rank > a.rank || (b.rank === a.rank && b.area > a.area));
      }

      // The playing video drawn at all, here or in any frame below, the one
      // `rank` puts first. A playing video with no size is a background
      // that has been put away. With nothing playing, a press takes the
      // resting one instead (automatic never does).
      function find(automatic) {
        var best = { el: null, area: 0, rank: -1 }, still = { el: null, area: 0, rank: -1 };
        var videos = each('video');
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i], one = { el: v, area: area(v), rank: rank(v) };
          if (candidate(v, automatic)) { if (better(best, one)) best = one; }
          else if (!automatic && resting(v) && better(still, one)) still = one;
        }
        var frames = each('iframe, frame').filter(function (f) { return area(f) > 0; });
        return Promise.all(frames.map(function (f) {
          return ask(f, 'size', automatic || 0, 400).then(
            function (a) {
              var all = Array.isArray(a) ? a : [a, 0, 0, 0], room = area(f);
              return [{ el: f, area: Math.min(+all[0] || 0, room), rank: +all[1] || 0 },
                      { el: f, area: Math.min(+all[2] || 0, room), rank: +all[3] || 0 }];
            },
            function () { return [{ el: f, area: 0, rank: 0 }, { el: f, area: 0, rank: 0 }]; }
          );
        })).then(function (inner) {
          for (var i = 0; i < inner.length; i++) {
            if (better(best, inner[i][0])) best = inner[i][0];
            if (!automatic && better(still, inner[i][1])) still = inner[i][1];
          }
          if (!best.el && !automatic && still.el) { still.resting = true; return still; }
          return best;
        });
      }
      // A video `find` handed back, still so when it is taken: a playing
      // one still playing (a hover preview that stopped meanwhile is not
      // floated), a resting one still there to be shown.
      function chosen(v, automatic, still) {
        return still ? !automatic && resting(v) : candidate(v, automatic);
      }

      function up(node) {
        var parent = node.parentNode;
        if (parent && parent.nodeType === 11 && parent.host) {
          shade(parent);
          return parent.host;
        }
        return node.parentElement;
      }
      function shade(root) {
        for (var i = 0; i < sheets.length; i++) if (sheets[i].parentNode === root) return;
        var sheet = document.createElement('style');
        sheet.textContent = SHADE;
        root.appendChild(sheet);
        sheets.push(sheet);
      }
      function unmark() {
        for (var i = 0; i < marked.length; i++) {
          marked[i].removeAttribute('data-yab-float');
          marked[i].removeAttribute('data-yab-around');
          if (marked[i].hasAttribute('data-yab-controls')) {
            marked[i].removeAttribute('data-yab-controls');
            marked[i].setAttribute('controls', '');
          }
        }
        marked = [];
        for (var j = 0; j < sheets.length; j++) {
          if (sheets[j].id !== 'yab-float' && sheets[j].parentNode) sheets[j].remove();
        }
        sheets = sheets.filter(function (s) { return s.id === 'yab-float'; });
      }
      // Where the player had put its video and the boxes around it, as it
      // wrote it on them, the moment the video went out: whatever it
      // writes there while the video fills the window is for a player the
      // whole page's size.
      var GEOMETRY = ['width', 'height', 'left', 'top'];
      var placed = null;
      function keep(els) {
        placed = placed || [];
        els.forEach(function (el) {
          if (!el.style || placed.some(function (p) { return p.el === el; })) return;
          placed.push({ el: el, at: GEOMETRY.map(function (p) { return el.style.getPropertyValue(p); }) });
        });
      }
      // Home, what the player wrote on them meanwhile is undone: the next
      // video on YouTube, an advert, were laid out at the whole page's
      // size, and a player that never lays out again until the window
      // changes size left them that size in its own player, too large and
      // too low, cut at its right and bottom (#45, again on 0.0.8).
      function replace() {
        var was = placed || [];
        placed = null;
        was.forEach(function (box) {
          if (!box.el.isConnected) return;
          GEOMETRY.forEach(function (p, i) {
            if (box.el.style.getPropertyValue(p) === box.at[i]) return;
            if (box.at[i]) box.el.style.setProperty(p, box.at[i]); else box.el.style.removeProperty(p);
          });
        });
      }
      function mark(el) {
        unmark();
        target = el;
        el.setAttribute('data-yab-float', '');
        // The engine's own controls come up over the picture on a pause or
        // a seek, and the style sheet's rule reaches only the old ones; a
        // video that has them lends them back until it lands.
        if (el.tagName === 'VIDEO' && el.hasAttribute('controls')) {
          el.setAttribute('data-yab-controls', '');
          el.removeAttribute('controls');
        }
        marked.push(el);
        for (var box = up(el); box && box !== document.body && box !== document.documentElement; box = up(box)) {
          box.setAttribute('data-yab-around', '');
          marked.push(box);
        }
        keep(marked);
        var sheet = document.getElementById('yab-float');
        if (!sheet) {
          sheet = document.createElement('style');
          sheet.id = 'yab-float';
          (document.head || document.documentElement).appendChild(sheet);
          sheets.push(sheet);
        }
        sheet.textContent = PAGE;
        document.documentElement.classList.add('yab-floating');
      }

      // A video marks itself; a frame is marked once the frame inside it has
      // floated something of its own. Moving on from one frame to another
      // puts the old one back first.
      // A search for the video takes a while, frames asked and waited for;
      // the page may go home meanwhile. `turn` counts the landings, and a
      // search begun before the last one marks nothing: the page stays as
      // its player laid it out, not as the window had it.
      var turn = 0;
      function take(el, mine, automatic, still) {
        var was = target;
        var done = function () {
          if (mine !== turn || (automatic && fullscreen())) return false;
          // Hover previews can stop or disappear while frame discovery
          // awaits its answers. Never float that stale video candidate.
          if (el.tagName === 'VIDEO' && !chosen(el, automatic, still)) return false;
          if (was && was !== el && was.tagName !== 'VIDEO') ask(was, 'off', 0, 400).catch(function () {});
          mark(el);
          return true;
        };
        if (el.tagName === 'VIDEO') return Promise.resolve(done());
        return ask(el, 'on', automatic || 0, 2000).then(
          function (answer) {
            if (!answer || answer[0] !== 'floating') return false;
            var accepted = done();
            // The child has already isolated its video. A parent entering
            // fullscreen while that answer was pending must undo it too.
            // A newer accepted request for this frame owns it already.
            if (!accepted && target !== el) ask(el, 'off', 0, 400).catch(function () {});
            return accepted;
          },
          function () { return false; }
        );
      }

      function on(automatic) {
        if (automatic && fullscreen()) return Promise.resolve('none');
        // A video filling the screen is in a window of its own; it has to
        // come back into the page before the page can be made small.
        if (document.fullscreenElement && document.exitFullscreen) {
          document.exitFullscreen().catch(function () {});
        } else if (document.webkitFullscreenElement && document.webkitExitFullscreen) {
          document.webkitExitFullscreen();
        }
        var mine = turn;
        return find(automatic).then(function (best) {
          if (!best.el) return 'none';
          return take(best.el, mine, automatic, best.resting).then(function (ok) {
            if (!ok) return 'none';
            guard(automatic);
            // With the video's own shape, so the window is made in it.
            return where().then(function (head) {
              return ['floating', head ? head[5] : 0, head ? head[6] : 0];
            });
          });
        });
      }

      // ⇧⌘P on the tab in front: only the video goes out, into WebKit's own
      // window (FloatPiP.swift), and the page stays in its tab to be read
      // and scrolled. Called from the app, it counts as a press for a few
      // seconds. A press for a video inside a frame asks that frame to put
      // its own out, which WebKit lets it do on the press passed along with
      // the message; a frame that can't answers 'frame', leaving its page
      // in place. Embedded players used to take the whole page out when
      // native PiP was refused.
      // A discovery started before fullscreen cannot resume after its exit:
      // DOM fullscreen is already false while the native owner returns.
      var fullscreenTurn = 0;
      if (typeof document.addEventListener === 'function')
        document.addEventListener('fullscreenchange', function () { fullscreenTurn++; }, true);
      function pip(automatic, exclusiveFullscreen) {
        // The Chromium owner arbitrates before dispatch. Candidate discovery
        // is asynchronous: recheck at the renderer commit point as well.
        // WebKit keeps its existing departure policy (no second argument).
        if (automatic && exclusiveFullscreen && fullscreen()) return Promise.resolve('none');
        var mine = turn, fullTurn = fullscreenTurn;
        return find(automatic).then(function (best) {
          if (mine !== turn || (automatic && exclusiveFullscreen &&
              (fullTurn !== fullscreenTurn || fullscreen()))) return 'none';
          if (!best.el) return 'none';
          if (best.el.tagName === 'VIDEO' && !chosen(best.el, automatic, best.resting)) return 'none';
          if (best.el.tagName !== 'VIDEO') {
            return ask(best.el, 'pip', automatic || 0, 3000).then(
              function (answer) { return answer === 'pip' ? 'pip' : 'frame'; },
              function () { return 'frame'; }
            );
          }
          if (best.el.tagName !== 'VIDEO' || !best.el.requestPictureInPicture) return 'frame';
          if (window.__yabPiPPlacard) window.__yabPiPPlacard.watch(best.el);
          return best.el.requestPictureInPicture().then(
            function () { return 'pip'; },
            function (e) { return 'refused:' + (e && e.name); }
          );
        });
      }

      // The mark has to be defended. Players rebuild their DOM, on a
      // quality change, an ad break, a React re-render, the next episode,
      // and the mark goes with the old element, leaving a black window over a
      // perfectly live page. So it is put back on whatever is playing now.
      function guard(automatic) {
        clearInterval(watch);
        watch = setInterval(function () {
          if (busy || (target && target.isConnected)) return;
          busy = true;
          var mine = turn;
          find(automatic).then(function (best) {
            return best.el ? take(best.el, mine, automatic, best.resting) : false;
          }).catch(function () {}).then(function () { busy = false; });
        }, 250);
      }

      function off(nativeClosing) {
        turn++;
        clearInterval(watch);
        watch = null;
        // The engine may have put the video in its own floating window as
        // well, some players ask for that themselves. Leaving one and not
        // the other leaves you with two.
        // A native dismissal already owns the exit. Clear our bookkeeping
        // without starting a second request while WebKit completes it.
        if (!nativeClosing) try {
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture().catch(function () {});
          }
          each('video').forEach(function (v) {
            if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
          });
        } catch (e) {}
        if (target && target.tagName !== 'VIDEO') ask(target, 'off', nativeClosing ? 1 : 0, 400).catch(function () {});
        var was = !!target;
        target = null;
        opened.forEach(function (track) { try { track.mode = 'disabled'; } catch (e) {} });
        opened = [];
        replace();
        unmark();
        document.documentElement.classList.remove('yab-floating');
        var sheet = document.getElementById('yab-float');
        if (sheet) sheet.remove();
        sheets = [];
        // A player writes its video's size and place on it, from the
        // player's own size, and reads that size again only when the
        // window changes size. Out in the window, the player is the whole
        // page, and a player that laid its video out meanwhile, YouTube on
        // the next video or an advert, wrote the whole page's size on it:
        // home, the video stood too large and too low in its player until
        // the window was resized. Put back as it was (`replace`), and the
        // window changing size is said once more, so it is laid out for
        // the player it is back in, a new video's shape too.
        if (was) {
          dispatchEvent(new Event('resize'));
          again(turn);
        }
        return 'landed';
      }

      // And said again once the page is in its tab and seen: the first
      // comes while the page is still in the floating window, and home by
      // Back to Tab with Yab behind another app it lands out of sight; a
      // player that lets a resize go then, or lays out a frame later from
      // a size read before, would keep the whole page's size on its video.
      function again(mine) {
        var shown = function () {
          if (document.visibilityState !== 'visible') return;
          document.removeEventListener('visibilitychange', shown);
          // After the frame the page is drawn in its tab, and only if it
          // has not gone out to the window again since.
          requestAnimationFrame(function () {
            setTimeout(function () {
              if (mine === turn && !target) dispatchEvent(new Event('resize'));
            }, 120);
          });
        };
        if (document.visibilityState === 'visible') shown();
        else document.addEventListener('visibilitychange', shown);
      }

      // A live stream's stretch, [start, edge], or null for a video; and
      // whether an advert plays in its player.
      var live = \(LiveEdge.reader);
      var advert = \(LiveEdge.advert);

      // The video the window's buttons mean: the floated one, wherever it is.
      function through(verb, argument, here) {
        if (target && target.tagName !== 'VIDEO' && target.isConnected) {
          return ask(target, verb, argument, 600).catch(function () { return null; });
        }
        var video = target && target.tagName === 'VIDEO' ? target : each('video')[0];
        return Promise.resolve(video ? here(video) : null);
      }
      // Where the video is: how far through, whether it plays, the time
      // and the length in seconds, how fast it goes, and its picture's own
      // width and height, which the window takes its shape from. Then
      // whether the picture is actually moving, not only meant to: a video
      // waiting on the network or a seek is not, and whether it is muted.
      // Last, for a live stream, which has no length (0): true, the oldest
      // moment it keeps (-1 where nobody says) and its edge (LiveEdge.swift),
      // and whether an advert plays in it.
      //
      // Nothing floated, a new document not yet taken, says nothing: the
      // first video there is as likely an advert as the film.
      function where() {
        if (!target) return Promise.resolve(null);
        return through('where', 0, function (v) {
          var d = v.duration;
          var reach = live(v);
          var length = !reach && d && isFinite(d) && d < 1e7 ? d : 0;
          return [length ? v.currentTime / length : 0, !v.paused, v.currentTime || 0, length,
                  v.playbackRate || 1, v.videoWidth || 0, v.videoHeight || 0,
                  !v.paused && v.readyState >= 3 && !v.seeking, v.muted || v.volume === 0,
                  !!reach, reach ? reach[0] : -1, reach ? reach[1] : 0, advert(v)].concat(fetched(v));
        });
      }
      // The stretch fetched around where it is, [from, to] in seconds, and
      // the video's error code.
      function fetched(v) {
        var b = v.buffered, at = v.currentTime || 0, from = 0, to = 0;
        try {
          for (var i = 0; i < b.length; i++) {
            if (b.start(i) <= at + 0.5 && b.end(i) >= at) { from = b.start(i); to = b.end(i); }
          }
        } catch (e) {}
        return [from, to, v.error ? v.error.code || 0 : 0];
      }
      // Fetches again from where it stands: a video that failed loads its
      // source anew and goes back there; one only stuck is asked for the
      // same place again, which players fetch from anew. A source made by
      // the page's own player (blob:) is its player's to reload.
      function retry() {
        return through('retry', 0, function (v) {
          var at = v.currentTime || 0;
          if (v.error && v.currentSrc && v.currentSrc.indexOf('blob:') !== 0) {
            v.addEventListener('loadedmetadata', function () {
              try { v.currentTime = at; } catch (e) {}
              v.play().catch(function () {});
            }, { once: true });
            v.load();
          } else {
            try { v.currentTime = at; } catch (e) {}
            v.play().catch(function () {});
          }
          return true;
        });
      }
      function sound(forceUnmute) {
        return through('sound', forceUnmute, function (v) {
          // Read the media element at the moment of the click. The window's
          // last poll can be older than a site's own mute button.
          var muted = forceUnmute ? false : !(v.muted || v.volume === 0);
          v.muted = muted;
          if (!muted && v.volume === 0) v.volume = 1;
          return v.muted || v.volume === 0;
        });
      }
      function toggle() {
        return through('toggle', 0, function (v) {
          if (v.paused) { v.play().catch(function () {}); return true; }
          v.pause();
          return false;
        });
      }
      function pause() {
        return through('pause', 0, function (v) {
          if (!v.paused) v.pause();
          return true;
        });
      }
      function skip(seconds) {
        return through('skip', seconds, function (v) {
          var reach = live(v);
          // Never past a live stream's edge, into a future it hasn't got.
          v.currentTime = Math.max(reach && reach[0] >= 0 ? reach[0] : 0,
                                   Math.min(reach ? reach[1] : Infinity, v.currentTime + seconds));
          return true;
        });
      }
      // To a point along it, nought to one: exactly, or, while a finger is
      // still dragging, to the nearest frame the engine can show at once.
      // On a live stream, along the stretch it keeps, 1 its edge.
      function seek(fraction, rough) {
        return through(rough ? 'scrub' : 'seek', fraction, function (v) {
          var at = Math.max(0, Math.min(1, fraction)), time;
          var reach = live(v);
          if (reach) {
            if (reach[0] < 0) return false;
            time = at >= 1 ? reach[1] : reach[0] + at * (reach[1] - reach[0]);
          } else {
            if (!v.duration || !isFinite(v.duration)) return false;
            time = at * v.duration;
          }
          if (rough && v.fastSeek) v.fastSeek(time); else v.currentTime = time;
          return true;
        });
      }
      // For the frame above: the playing video's area and rank, then the
      // resting one's, which a press falls back on.
      function size(automatic) {
        return find(automatic).then(function (best) {
          return best.resting ? [0, 0, best.area, best.rank] : [best.area, best.rank, 0, 0];
        });
      }

      // The subtitles showing now, a line to a line, or '' for none. From
      // the video's own tracks first, the ones switched on; then from the
      // layer a player draws its own in, which is what a player that turns
      // them off stops drawing, so off in the player is off here too.
      function tidy(text) {
        return String(text || '').split(/\\n+/).map(function (line) {
          return line.replace(/\\s+/g, ' ').trim();
        }).filter(Boolean).join('\\n');
      }
      function captionParent(el) {
        return el.parentElement || (el.getRootNode && el.getRootNode().host) || null;
      }
      function captionVisible(el) {
        for (var box = el; box; box = captionParent(box)) {
          var style = getComputedStyle(box);
          if (box.hidden ||
              style.display === 'none' || style.visibility === 'hidden' ||
              style.visibility === 'collapse' || style.contentVisibility === 'hidden' ||
              parseFloat(style.opacity) === 0) return false;
        }
        return true;
      }
      function playerWords(v) {
        var layers = each(CAPTIONS.join(','));
        // Only the floated video's player, not another player's retained text.
        for (var box = captionParent(v); box && box !== document.body && box !== document.documentElement; box = captionParent(box)) {
          var own = layers.filter(function (layer) {
            for (var parent = layer; parent; parent = captionParent(parent)) {
              if (parent === box) return true;
            }
            return false;
          });
          if (!own.length) continue;
          // PiP forces visibility and zero opacity on caption layers. Read
          // the player's styles synchronously, before the next paint, so a
          // hidden layer's stale innerText cannot turn subtitles back on.
          var disabled = sheets.map(function (el) {
            var sheet = el.sheet;
            var was = sheet && sheet.disabled;
            if (sheet) sheet.disabled = true;
            return [sheet, was];
          });
          try {
            for (var k = 0; k < own.length; k++) {
              if (!captionVisible(own[k])) continue;
              var words = tidy(own[k].innerText);
              if (words) return words;
            }
            return '';
          } finally {
            disabled.forEach(function (state) { if (state[0]) state[0].disabled = state[1]; });
          }
        }
        return '';
      }
      function spoken(v) {
        var lines = [];
        var tracks = v.textTracks || [];
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          // A list of chapters or of data for scripts is never words.
          if (track.kind === 'chapters' || track.kind === 'metadata') continue;
          if (track.mode !== 'showing' || !track.activeCues) continue;
          for (var j = 0; j < track.activeCues.length; j++) {
            var cue = track.activeCues[j];
            // As text, never as markup: a cue's <i> and <v Name> come out as
            // their words, and nothing in it is ever put into a page.
            var text = cue.getCueAsHTML ? cue.getCueAsHTML().textContent : String(cue.text || '').replace(/<[^>]*>/g, '');
            if (text) lines.push(text);
          }
        }
        if (lines.length) return tidy(lines.join('\\n'));
        return playerWords(v);
      }
      function words() {
        return through('words', 0, spoken);
      }

      // The video's chapters, [start in seconds, name] each: its own
      // <track kind="chapters"> first, then, on YouTube, the list the page
      // keeps for its Chapters panel, there whether the panel is open or
      // not. Only the video's own list: a page left over from the last one
      // YouTube played, while the next one's comes in, says nothing.
      var opened = [];
      function clock(text) {
        var parts = String(text || '').trim().split(':');
        if (parts.length < 2 || parts.length > 3) return -1;
        var total = 0;
        for (var i = 0; i < parts.length; i++) {
          if (!/^\\d+$/.test(parts[i])) return -1;
          total = total * 60 + (+parts[i]);
        }
        return total;
      }
      function listed(v) {
        var out = [];
        var tracks = v.textTracks || [];
        for (var i = 0; i < tracks.length; i++) {
          var track = tracks[i];
          if (track.kind !== 'chapters') continue;
          // A track switched off has no cues read; hidden, it is read and
          // still never drawn. Given back as it was when the video lands.
          if (track.mode === 'disabled') { track.mode = 'hidden'; opened.push(track); }
          var cues = track.cues || [];
          for (var j = 0; j < cues.length; j++) {
            var cue = cues[j];
            var name = cue.getCueAsHTML ? cue.getCueAsHTML().textContent : String(cue.text || '');
            out.push([cue.startTime, tidy(name).replace(/\\n/g, ' ')]);
          }
          if (out.length) return out;
        }
        if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return out;
        var flexy = document.querySelector('ytd-watch-flexy');
        if (flexy) {
          var id = new URLSearchParams(location.search).get('v');
          if (!id || flexy.getAttribute('video-id') !== id) return out;
          var panel = document.querySelector('[target-id="engagement-panel-macro-markers-description-chapters"]') ||
            document.querySelector('[target-id="engagement-panel-macro-markers-auto-chapters"]');
          var items = panel ? panel.querySelectorAll('ytd-macro-markers-list-item-renderer') : [];
          for (var k = 0; k < items.length; k++) {
            // The page says it is the next video a moment before the list
            // is the next video's: each chapter links to the video it is in.
            var link = items[k].querySelector('a#endpoint');
            var href = link && link.getAttribute('href');
            if (!href || new URL(href, location.href).searchParams.get('v') !== id) return [];
            var heading = items[k].querySelector('h3.macro-markers, h4');
            var time = clock((items[k].querySelector('#time') || {}).textContent);
            if (time < 0) continue;
            out.push([time, tidy(heading && (heading.getAttribute('title') || heading.textContent)).replace(/\\n/g, ' ')]);
          }
          if (out.length) return out;
        }
        // No list with names, a page that has none or a player embedded
        // in another site's that draws its bar: the player's own bar, a
        // piece to a chapter, says where each starts, if not what it is
        // called. Its widths leave the gaps out, so they are summed, not
        // measured against the bar; on a 19-minute video within 4 s.
        var player = v.closest('.html5-video-player');
        var pieces = player ? player.querySelectorAll('.ytp-chapter-hover-container') : [];
        var length = v.duration;
        if (pieces.length < 2 || !(length > 0) || !isFinite(length)) return out;
        var widths = [], total = 0;
        for (var p = 0; p < pieces.length; p++) {
          var wide = parseFloat(pieces[p].style.width) || pieces[p].getBoundingClientRect().width;
          if (!(wide > 0)) return out;
          widths.push(wide);
          total += wide;
        }
        for (var q = 0, run = 0; q < widths.length; q++) {
          out.push([run / total * length, '']);
          run += widths[q];
        }
        return out;
      }
      function chapters() {
        return through('chapters', 0, function (v) {
          try { return listed(v); } catch (e) { return []; }
        });
      }

      // The speed it plays at: set when asked with one above nought, and
      // always answered as the video has it now.
      function rate(speed) {
        return through('rate', speed, function (v) {
          if (speed > 0) { try { v.playbackRate = speed; } catch (e) {} }
          return v.playbackRate || 1;
        });
      }

      // The video's own subtitles, its <track>s of words: [the one showing
      // or -1, [their names]]. Asked with -2 it only says; -1 turns them
      // all off; a number shows that one and no other. A player that keeps
      // its own (YouTube's) is asked in the page's world instead
      // (Floater.youTubeSubtitles).
      function subtitles(choice) {
        return through('subtitles', choice, function (v) {
          var all = v.textTracks || [], list = [];
          for (var i = 0; i < all.length; i++) {
            if (all[i].kind === 'subtitles' || all[i].kind === 'captions') list.push(all[i]);
          }
          if (choice >= -1) list.forEach(function (track, k) {
            try { track.mode = k === choice ? 'showing' : 'disabled'; } catch (e) {}
          });
          var now = -1;
          list.forEach(function (track, k) { if (track.mode === 'showing' && now < 0) now = k; });
          return [now, list.map(function (track) { return String(track.label || track.language || ''); })];
        });
      }

      // WebKit's own video out in Yab's window (FloatPiP.swift): the page
      // stays as it is, and the window's buttons mean that video, here or
      // in a frame below.
      function picture() {
        var el = document.pictureInPictureElement;
        if (el) {
          turn++;
          target = el;
          return where().then(function (head) {
            return ['floating', head ? head[5] : 0, head ? head[6] : 0];
          });
        }
        var frames = each('iframe, frame').filter(function (f) { return area(f) > 0; });
        return Promise.all(frames.map(function (f) {
          return ask(f, 'picture', 0, 600).then(
            function (a) { return a && a[0] === 'floating' ? f : null; },
            function () { return null; }
          );
        })).then(function (found) {
          var f = found.filter(Boolean)[0];
          if (!f) return 'none';
          turn++;
          target = f;
          return ['floating', 0, 0];
        });
      }

      var verbs = {
        on: on, pip: pip, picture: picture, off: off, where: where, toggle: toggle, pause: pause, skip: skip, sound: sound, size: size, words: words, chapters: chapters,
        rate: rate, subtitles: subtitles, retry: retry,
        seek: function (f) { return seek(f, false); }, scrub: function (f) { return seek(f, true); }
      };

      window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || typeof data !== 'object' || data.yabFloat !== KEY) return;
        // Ours, and nobody else's business.
        event.stopImmediatePropagation();
        if (data.reply) {
          if (waiting[data.id]) waiting[data.id](data.value);
          return;
        }
        // Only ever from the frame this one is in.
        if (window.parent === window || event.source !== window.parent) return;
        var verb = verbs[data.verb];
        if (!verb) return;
        Promise.resolve(verb(data.argument)).catch(function () { return null; }).then(function (value) {
          event.source.postMessage({ yabFloat: KEY, reply: true, id: data.id, value: value }, '*');
        });
      }, true);

      window.__yabFloat = verbs;
    })();
    """
}
