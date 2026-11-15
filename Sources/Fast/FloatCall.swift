import AppKit

// A call in the floating window.
//
// The page moves into the window as a video's does (Floater), but what it
// shows is yab's, not the page's: the people with their cameras on, laid
// out over the page by CallStage, and under the pointer what a call needs
// from wherever you are: the microphone, the camera, the screen, Leave.
// The microphone and the camera are the call's own switches (CallRelay) or
// WebKit's, which is what the dot on the tab shows, so the window, the dot
// and the menu can never disagree. Their devices are chosen in the page's
// own menus (CallStage), so the page keeps being the one that knows.

/// The buttons over a call: the microphone and the camera, each with an
/// arrow for its devices when there is a choice, the screen, and Leave
/// along the bottom; away and back to the tab in the top corners; a still
/// mark in the corner while you are muted, showing your screen or have your
/// hand up, whatever else is showing. Everything a hand does to the window is FloatHand's,
/// the video window's own.
final class CallControls: FloatHand {
    var onMic: (() -> Void)?
    var onCamera: (() -> Void)?
    var onShare: (() -> Void)?
    var onLeave: (() -> Void)?
    /// The menu of the microphone's or the camera's devices, built as it
    /// opens, from the arrow or a right-click on the button.
    var menuFor: ((Devices) -> NSMenu?)?
    enum Devices { case mic, camera }
    /// How much of the window's foot is taken, in points: by the row, a
    /// word standing in its place, the field to answer the chat. Your
    /// picture in the corner, the names and the captions step up over it
    /// (CallStage).
    var onBand: ((CGFloat) -> Void)?
    private var band: CGFloat = 0
    /// What the window asks of the page beyond the microphone and the
    /// camera: let someone in, a hand, captions, a reaction, a message.
    var onAsk: ((CallAsk) -> Void)?

    private let close = FloatButton()
    private let back = FloatButton()
    private let mic = FloatButton()
    private let camera = FloatButton()
    private let share = FloatButton()
    private let leave = FloatButton()
    /// The arrows, and the pill each makes with its button.
    private let micMore = FloatButton()
    private let cameraMore = FloatButton()
    private let micPill = FloatGlass.media(cornerRadius: 19) // design: capsule, half its 38 pt height
    private let cameraPill = FloatGlass.media(cornerRadius: 19) // design: capsule, half its 38 pt height
    private var glass: [ObjectIdentifier: FloatGlass] = [:]
    private let mutedPlate = FloatGlass.media(cornerRadius: 12) // design: capsule, half its 24 pt height
    private let showingPlate = FloatGlass.media(cornerRadius: 12) // design: capsule, half its 24 pt height
    private let handPlate = FloatGlass.media(cornerRadius: 12) // design: capsule, half its 24 pt height
    private lazy var micMark = Turn(on: mic, "mic", "mic.slash", size: 15)
    private lazy var cameraMark = Turn(on: camera, "video", "video.slash", size: 15)
    private lazy var shareMark = Turn(on: share, "screen.share", "screen.share.stop", size: 15, ink: CallControls.ink)
    /// Muted, showing your screen, and your hand up, while the buttons are
    /// away: 24 pt plates 14 in from the bottom left, 28 apart.
    private let muted = NSImageView()
    private let showing = NSImageView()
    private let raised = NSImageView()
    /// A word about a device come or gone, over the row: "AirPods Pro
    /// connected" with Use, or what the call hears now.
    private let note = FloatGlass.media(cornerRadius: 14) // design: capsule, half its 28 pt height
    private let noteWords = NSTextField(labelWithString: "")
    private let noteUse = NSButton()
    private var noteAct: (() -> Void)?
    private var noteTimer: Timer?
    /// The meeting's last five minutes, when the calendar knows its end:
    /// the words, on a tag of their own that centers them.
    private let left = FloatGlass.media(cornerRadius: 10) // design: capsule, half its 20 pt height
    private let leftWords = NSTextField(labelWithString: "")
    private var minutesLeft: Int?

    /// The rest of a call, behind ⋯: the row turns into a second one (your
    /// hand, the captions, a reaction, the chat, and back), and a reaction
    /// into a row of faces to send. Leave stays where it is, so does ‹.
    enum Row { case main, more, faces }
    private(set) var row = Row.main
    private let more = FloatButton()
    /// Your hand, in the main row while it is up, light: one press puts it down.
    private let handUp = FloatButton()
    private let hand = FloatButton()
    private let captions = FloatButton()
    private let react = FloatButton()
    private let chat = FloatButton()
    private let backRow = FloatButton()
    private let facesPlate = FloatGlass.media(cornerRadius: 19) // design: capsule, half its 38 pt height
    static let faces = ["💖", "👍", "🎉", "👏", "😂", "😮", "😢"]
    private var faceButtons: [NSButton] = []
    /// Messages come since the chat was last opened from here, on ⋯ and on
    /// the chat.
    private let unreadMore = NSTextField(labelWithString: "")
    private let unreadChat = NSTextField(labelWithString: "")
    private(set) var news = CallNews()
    /// Along the top: "● Rec", and someone asking to come in.
    let island = CallIsland()
    /// The chat's field, over the row, where a message is answered.
    let reply = CallReply()

    private var state: (mic: PageMediaState, camera: PageMediaState) = (.none, .none)
    /// What a press has already shown, off or on, before the page has
    /// said so: the microphone's and the camera's. Nil when the buttons
    /// wear what WebKit says.
    private var pending: (mic: Bool?, camera: Bool?) = (nil, nil)
    private var pendingTimer: [Devices: Timer] = [:]
    private var micOff: Bool { pending.mic ?? (state.mic == .muted) }
    private var cameraOff: Bool { pending.camera ?? (state.camera == .muted) }
    /// The camera's mark crossed: off, or no camera in the call at all.
    private var cameraCrossed: Bool { pending.camera ?? (state.camera == .muted || state.camera == .none) }
    /// Showing your screen, whether the page has a Share of its own to
    /// press, and whether the microphone's and the camera's menus have a
    /// choice of devices: what the row is made of.
    private var presenting = false
    private var sharable = false
    private var choice: (mic: Bool, camera: Bool) = (false, false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The pills go in first, under the buttons they hold.
        for pill in [micPill, cameraPill] {
            addSubview(pill)
        }
        dress(close, "xmark", 11, action: #selector(pressedClose), help: "Back into its tab", side: .below)
        dress(back, "pip.exit", 12, action: #selector(pressedReturn), help: "Go to the call", side: .below)
        dress(micMore, "chevron.up", 10, action: #selector(pressedMicMore), help: "Microphone and speaker")
        dress(cameraMore, "chevron.up", 10, action: #selector(pressedCameraMore), help: "Camera")
        dress(mic, "mic", 15, action: #selector(pressedMic), help: "Mute")
        dress(camera, "video", 15, action: #selector(pressedCamera), help: "Turn camera off")
        dress(share, "screen.share", 15, action: #selector(pressedShare), help: "Share screen")
        dress(leave, "phone.down", 17, action: #selector(pressedLeave), help: "Leave the call")
        surface(leave).tintColor = CallControls.red
        dress(more, "ellipsis", 15, action: #selector(pressedMore), help: "More")
        dress(handUp, "hand.raised", 15, action: #selector(pressedHand), help: "Lower hand")
        handUp.contentTintColor = CallControls.ink
        surface(handUp).tintColor = CallControls.light
        dress(hand, "hand.raised", 15, action: #selector(pressedHand), help: "Raise hand")
        dress(captions, "captions.bubble", 15, action: #selector(pressedCaptions), help: "Captions")
        dress(react, "face.smiling", 15, action: #selector(pressedReact), help: "Send a reaction")
        dress(chat, "bubble", 15, action: #selector(pressedChat), help: "Message everyone")
        dress(backRow, "chevron.left", 13, action: #selector(pressedBackRow), help: "Back")
        addSubview(facesPlate)
        for face in CallControls.faces {
            let button = FloatButton()
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.attributedTitle = NSAttributedString(string: face, attributes: [.font: NSFont.systemFont(ofSize: 17)])
            button.target = self
            button.action = #selector(pressedFace(_:))
            button.setAccessibilityLabel("React with " + face)
            facesPlate.content.addSubview(button)
            faceButtons.append(button)
        }
        for count in [unreadMore, unreadChat] {
            count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            count.textColor = CallControls.ink
            count.alignment = .center
            count.wantsLayer = true
            count.layer?.backgroundColor = NSColor.white.cgColor
            count.layer?.cornerRadius = 7.5
            count.isHidden = true
            addSubview(count)
        }
        island.onAsk = { [weak self] ask in self?.poke(); self?.onAsk?(ask) }
        island.onResize = { [weak self] in self?.needsLayout = true }
        addSubview(island)
        // Sent words go into the thread over the field (CallStage `thread`).
        reply.onSend = { [weak self] words in self?.onAsk?(.send(words)) }
        reply.onDone = { [weak self] in self?.onAsk?(.thread(false)); self?.needsLayout = true; self?.tellBand() }
        addSubview(reply)
        for more in [micMore, cameraMore] {
            more.layer?.backgroundColor = NSColor.clear.cgColor
            more.contentTintColor = NSColor(white: 1, alpha: 0.82)
            more.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            more.isHidden = true
        }
        mic.onPress = { [weak self] press in self?.pressed(.mic, press) }
        camera.onPress = { [weak self] press in self?.pressed(.camera, press) }
        mic.onSecondary = { [weak self] in self?.open(.mic) }
        camera.onSecondary = { [weak self] in self?.open(.camera) }
        mic.image = nil
        camera.image = nil
        share.image = nil
        micMark.set(false, now: true)
        cameraMark.set(false, now: true)
        shareMark.set(false, now: true)
        share.isHidden = true

        for (badge, plate, symbol, ground, ink) in [(muted, mutedPlate, "mic.slash", CallControls.red, NSColor.white),
                                                    (showing, showingPlate, "screen.share", CallControls.light, CallControls.ink),
                                                    (raised, handPlate, "hand.raised", CallControls.light, CallControls.ink)] {
            badge.image = Glyphs.image(symbol, size: 11)
            badge.contentTintColor = ink
            badge.imageScaling = .scaleNone
            plate.tintColor = ground
            badge.isHidden = true
            plate.isHidden = true
            plate.content.addSubview(badge)
            addSubview(plate)
        }

        note.alphaValue = 0
        note.isHidden = true
        noteWords.font = .systemFont(ofSize: 12)
        noteWords.textColor = .white
        noteWords.lineBreakMode = .byTruncatingTail
        note.content.addSubview(noteWords)
        noteUse.title = "Use"
        noteUse.font = .systemFont(ofSize: 12, weight: .semibold)
        noteUse.contentTintColor = .white
        noteUse.attributedTitle = NSAttributedString(string: "Use", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        noteUse.isBordered = false
        noteUse.wantsLayer = true
        noteUse.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        noteUse.layer?.cornerRadius = 10
        noteUse.target = self
        noteUse.action = #selector(pressedNote)
        note.content.addSubview(noteUse)
        addSubview(note)

        leftWords.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        leftWords.textColor = .white
        leftWords.alignment = .center
        left.content.addSubview(leftWords)
        left.alphaValue = 0
        addSubview(left)

        faded.forEach { $0.alphaValue = 0 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var buttons: [NSButton] {
        [close, back, mic, camera, share, leave, micMore, cameraMore, more, handUp, hand, captions, react, chat, backRow] + faceButtons
    }
    override var faded: [NSView] {
        let all: [NSView] = [surface(close), surface(back), micPill, cameraPill, surface(share), surface(leave),
                             surface(more), surface(handUp), surface(hand), surface(captions), surface(react),
                             surface(chat), surface(backRow), facesPlate, unreadMore, unreadChat]
        return minutesLeft == nil ? all : all + [left]
    }
    override var pressable: [NSView] { buttons + [noteUse] + island.pressable + (reply.isHidden ? [] : [reply.field]) }
    override func didFade(_ up: Bool) {
        // The row stays as it was left: only ‹ (or a face picked) turns it
        // back, so the pointer slipping off the window closes nothing.
        muted.isHidden = up || !micOff
        showing.isHidden = up || !presenting
        raised.isHidden = up || !news.myHand
        // A word up goes over the row as the buttons come, and back into
        // the row's place as they go, in their time.
        if !note.isHidden {
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window?.isVisible != true
            let to = noteFrame()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduced ? 0 : up ? 0.16 : 0.3
                context.timingFunction = markCurve
                note.animator().frame = to
            }
        }
        needsLayout = true
        tellBand()
    }

    private func tellBand() {
        var taken: CGFloat = near || noteTimer != nil ? 14 + 38 + 8 : 0
        if !reply.isHidden { taken = (near ? taken : 14) + 28 + 6 }
        guard taken != band else { return }
        band = taken
        onBand?(taken)
    }

    /// The call's news, as read: the island, your hand, the second row, how
    /// many messages wait.
    func show(news: CallNews) {
        guard news != self.news else { return }
        self.news = news
        island.show(news, narrow: bounds.width < 300)
        handUp.keyTip("Lower hand", side: .above)
        hand.keyTip(news.myHand ? "Lower hand" : "Raise hand", side: .above)
        surface(hand).tintColor = news.myHand ? CallControls.light : nil
        hand.contentTintColor = news.myHand ? CallControls.ink : .white
        surface(captions).tintColor = news.captions ? CallControls.light : nil
        captions.contentTintColor = news.captions ? CallControls.ink : .white
        for (count, shown) in [(unreadMore, news.unread), (unreadChat, news.unread)] {
            count.stringValue = shown > 9 ? "9+" : "\(shown)"
        }
        // A message, a knock, a hand come the same with the pointer away:
        // on the people and the island, never by bringing the buttons up.
        raised.isHidden = near || !news.myHand
        needsLayout = true
    }

    /// Meet's red, a touch deeper, so white holds on it.
    static let red = NSColor(srgbRed: 0.85, green: 0.19, blue: 0.16, alpha: 1)
    /// A switch that is on and light: your screen shown, dark on white.
    private static let light = NSColor(white: 1, alpha: 0.94)
    private static let ink = NSColor(white: 0.07, alpha: 1)

    private func dress(_ button: NSButton, _ symbol: String, _ size: CGFloat, action: Selector, help: String, side: KeyTip.Side = .above) {
        button.image = Glyphs.image(symbol, size: size)
        button.contentTintColor = .white
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.keyTip(help, side: side)
        button.setAccessibilityLabel(help)
        button.wantsLayer = true
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.55
        button.layer?.shadowRadius = 1
        button.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        let material: FloatGlass
        if button === mic || button === micMore {
            material = micPill
        } else if button === camera || button === cameraMore {
            material = cameraPill
        } else {
            material = FloatGlass.media(cornerRadius: 19) // design: media button, half its 38 pt height; corner buttons resize to 28 pt
            addSubview(material)
        }
        material.content.addSubview(button)
        glass[ObjectIdentifier(button)] = material
    }

    private func surface(_ button: NSButton) -> FloatGlass { glass[ObjectIdentifier(button)]! }
    private func box(_ view: NSView) -> NSRect { convert(view.bounds, from: view) }
    private func place(_ button: NSButton, at frame: NSRect) {
        let material = surface(button)
        material.frame = frame
        material.cornerRadius = frame.height / 2
        button.frame = NSRect(origin: .zero, size: frame.size)
        button.layer?.cornerRadius = frame.height / 2
    }

    /// What WebKit says the page has now: the buttons wear it, red when off.
    func show(mic: PageMediaState, camera: PageMediaState) {
        guard mic != state.mic || camera != state.camera else { return }
        // The first word from WebKit sets them as they are; after that a
        // change turns over.
        let now = state == (.none, .none) || window?.isVisible != true
        state = (mic, camera)
        // The page agreeing with a press: nothing more to show.
        if pending.mic == (mic == .muted) { settle(.mic) }
        if pending.camera == (camera == .muted) { settle(.camera) }
        let micOff = self.micOff
        micMark.set(micOff, now: now)
        let micSays = micOff ? "Unmute" : "Mute"
        self.mic.keyTip(micSays, side: .above)
        self.mic.setAccessibilityLabel(micSays)
        self.mic.isEnabled = mic != .none
        let cameraOff = self.cameraOff
        cameraMark.set(cameraCrossed, now: now)
        let cameraSays = cameraOff ? "Turn camera on" : "Turn camera off"
        self.camera.keyTip(cameraSays, side: .above)
        self.camera.setAccessibilityLabel(cameraSays)
        self.camera.isEnabled = camera != .none
        muted.isHidden = !micOff || near
        needsLayout = true
    }

    /// Your screen shown or not, whether the page has a Share to press, and
    /// whether each menu has devices to choose from: the row as it is made.
    func show(presenting: Bool, sharable: Bool, choice: (mic: Bool, camera: Bool)) {
        guard presenting != self.presenting || sharable != self.sharable || choice != self.choice else { return }
        let now = window?.isVisible != true
        self.presenting = presenting
        self.sharable = sharable
        self.choice = choice
        shareMark.set(presenting, now: now)
        surface(share).tintColor = presenting ? CallControls.light : nil
        let shareSays = presenting ? "Stop sharing" : "Share screen"
        share.keyTip(shareSays, side: .above)
        share.setAccessibilityLabel(shareSays)
        showing.isHidden = !presenting || near
        needsLayout = true
    }

    /// A word for a few seconds, in the row's place while the buttons are
    /// away and over the row while they show: a device come, with Use, or
    /// what the call hears now that one went.
    func say(_ words: String, use: (() -> Void)? = nil, for seconds: TimeInterval) {
        noteTimer?.invalidate()
        noteWords.stringValue = words
        noteAct = use
        noteUse.isHidden = use == nil
        note.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        fadeNote(to: 1)
        noteTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hush() }
        }
        tellBand()
    }

    /// The word, gone.
    func hush() {
        noteTimer?.invalidate()
        noteTimer = nil
        noteAct = nil
        fadeNote(to: 0)
        tellBand()
    }

    /// Where the word stands: over the row while the buttons show; in the
    /// row's own place, its middle the row's, while they are away, clear of
    /// the marks in the corner. As wide as its words, the field's own inset
    /// on either side of them, and Use.
    private func noteFrame() -> NSRect {
        let font = noteWords.font ?? .systemFont(ofSize: 12)
        let words = (noteWords.stringValue as NSString).size(withAttributes: [.font: font])
        let use: CGFloat = noteUse.isHidden ? 0 : 38
        let side: CGFloat = 38, tall: CGFloat = 28
        var wide = min(bounds.width - 28, 8 + ceil(words.width) + 6 + (use > 0 ? 5 + use + 4 : 8))
        var x = ((bounds.width - wide) / 2).rounded()
        guard !near else { return NSRect(x: x, y: 14 + side + 8, width: wide, height: tall) }
        let marks = [muted, showing, raised].filter { !$0.isHidden }.count
        if marks > 0 {
            let clear = 14 + CGFloat(marks) * 28 + 4
            if x < clear {
                x = clear
                wide = min(wide, bounds.width - 14 - clear)
            }
        }
        return NSRect(x: x, y: 14 + ((side - tall) / 2).rounded(), width: wide, height: tall)
    }

    private func fadeNote(to alpha: CGFloat) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window?.isVisible != true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : 0.16
            note.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, alpha == 0, self.noteTimer == nil else { return }
                self.note.isHidden = true
            }
        }
    }

    /// "5 min left", up with the buttons; and by itself for a few seconds
    /// as it first shows and at two, however still the pointer is.
    func show(left minutes: Int?) {
        guard minutes != minutesLeft else { return }
        let was = minutesLeft
        minutesLeft = minutes
        leftWords.stringValue = minutes.map { "\($0) min left" } ?? ""
        needsLayout = true
        guard let minutes else { left.alphaValue = 0; return }
        if near { left.alphaValue = 1 }
        if was == nil || minutes == 2 { poke() }
    }

    override func layout() {
        super.layout()
        // The video PiP's same corner controls and inset.
        place(close, at: NSRect(x: 6, y: bounds.height - 34, width: 28, height: 28))
        place(back, at: NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 28, height: 28))

        // Along the bottom, 14 up, in a row, the size of the video's skip
        // buttons, Leave the wider, as its play is the larger: 38, Leave 52,
        // 8 apart at every width. The microphone and the camera take an
        // arrow for their devices when there is a choice and room: a pill,
        // the button round at its left end and the arrow in its right.
        // Under 300 points the arrows go (a right-click on the button opens
        // the same menu) and Share goes behind ⋯, into the second row.
        let roomy = bounds.width >= 300
        let side: CGFloat = 38, wide: CGFloat = 52, gap: CGFloat = 8, arrow: CGFloat = 16
        let showsShare = sharable || presenting
        let shareMain = showsShare && roomy, shareMore = showsShare && !roomy
        let showsMore = news.hasMore || shareMore
        var bar: [(NSButton, CGFloat)] = []
        for (button, more, has) in [(mic, micMore, choice.mic), (camera, cameraMore, choice.camera)] {
            let pilled = roomy && has
            more.isHidden = !pilled
            bar.append((button, pilled ? side + arrow : side))
        }
        if shareMain { bar.append((share, side)) }
        if news.myHand { bar.append((handUp, side)) }
        if showsMore { bar.append((more, side)) }
        bar.append((leave, wide))
        let rowWidth = bar.reduce(0) { $0 + $1.1 } + gap * CGFloat(bar.count - 1)
        var x = ((bounds.width - rowWidth) / 2).rounded()
        var leaveX = x + rowWidth - wide
        // Every row in the middle of the window, Leave at its right end:
        // the second row and the faces, wider than the main row, carry ‹
        // and Leave over with them in the shift.
        var second: [(NSButton, CGFloat)] = []
        if self.row == .more {
            if shareMore { second.append((share, side)) }
            if news.canHand { second.append((hand, side)) }
            if news.canCaptions { second.append((captions, side)) }
            if news.canReact { second.append((react, side)) }
            if news.canChat { second.append((chat, side)) }
        }
        let main = self.row == .main, inMore = self.row == .more
        var leaveShown = true
        let before = rowSurfaces.filter { !$0.isHidden }
        for (button, shown) in [(mic, main), (camera, main), (share, (main && shareMain) || (inMore && shareMore)),
                                (handUp, main && news.myHand), (more, main && showsMore), (hand, inMore && news.canHand),
                                (captions, inMore && news.canCaptions), (react, inMore && news.canReact),
                                (chat, inMore && news.canChat), (backRow, !main)] {
            button.isHidden = !shown
            surface(button).isHidden = !shown
        }
        micPill.isHidden = !main
        cameraPill.isHidden = !main
        facesPlate.isHidden = self.row != .faces
        if !main {
            var items = second.map { ($0.0 as NSView, $0.1) }
            if self.row == .faces {
                // The design's ribbon: seven faces in 178, four in 140 when narrow.
                items = [(facesPlate as NSView, roomy ? 178 : 140)]
            }
            items.append((backRow as NSView, side))
            var space = gap
            var across = items.reduce(0) { $0 + $1.1 } + space * CGFloat(items.count - 1)
            var at = ((bounds.width - across - gap - wide) / 2).rounded()
            leaveX = at + across + gap
            if at < 6 {
                if roomy {
                    // Too wide for the middle: from the edge's inset.
                    at = 6
                    leaveX = at + across + gap
                } else {
                    // Narrow, there is no room beside Leave: the row has the
                    // whole width while it is up and Leave steps out where it
                    // stands, back with the main row. The gaps close up to 4
                    // before anything is left out.
                    leaveShown = false
                    let free = bounds.width - 12 - items.reduce(0) { $0 + $1.1 }
                    space = max(4, min(gap, (free / CGFloat(max(items.count - 1, 1))).rounded(.down)))
                    across = items.reduce(0) { $0 + $1.1 } + space * CGFloat(items.count - 1)
                    at = ((bounds.width - across) / 2).rounded()
                }
            }
            for (view, width) in items {
                let frame = NSRect(x: at, y: 14, width: width, height: side)
                if let button = view as? NSButton { place(button, at: frame) } else {
                    view.frame = frame
                    facesPlate.cornerRadius = side / 2
                    let shown = roomy ? faceButtons : Array(faceButtons.prefix(4))
                    let each = (width - 8) / CGFloat(shown.count)
                    for button in faceButtons { button.isHidden = !shown.contains(button) }
                    // Each face a circle of its share of the ribbon, in the
                    // middle of its height: the pointer lights a round of it.
                    let round = min(each, side - 8).rounded(.down)
                    for (index, button) in shown.enumerated() {
                        button.frame = NSRect(x: 4 + CGFloat(index) * each + (each - round) / 2, y: (side - round) / 2,
                                              width: round, height: round)
                        button.wantsLayer = true
                        button.layer?.cornerRadius = round / 2
                    }
                }
                at += width + space
            }
        }
        leave.isHidden = !leaveShown
        surface(leave).isHidden = !leaveShown
        if leaveShown {
            // Leave goes with its row, in the row's own step, from where it was.
            let was = surface(leave).frame.minX
            place(leave, at: NSRect(x: leaveX, y: 14, width: wide, height: side))
            if self.row != laidRow, was != 0, was != leaveX, window?.isVisible == true,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = surface(leave).layer {
                let glide = CABasicAnimation(keyPath: "transform")
                glide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(was - leaveX, 0, 0))
                glide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                glide.duration = 0.15
                glide.timingFunction = markCurve
                layer.add(glide, forKey: "row.leave")
            }
        }
        for (view, width) in bar where main {
            if view === mic || view === camera, let button = view as? FloatButton {
                let more = button === mic ? micMore : cameraMore
                let pill = button === mic ? micPill : cameraPill
                button.frame = NSRect(x: 0, y: 0, width: side, height: side)
                more.frame = NSRect(x: side, y: 0, width: width - side, height: side)
                pill.frame = NSRect(x: x, y: 14, width: width, height: side)
                pill.cornerRadius = side / 2
                more.layer?.cornerRadius = side / 2
            } else if view !== leave {
                place(view, at: NSRect(x: x, y: 14, width: width, height: side))
            }
            view.layer?.cornerRadius = side / 2
            x += width + gap
        }
        if self.row != laidRow {
            shift(from: laidRow, to: self.row, before: before)
            laidRow = self.row
        }
        // How many messages wait, on the corner of ⋯ and of the chat: 26 in
        // and 4 over its top, the design's.
        for (count, on) in [(unreadMore, more), (unreadChat, chat)] {
            let frame = box(on)
            count.isHidden = news.unread == 0 || on.isHidden
            count.frame = NSRect(x: frame.minX + 26, y: frame.maxY - 11, width: max(15, count.intrinsicContentSize.width + 6), height: 15)
        }
        // The island, along the top in the middle, between the corners; the
        // list stops 6 clear of the row.
        island.room = bounds.height - 8 - (14 + side + 6)
        island.place()
        // The field over the row, or in its place with the buttons away.
        let field = min(300, bounds.width - 28)
        reply.frame = NSRect(x: ((bounds.width - field) / 2).rounded(), y: near ? 14 + side + 8 : 14, width: field, height: 28)
        // Tint the entire device capsule, keeping the arrow on the same
        // native surface as its switch.
        tint()
        micMark.layout()
        cameraMark.layout()
        shareMark.layout()
        // The marks, from the corner in: muted, your screen, your hand.
        var markX: CGFloat = 14
        for (badge, plate) in [(muted, mutedPlate), (showing, showingPlate), (raised, handPlate)] {
            plate.isHidden = badge.isHidden
            plate.frame = NSRect(x: markX, y: 14, width: 24, height: 24)
            badge.frame = plate.bounds
            if !badge.isHidden { markX += 28 }
        }

        // The word, where it stands now (noteFrame).
        let font = noteWords.font ?? .systemFont(ofSize: 12)
        let line = ceil(font.ascender - font.descender + font.leading)
        let use: CGFloat = noteUse.isHidden ? 0 : 38
        let spot = noteFrame()
        if note.frame != spot { note.frame = spot }
        noteWords.frame = NSRect(x: 8, y: ((28 - line) / 2).rounded(), width: spot.width - 8 - (use > 0 ? use + 9 : 8), height: line)
        noteUse.frame = NSRect(x: spot.width - use - 4, y: 4, width: use, height: 20)
        noteUse.layer?.cornerRadius = 10
        // In line with the two corner buttons, their middle its middle.
        let size = leftWords.intrinsicContentSize
        let across = (size.width + 12).rounded(), tall: CGFloat = 20
        left.frame = NSRect(x: ((bounds.width - across) / 2).rounded(), y: bounds.height - 20 - tall / 2 - (island.isHidden ? 0 : island.frame.height + 6),
                            width: across, height: tall)
        leftWords.frame = NSRect(x: 0, y: ((tall - size.height) / 2).rounded(), width: across, height: size.height)
        tellOverlay()
    }

    /// What the stage keeps clear of (CallAsk.overlay): the island where it
    /// is heading, and the corner's marks while the buttons are away.
    private var overlaid: (island: NSRect, marks: CGFloat)?
    private func tellOverlay() {
        let isle = island.isHidden && island.shape == .none ? .zero : island.size(in: bounds.width)
        let rect = isle == .zero ? NSRect.zero : NSRect(x: ((bounds.width - isle.width) / 2).rounded(), y: 8, width: isle.width, height: isle.height)
        let marks: CGFloat = !near && [muted, showing, raised].contains(where: { !$0.isHidden }) ? 14 + 24 + 6 : 0
        guard overlaid?.island != rect || overlaid?.marks != marks else { return }
        overlaid = (rect, marks)
        onAsk?(.overlay(island: rect, marks: marks))
    }

    /// The row's glass, each a surface of its own.
    private var rowSurfaces: [NSView] {
        [micPill, cameraPill, surface(share), surface(handUp), surface(more), surface(hand), surface(captions),
         surface(react), surface(chat), surface(backRow), facesPlate, surface(leave)]
    }
    private var laidRow = Row.main

    /// The row turned over (the design's C): what goes moves 16 points the
    /// way the row goes and fades, what comes moves in from the other side,
    /// 0.15 s; ⋯ turns a quarter as it goes and ‹ comes in where it was;
    /// Leave, in both rows, doesn't move. Reduce Motion: at once.
    private func shift(from old: Row, to new: Row, before: [NSView]) {
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let deeper = new == .faces || (old == .main && new == .more)
        let step: CGFloat = deeper ? -16 : 16
        let now = rowSurfaces.filter { !$0.isHidden }
        let leaving = before.filter { !now.contains($0) }
        let coming = now.filter { !before.contains($0) }
        let turning = surface(more)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(markCurve)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // Gone: hidden again, then let go of.
                for view in leaving {
                    view.isHidden = true
                    view.layer?.removeAnimation(forKey: "row.move")
                    view.layer?.removeAnimation(forKey: "row.fade")
                }
                self?.needsLayout = true
            }
        }
        for view in leaving {
            guard let layer = view.layer else { continue }
            view.isHidden = false
            let to: CATransform3D
            if view === turning {
                let w = view.bounds.width / 2, h = view.bounds.height / 2
                to = CATransform3DTranslate(CATransform3DRotate(CATransform3DMakeTranslation(w, h, 0), -.pi / 2, 0, 0, 1), -w, -h, 0)
            } else {
                to = CATransform3DMakeTranslation(step, 0, 0)
            }
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            move.toValue = NSValue(caTransform3D: to)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            for animation in [move, fade] {
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            layer.add(move, forKey: "row.move")
            layer.add(fade, forKey: "row.fade")
        }
        for view in coming {
            guard let layer = view.layer else { continue }
            // ‹ comes in where ⋯ turned away, without moving.
            let still = view === surface(backRow) && old == .main
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(still ? 0 : -step, 0, 0))
            move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = layer.opacity
            layer.add(move, forKey: "row.in")
            layer.add(fade, forKey: "row.in.fade")
        }
        CATransaction.commit()
    }

    /// Asked to show before the window was up: shown now it is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, minutesLeft != nil else { return }
        fade(to: 0, over: 0)
        poke()
    }

    /// Meet's own keys, from the window: ⌘D the microphone, ⌘E the camera;
    /// the screen has none unless one is given in Settings.
    /// Escape puts the call back into its tab, Return goes to it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Keymap.shared.matches(event, .callMic) { poke(); onMic?(); return true }
        if Keymap.shared.matches(event, .callCamera) { poke(); onCamera?(); return true }
        if Keymap.shared.matches(event, .callShare), !share.isHidden { poke(); onShare?(); return true }
        // Meet's own: ⌃⌘H your hand.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .control],
           event.charactersIgnoringModifiers?.lowercased() == "h", news.canHand { poke(); onAsk?(.hand); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// The devices' menu, over its arrow (or the button, with no arrow),
    /// its foot 6 points above the row. The buttons stay while it is open:
    /// their timer waits on the run loop the menu holds.
    private func open(_ which: Devices, closingAfter seconds: Double? = nil) {
        guard let menu = menuFor?(which) else { return }
        poke()
        // The bench's open menu closes itself: popUp holds the run loop
        // until then, and only a common-mode timer runs while it does.
        if let seconds {
            RunLoop.main.add(Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                menu.cancelTracking()
                MainActor.assumeIsolated { self?.benchHover(false) }
            }, forMode: .common)
        }
        let anchor = which == .mic ? (micMore.isHidden ? mic : micMore) : (cameraMore.isHidden ? camera : cameraMore)
        let frame = box(anchor)
        let at = NSPoint(x: frame.minX - 8, y: frame.maxY + 6 + menu.size.height)
        menu.popUp(positioning: nil, at: at, in: self)
    }

    // MARK: - bench

    func benchState() -> [String: Any] {
        [
            "glass_native": (Array(glass.values) + [note, left, mutedPlate, showingPlate, handPlate]).allSatisfy { $0.usesLiquidGlass },
            "glass_class": micPill.usesLiquidGlass ? "NSGlassEffectView" : "NSVisualEffectView",
            "shown": Double(surface(close).alphaValue),
            "near": near, "muted_badge": !muted.isHidden, "hand_badge": !raised.isHidden, "left": leftWords.stringValue,
            "mic": mic.accessibilityLabel() ?? "", "camera": camera.accessibilityLabel() ?? "",
            "share": share.isHidden ? "" : (share.accessibilityLabel() ?? ""), "showing_badge": !showing.isHidden,
            "arrows": [micMore.isHidden ? "" : "mic", cameraMore.isHidden ? "" : "camera"].filter { !$0.isEmpty },
            "note": note.isHidden ? "" : noteWords.stringValue, "note_use": !note.isHidden && !noteUse.isHidden,
            "note_frame": note.isHidden ? "" : NSStringFromRect(noteFrame()), "band": band,
            "row": "\(row)", "island": island.benchState, "reply": reply.isHidden ? "" : "open",
            "unread": news.unread, "hand": news.myHand, "captions": news.captions,
            "row_buttons": buttons.filter { !$0.isHidden && !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.accessibilityLabel() },
            "frames": [
                "close": NSStringFromRect(box(close)), "return": NSStringFromRect(box(back)),
                "mic": NSStringFromRect(box(mic)), "mic_more": micMore.isHidden ? "" : NSStringFromRect(box(micMore)),
                "camera": NSStringFromRect(box(camera)), "share": share.isHidden ? "" : NSStringFromRect(box(share)),
                "leave": leave.isHidden ? "" : NSStringFromRect(box(leave)), "showing": showing.isHidden ? "" : NSStringFromRect(box(showing)),
                "hand_mark": raised.isHidden ? "" : NSStringFromRect(box(raised)),
                "island": island.isHidden ? "" : NSStringFromRect(island.frame),
                "faces": facesPlate.isHidden ? "" : NSStringFromRect(facesPlate.frame),
                "more": more.isHidden ? "" : NSStringFromRect(box(more)), "back_row": backRow.isHidden ? "" : NSStringFromRect(box(backRow)),
            ],
        ]
    }

    /// For the bench: a button pressed as a click on it would.
    func press(_ name: String) {
        switch name {
        case "mic": pressedMic()
        case "camera": pressedCamera()
        case "share": pressedShare()
        case "use": pressedNote()
        case "leave": pressedLeave()
        case "back": pressedReturn()
        case "close": pressedClose()
        case "more": pressedMore()
        case "hand": pressedHand()
        case "captions": pressedCaptions()
        case "react": pressedReact()
        case "chat": pressedChat()
        case "row-back": pressedBackRow()
        case "admit", "deny", "view", "deny-all": island.press(name)
        default:
            if let face = faceButtons.first(where: { $0.attributedTitle.string == name }) { pressedFace(face) }
        }
    }

    @objc private func pressedClose() { onClose?() }
    @objc private func pressedReturn() { onReturn?() }
    /// For the bench: the devices' menu opened over its arrow, as a click
    /// opens it, closed again after `seconds` (pictures of it, #257).
    /// The pointer is over the window while a click's menu is open, so the
    /// buttons come up first: popUp holds the run loop their fade-in needs.
    func benchOpen(_ which: Devices, seconds: Double) {
        benchHover(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.open(which, closingAfter: seconds) }
        }
    }

    /// For the bench: the devices' menu, as it would open, its items'
    /// titles, a tick before the one in use.
    func benchMenu(_ which: Devices) -> [String] {
        (menuFor?(which)?.items ?? []).map { item in
            item.isSeparatorItem ? "-" : (item.isSectionHeader ? "# " : item.state == .on ? "✓ " : "") + item.title
                + (item.subtitle.map { " (\($0))" } ?? "")
        }
    }

    // MARK: - the press

    /// The microphone and the camera answer the press, not the release:
    /// down, the whole capsule gives (to 0.9 on a spring with no pass) and
    /// turns over at once, red glass and the crossed mark, 0.14 s, so it has
    /// by the time a click lets go; up, it springs back past whole by a
    /// little and the page is told. The pointer taken off before letting go
    /// turns it back. The page then has the last word: should it not agree
    /// within 1.5 s, the button goes back to what the page says.
    private func pressed(_ which: Devices, _ press: FloatButton.Press) {
        let pill = which == .mic ? micPill : cameraPill
        let off = which == .mic ? (state.mic == .muted) : (state.camera == .muted)
        switch press {
        case .down:
            poke()
            squeeze(pill, to: 0.9)
            show(which, off: !off)
        case .held(let inside):
            show(which, off: inside ? !off : nil)
        case .up(let inside):
            squeeze(pill, to: 1)
            guard inside else { return show(which, off: nil) }
            pendingTimer[which]?.invalidate()
            pendingTimer[which] = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle(which); self?.show(which, off: nil) }
            }
        }
    }

    /// A press's state on the button, or nil for what the page says.
    private func show(_ which: Devices, off: Bool?) {
        if which == .mic { pending.mic = off } else { pending.camera = off }
        if off == nil { pendingTimer[which]?.invalidate(); pendingTimer[which] = nil }
        (which == .mic ? micMark : cameraMark).set(which == .mic ? micOff : cameraCrossed, now: false)
        tint(animated: true)
        muted.isHidden = !micOff || near
    }

    private func settle(_ which: Devices) {
        pendingTimer[which]?.invalidate()
        pendingTimer[which] = nil
        if which == .mic { pending.mic = nil } else { pending.camera = nil }
    }

    /// The capsules red while off; on a press, the change rides the
    /// marks' curve.
    private func tint(animated: Bool = false) {
        let apply = {
            self.micPill.tintColor = self.micOff ? CallControls.red : nil
            self.cameraPill.tintColor = self.cameraOff ? CallControls.red : nil
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return apply() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = markCurve
            context.allowsImplicitAnimation = true
            apply()
        }
    }

    /// The capsule's size about its middle: in on a critically damped
    /// spring, back out on one that passes whole by about two percent.
    private func squeeze(_ pill: NSView, to scale: CGFloat) {
        guard let layer = pill.layer else { return }
        let w = pill.bounds.width / 2, h = pill.bounds.height / 2
        var to = CATransform3DMakeTranslation(w, h, 0)
        to = CATransform3DScale(to, scale, scale, 1)
        to = CATransform3DTranslate(to, -w, -h, 0)
        if scale == 1 { to = CATransform3DIdentity }
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: to)
        spring.mass = 1
        if scale < 1 {
            // ω 45, critically damped: in by 60 ms, no pass.
            spring.stiffness = 45 * 45
            spring.damping = 2 * 45
        } else {
            // ω 28, ζ 0.45: out with one small pass.
            spring.stiffness = 28 * 28
            spring.damping = 2 * 0.45 * 28
        }
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "press")
    }

    @objc private func pressedMic() { poke(); onMic?() }
    @objc private func pressedCamera() { poke(); onCamera?() }
    @objc private func pressedShare() { poke(); onShare?() }
    @objc private func pressedMicMore() { open(.mic) }
    @objc private func pressedCameraMore() { open(.camera) }
    @objc private func pressedNote() {
        let act = noteAct
        hush()
        act?()
    }
    @objc private func pressedLeave() { onLeave?() }
    @objc private func pressedMore() { poke(); row = .more; needsLayout = true }
    @objc private func pressedBackRow() { poke(); row = row == .faces ? .more : .main; needsLayout = true }
    @objc private func pressedHand() { poke(); onAsk?(.hand) }
    @objc private func pressedCaptions() { poke(); onAsk?(.captions) }
    @objc private func pressedReact() { poke(); row = .faces; needsLayout = true }
    @objc private func pressedFace(_ sender: NSButton) {
        poke()
        onAsk?(.react(sender.attributedTitle.string))
        row = .main
        needsLayout = true
    }
    /// The chat, from the second row: the field opens over the row.
    @objc private func pressedChat() { openReply() }

    func openReply() {
        poke()
        row = .main
        // Out of a bubble just clicked: the stage brings the bubble down to
        // be the field, which shows as it gets there (CallStage `hit`).
        reply.open(after: CACurrentMediaTime() - tappedAt < 1.5 ? 0.2 : 0)
        onAsk?(.read)
        onAsk?(.thread(true))
        needsLayout = true
        tellBand()
    }

    /// For the bench: words typed into the field and sent, as Return would.
    func benchReply(_ words: String) {
        openReply()
        reply.field.stringValue = words
        if !words.isEmpty { onAsk?(.send(words)) }
        reply.close()
    }

    /// A click on the picture, not on a button: the stage is asked whether
    /// a message was there (FloatHand.tapped).
    override func tapped(_ point: NSPoint) {
        // The chat open, a click on the picture puts it away, as Escape and
        // Return on nothing do.
        if !reply.isHidden { return reply.close() }
        tappedAt = CACurrentMediaTime()
        onAsk?(.tap(NSPoint(x: point.x, y: bounds.height - point.y)))
    }
    private var tappedAt: CFTimeInterval = 0

    /// A right-click on the island: Admit and Deny, the narrow card's Deny
    /// among them (CallIsland.askMenu).
    override func menu(for event: NSEvent) -> NSMenu? {
        let at = convert(event.locationInWindow, from: nil)
        if !island.isHidden, island.frame.contains(at), let menu = island.askMenu() { return menu }
        return nil
    }

    /// Anywhere else a right-click is nothing: the page under the stage
    /// has its own menu (Reload, Inspect Element), which is not the call's.
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

/// What lays a call out in the window: over the page, a black stage of its
/// own with the people on the call (PLAN-calls.md, the ten cases).
///
/// Nothing of the page is moved or restyled: each video it plays is played
/// a second time, muted, from the same stream, in yab's own element, so
/// the page's layout and script are left as they were, and coming home is
/// taking the stage away.
///
/// On Meet the people are Meet's own tiles, so everyone is there, camera or
/// not: a name, a picture or an initial, who is speaking (the tile's sound
/// level, `jsname="QgSmzd"`, which stirs only while someone talks), and a
/// screen shared (a tile whose media is not its person's, a playing tile
/// with no name, or a video outside every tile), and who is muted (a mark
/// in the tile's corner, by the name while names are up). Anywhere else,
/// the page's live videos, the biggest first.
///
/// Tiles keep their places: speaking lights a thin ring and moves nothing;
/// someone off the grid who talks for two seconds takes the place of the
/// one quiet the longest. You are small in the corner, or the fourth of two
/// by two when three others fill the rest; alone, you fill it. A window
/// under 300 points shows only who speaks. A screen shared fills the
/// window, everyone else a row of faces along its top. Names come up with
/// the buttons.
///
/// The page is shown scaled (Floater's Lens): every size here is in the
/// window's points, turned into the page's pixels by `size`.
///
/// In its own world: the page cannot see the script, and the stage is a
/// closed shadow root the page cannot look into.
@MainActor
enum CallStage {
    /// Each verb is a short call into the stage the page already has; the
    /// script itself (some 100 KB) goes in only when the page has none yet,
    /// its first verb or the first after a new document. Sent with every
    /// verb, twice a second as the window ticks, each copy was parsed again
    /// and left to the page's garbage, which a page busy only drawing video
    /// does not collect: a call out in the window grew its page by some
    /// 28 MB a minute (WebKit malloc) until something collected it (#284).
    static func run(_ verb: String, _ argument: Any = 0, on web: any PageHandle, _ answer: ((Any?) -> Void)? = nil) {
        let arguments: [String: Any] = ["verb": verb, "argument": argument]
        func done(_ result: Result<Any?, any Error>) {
            if case .success(let value) = result { answer?(value) } else { answer?(nil) }
        }
        handed(call)
        web.call(call, arguments: arguments, in: .named("call")) { [weak web] result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, value as? String == missing else { return done(result) }
                guard let web else { answer?(nil); return }
                handed(source)
                handed(call)
                web.call(source + "\n" + call, arguments: arguments, in: .named("call")) { result in
                    MainActor.assumeIsolated { done(result) }
                }
            }
        }
    }

    /// Bytes of script handed to pages so far, for the tests.
    private(set) static var sent = 0
    static func handed(_ script: String) { sent += script.utf8.count }
    /// What a page without the stage answers, so the script goes in.
    static let missing = "yab-call-stage-missing"
    static let call = "if (!window.__yabCall) return \"\(missing)\";\nreturn await window.__yabCall[verb](argument);"

    /// `on` answers with how many are shown; `leave` with whether the page
    /// had a Leave button to press, or "asked" when pressing it put a
    /// question up on the page; `size` takes the window's width in
    /// points, `names` 1 or 0.
    static let source = PageScript.load("call-stage")
}
