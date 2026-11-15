import AppKit

/// What a floating window does under a hand, whatever it holds: a video's
/// (Floater.Controls) and a call's (CallControls) are this, with their own
/// buttons in it, so a gesture learned on one works on the other and a new
/// one lands in both.
///
/// The buttons come up with the pointer; a video's stay until it leaves,
/// a call's go after it rests. A drag moves
/// the window and the corner sizes it, keeping its shape; two fingers send
/// it to a corner; a pinch sizes it about
/// the corner it is in; a double-click is the window's own (play or pause, go
/// to the call); Escape puts it away, Return goes to its tab. Let go after a
/// carry, the edge may keep it (`onLetGo`).
///
/// Everything reaches this view: the window's whole background is a web
/// view, which swallows every drag before the window sees it, so every
/// gesture is taken here, above it.
class FloatHand: NSView {
    var onClose: (() -> Void)?
    var onReturn: (() -> Void)?
    /// The buttons came up, or went.
    var onNear: ((Bool) -> Void)?
    /// Up after being out of sight: what they show wants reading again.
    var onShow: (() -> Void)?
    /// Put down after a drag, for the edge to keep it: where the pointer
    /// was let go of, when a mouse carried it.
    var onLetGo: ((NSPoint?) -> Void)?
    /// Carried by the mouse, a step at a time: where the hand would have
    /// the window. True when the edge has it, going behind a side or
    /// coming back out to the hand, and the hand leaves it be.
    var onCarry: ((NSRect) -> Bool)?
    /// Present the same edge effect as the frame travels, by any gesture.
    var onTravel: ((NSRect) -> Void)?
    /// A second outward swipe from a docked side tucks the window there.
    var onTuck: ((FloatPark.Side) -> Void)?
    /// Read for each gesture so an open video's menu choice applies at once.
    var snapToEdges: () -> Bool = { true }

    /// A wash at the top and bottom, so white buttons hold against a bright
    /// frame without covering it.
    let scrim = CAGradientLayer()
    private(set) var near = false

    // MARK: - what each window says

    /// What comes up with the pointer and goes after a while.
    var faded: [NSView] { [] }
    /// What a click reaches while the buttons show.
    var pressable: [NSView] { [] }
    /// Anything else a click may reach while they show: a video's bar.
    func reach(_ point: NSPoint) -> NSView? { nil }
    /// A hand busy inside, dragging a bar: the buttons don't go meanwhile.
    var engaged: Bool { false }
    /// A video's buttons stay up while the pointer rests anywhere on it.
    var staysOnHover: Bool { false }
    /// The buttons came up or went: for what goes with them.
    func didFade(_ up: Bool) {}
    /// Twice in one place, anywhere but a button or the corner.
    func doubleClicked() { onReturn?() }
    /// Once, let go where it was pressed, anywhere but a button or the
    /// corner: a call's stage may have something there (CallControls).
    func tapped(_ point: NSPoint) {}
    /// A key of the window's own, before Escape and Return: true if taken.
    func key(_ event: NSEvent, once: Bool) -> Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrim.colors = [
            NSColor(white: 0, alpha: 0.45).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0.5).cgColor,
        ]
        if #available(macOS 26.0, *) {
            // Both media overlays hold white marks over bright pictures.
            scrim.colors = [
                NSColor(white: 0, alpha: 0.34).cgColor,
                NSColor(white: 0, alpha: 0.26).cgColor,
                NSColor(white: 0, alpha: 0.26).cgColor,
                NSColor(white: 0, alpha: 0.38).cgColor,
            ]
        }
        scrim.locations = [0, 0.28, 0.66, 1]
        scrim.opacity = 0
        layer?.addSublayer(scrim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = bounds
        CATransaction.commit()
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The visible rect follows layout without replacing the area under
        // a still pointer as the controls come up.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// The pointer is over the window: only then does leaving it hide the
    /// buttons early; come up by themselves, they wait out their time.
    private var inside = false
    private weak var keyBeforeHover: NSWindow?
    private var keyedOnHover = false
    private var resizingGesture = false

    /// AppKit sends pinch gestures only to the key window. Make the floating
    /// panel key as the pointer reaches it, so the first pinch needs no click.
    ///
    /// Only while Yab is the active app. With another app in front, a
    /// nonactivating panel made key by a hover takes every key typed into
    /// that app while the pointer rests on the video, and activating the
    /// app again to hand them back is refused once Yab isn't active
    /// (register 1665). There a click makes the window key, as any window.
    private func readyForGesture() {
        guard NSApp.isActive, let window, !window.isKeyWindow else { return }
        keyBeforeHover = NSApp.keyWindow
        window.makeKey()
        keyedOnHover = window.isKeyWindow
    }

    private func returnFocusIfAway() {
        guard keyedOnHover, !inside, !holding, swipeStart == nil, !resizingGesture else { return }
        defer {
            keyedOnHover = false
            keyBeforeHover = nil
        }
        guard NSApp.isActive, window?.isKeyWindow == true else { return }
        if let keyBeforeHover, keyBeforeHover.isVisible { keyBeforeHover.makeKey() }
    }

    override func mouseEntered(with event: NSEvent) {
        noteHover("enter")
        inside = true
        readyForGesture()
        poke()
    }

    override func mouseMoved(with event: NSEvent) {
        inside = true
        readyForGesture()
        poke()
    }

    override func mouseExited(with event: NSEvent) {
        noteHover("exit")
        guard inside || near else { return }
        // Child controls and tracking updates can report an exit without
        // the pointer leaving the window.
        guard !pointerIsInside else { return }
        // A carry moves the panel under the pointer, and AppKit can report
        // an exit with the pointer still on it. Keep gesture focus through
        // the carry; its release reads where the pointer really is.
        if !holding { inside = false }
        returnFocusIfAway()
        // A drag carried outside is still a drag. Keep a fallback alive
        // until that interaction releases, even if its exit came early.
        guard !hoverBusy else {
            if still == nil { wait(0.15) }
            return
        }
        still?.invalidate()
        still = nil
        fade(to: 0, over: 0.16)
    }

    // MARK: - going after a while

    /// How long the pointer may rest before the buttons go.
    static let patience: CFTimeInterval = 2.8
    private var stirred: CFTimeInterval = 0
    /// A fallback only while controls show, including event tracking modes.
    /// It reconciles lost exits and stops once the overlay has faded.
    private var still: Timer?
    var waiting: Bool { still != nil }

    /// For the bench: the pointer over the window, as a click on one of its
    /// buttons has it, or gone again. Probes have no pointer of their own.
    func benchHover(_ over: Bool) {
        inside = over
        if over { poke() } else { refreshPointer() }
    }

    /// Something happened: a move, a click, a key. The buttons come up and
    /// the wait starts over.
    func poke() {
        stirred = CACurrentMediaTime()
        reveal()
        guard still == nil else { return }
        wait(0.15)
    }

    private var hoverBusy: Bool { engaged || holding || swipeStart != nil || resizingGesture }

    /// Tracking exits can be lost when the panel moves under the pointer.
    /// Probe events use their own hover state, never the person's pointer,
    /// unless a probe moves the real one (evals/pip-menu).
    var pointerIsInside: Bool {
        if Store.testing, ProcessInfo.processInfo.environment["YAB_REAL_POINTER"] == nil { return inside }
        guard let window else { return false }
        return window.convertToScreen(convert(bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    /// Reconcile the overlay after a reveal or a glide moved its window.
    func refreshPointer() {
        guard window != nil, !isHidden else { return }
        inside = pointerIsInside
        noteHover("reconcile")
        if inside { poke() }
        else if !hoverBusy {
            stopWatching()
            fade(to: 0, over: 0.16)
            returnFocusIfAway()
        }
    }

    private func noteHover(_ event: String) {
        if DebugLog.pip {
            DebugLog.note("controls-hover", ["event": event, "inside": inside, "near": near,
                                             "engaged": hoverBusy, "waiting": waiting,
                                             "p": DebugLog.point(NSEvent.mouseLocation)])
        }
    }

    private func wait(_ seconds: CFTimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.still = nil
                guard self.near else { return }
                if self.hoverBusy { return self.wait(0.15) }
                if !self.pointerIsInside {
                    self.inside = false
                    self.noteHover("outside-fallback")
                    self.returnFocusIfAway()
                    self.fade(to: 0, over: 0.16)
                    return
                }
                if self.staysOnHover { return self.wait(0.15) }
                let left = FloatHand.patience - (CACurrentMediaTime() - self.stirred)
                if left > 0.05 { return self.wait(min(left, 0.15)) }
                self.noteHover("idle")
                self.fade(to: 0, over: 0.3)
            }
        }
        still = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopWatching() {
        still?.invalidate()
        still = nil
    }

    private func reveal() {
        // Away under the lip of a tucked window, nothing comes up.
        guard !near, !isHidden else { return }
        // In as quick as the system's: there in 0.1 s.
        fade(to: 1, over: 0.1)
        onShow?()
    }

    func fade(to value: CGFloat, over duration: TimeInterval) {
        let up = value > 0
        guard up != near else { return }
        near = up
        if DebugLog.pip { DebugLog.note("controls-fade", ["shown": up, "inside": inside, "engaged": hoverBusy, "waiting": waiting]) }
        onNear?(near)
        didFade(up)
        let time = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
        if time > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = time
                faded.forEach { $0.animator().alphaValue = value }
            }
        } else {
            faded.forEach { $0.alphaValue = value }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(time <= 0)
        CATransaction.setAnimationDuration(time)
        scrim.opacity = Float(value)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        // Out of sight, a click on where a button was only brings them up;
        // the corner always sizes. And the click after that one, if it comes
        // as quick as a double-click's second, is that: a double-click on a
        // still window, not a press of the button that came up under it.
        let justUp = CACurrentMediaTime() - clickedUp < NSEvent.doubleClickInterval
        guard near, !justUp, !atCorner(inside) else { return self }
        // Controls can live inside glass groups, whose coordinates differ
        // from this view's. Hidden groups must not leave live buttons behind.
        for view in pressable where canPress(view) && view.bounds.contains(view.convert(inside, from: self)) {
            return view
        }
        if let view = reach(inside), canPress(view) { return view }
        return self
    }

    private func canPress(_ view: NSView) -> Bool {
        view.isDescendant(of: self) && !view.isHiddenOrHasHiddenAncestor && (view as? NSControl)?.isEnabled != false
    }

    // MARK: - keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // With ⌘ and the like it is the app's, not the window's.
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            return super.keyDown(with: event)
        }
        // A held key has already done what it was for, but for the window's
        // own keys, which say for themselves.
        let once = !event.isARepeat
        if key(event, once: once) { return }
        switch event.keyCode {
        case 53: if once { onClose?() }
        case 36, 76: if once { onReturn?() }
        default: super.keyDown(with: event)
        }
    }

    // MARK: - moving and sizing

    /// Being moved or sized by hand, or its bar dragged: a window that
    /// changes shape under a hand is a window fighting it.
    var busy: Bool { holding || engaged || gliding != nil || swipeStart != nil }
    private var holding = false
    private var grab = NSPoint.zero
    private var origin = NSRect.zero
    private var stretching = false
    /// When a click last brought the buttons up from out of sight.
    private var clickedUp: CFTimeInterval = 0
    /// Where the last press was, on the screen, and whether the window was
    /// carried after it.
    private var lastDown = NSPoint(x: -1e6, y: -1e6)
    private var dragged = false
    /// How far the hand has pushed the window past an outer side with the
    /// pointer standing at it (FloatPark.pushed).
    private var push: CGFloat = 0
    private var previousPointer = NSPoint.zero
    /// The edge has the window, this carry: no more pushing it out.
    private var edgeHas = false

    func atCorner(_ point: NSPoint) -> Bool {
        point.x > bounds.maxX - 22 && point.y < bounds.minY + 22
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: bounds.maxX - 22, y: bounds.minY, width: 22, height: 22), cursor: .crosshair)
    }

    /// A double-click on a window that isn't key yet is still one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        stopGlide()
        if !near { clickedUp = CACurrentMediaTime() }
        poke()
        let at = convert(event.locationInWindow, from: nil)
        let onScreen = window.convertPoint(toScreen: event.locationInWindow)
        // Twice in one place: two quick drags to put the window somewhere
        // are not a double-click.
        let inPlace = !dragged && hypot(onScreen.x - lastDown.x, onScreen.y - lastDown.y) < 3
        lastDown = onScreen
        dragged = false
        if event.clickCount == 2, inPlace, !atCorner(at) {
            doubleClicked()
            return
        }
        holding = true
        grab = NSEvent.mouseLocation
        previousPointer = grab
        origin = window.frame
        push = 0
        edgeHas = false
        stretching = atCorner(at)
        if stretching { beginResizeFeedback(around: pin()) }
        if DebugLog.pip {
            DebugLog.screens()
            DebugLog.note("down", ["p": DebugLog.point(grab), "f": DebugLog.rect(window.frame), "corner": stretching])
        }
    }

    override func mouseUp(with event: NSEvent) {
        if DebugLog.pip {
            DebugLog.note("up", ["p": DebugLog.point(NSEvent.mouseLocation), "f": DebugLog.rect(window?.frame ?? .zero),
                                 "dragged": dragged, "corner": stretching])
        }
        if dragged { FeedbackDiagnostics.shared.record(.pipDragged) }
        if holding, !dragged, !stretching, event.clickCount == 1 { tapped(convert(event.locationInWindow, from: nil)) }
        holding = false
        if stretching { endResizeFeedback() }
        if dragged || stretching { inside = !isHiddenOrHasHiddenAncestor && pointerIsInside }
        if dragged { onLetGo?(NSEvent.mouseLocation) }
        returnFocusIfAway()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, holding else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - grab.x
        let dy = now.y - grab.y
        defer { previousPointer = now }
        guard stretching else {
            let began = CACurrentMediaTime()
            let screens = Self.screens
            if !edgeHas {
                push = FloatPark.pushed(push, by: event.deltaX, moved: now.x - previousPointer.x,
                                        pointer: now, frame: window.frame, in: screens)
            }
            if hypot(dx + push, dy) >= 3 { dragged = true }
            let raw = NSRect(origin: NSPoint(x: origin.minX + dx + push, y: origin.minY + dy), size: origin.size)
            let carried = FloatPark.carried(raw, pointer: now, in: screens, lipWidth: FloatEdgeTab.shown)
            // Discard excess push at the limit, so reversing the hand
            // moves the picture immediately rather than paying it back.
            push += carried.minX - raw.minX
            let hand = NSRect(origin: FloatPark.magnetic(carried, in: screens, snapToEdges: snapToEdges()), size: origin.size)
            edgeHas = onCarry?(hand) == true
            if !edgeHas { window.setFrameOrigin(hand.origin) }
            onTravel?(window.frame)
            if DebugLog.pip {
                DebugLog.note("drag", ["p": DebugLog.point(now), "dx": Double(event.deltaX), "push": Double(push),
                                       "hand": DebugLog.rect(hand), "f": DebugLog.rect(window.frame), "edge": edgeHas,
                                       "ms": DebugLog.ms(CACurrentMediaTime() - began)])
            }
            return
        }
        if hypot(dx, dy) >= 3 { dragged = true }
        // Away from the corner it is held at is bigger, whichever corner.
        let pinned = pin(origin)
        let grow = pinned.x > origin.midX ? -dx : dx
        guard freeShape else { return resizeWhileLifted(to: origin.width + grow, from: origin, around: pinned) }
        // A call's window takes any shape: the height follows the hand too.
        let rise = pinned.y > origin.midY ? -dy : dy
        resizeFreely(to: NSSize(width: origin.width + grow, height: origin.height + rise), around: pinned)
    }

    /// Any shape, not the content's (a call: the people are laid out again
    /// for it), within `shapeLimits`.
    var freeShape = false
    /// A call's window: its shorter side at least 146, from 1:2.2 to 3:1.
    static let shapeLimits = (shortest: CGFloat(146), tallest: CGFloat(1 / 2.2), widest: CGFloat(3))

    /// `size` kept to the limits and the screen, the corner at `anchor`
    /// where it is.
    static func freely(_ size: NSSize, around anchor: NSPoint, in area: NSRect) -> NSRect {
        let limits = shapeLimits
        var w = min(max(size.width, limits.shortest), area.width * 0.85)
        var h = min(max(size.height, limits.shortest), area.height * 0.85)
        if w / h > limits.widest { h = w / limits.widest }
        if w / h < limits.tallest { w = h * limits.tallest }
        let x = anchor.x > area.midX ? anchor.x - w : anchor.x
        let y = anchor.y > area.midY ? anchor.y - h : anchor.y
        return NSRect(x: min(max(x, area.minX), area.maxX - w), y: min(max(y, area.minY), area.maxY - h), width: w, height: h)
    }

    private func resizeFreely(to size: NSSize, around anchor: NSPoint) {
        guard let window else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let logical = Self.freely(size, around: anchor, in: area)
        resizeLogicalFrame = logical
        let lifted = Self.freely(NSSize(width: logical.width * Self.resizeLift, height: logical.height * Self.resizeLift),
                                 around: anchor, in: area)
        window.setFrame(lifted, display: false)
    }

    /// The window's corner at the screen's corner it is in: sizing keeps it
    /// there, so a window in a corner stays in it.
    private func pin(_ frame: NSRect? = nil) -> NSPoint {
        guard let window else { return .zero }
        let frame = frame ?? window.frame
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        return NSPoint(x: frame.midX > area.midX ? frame.maxX : frame.minX,
                       y: frame.midY > area.midY ? frame.maxY : frame.minY)
    }

    /// Two fingers carry the window anywhere, and on lifting it goes where
    /// it was heading: a corner, or behind a side.
    override func scrollWheel(with event: NSEvent) {
        guard window != nil else { return }
        // A swipe under way is followed by its monitors: the window leaves
        // the pointer and AppKit sends the rest of the gesture, its end
        // too, to whatever is under the pointer then.
        guard !following.on else { return }
        flick(with: event)
    }

    /// The swipe's own events wherever they go while it carries the window:
    /// this app's other windows (taken, so a page under the pointer doesn't
    /// scroll) and other apps'.
    private let following = SwipeFollow()

    private func follow(_ on: Bool) {
        following.stop()
        guard on else { return }
        following.start(local: { [weak self] event in
            guard let self else { return event }
            self.flick(with: event)
            return nil
        }, global: { [weak self] event in
            self?.flick(with: event)
        })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { follow(false) }
        watchPinch(window != nil)
    }

    private var pinchWatch: [Any] = []

    /// A pinch reaches only the key window, and this one takes key on hover
    /// only with Yab in front (register 1665). Watched here, a pinch on the
    /// video works over another app too, and its keys stay with that app.
    private func watchPinch(_ on: Bool) {
        pinchWatch.forEach(NSEvent.removeMonitor)
        pinchWatch = []
        guard on else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            self?.pinched(event) == true ? nil : event
        }) { pinchWatch.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            _ = self?.pinched(event)
        }) { pinchWatch.append(global) }
    }

    private func pinched(_ event: NSEvent) -> Bool {
        guard resizingGesture || (!isHiddenOrHasHiddenAncestor && pointerIsInside) else { return false }
        magnify(with: event)
        return true
    }

    // MARK: - flicking to a corner

    /// Two fingers carry the window by hand, as a drag does, with nothing
    /// holding it back; a mouse wheel's turn chooses a corner.
    private var swipe: CGVector = .zero
    private var swipeStart: NSRect?
    /// Where the fingers had got to and when, the last tenth of a second:
    /// how fast they were going when they lifted.
    private var swipeTrail: [(time: TimeInterval, at: CGVector)] = []
    /// A mouse wheel has no gesture to belong to: one flick a turn.
    private var lastWheelFlick = Date.distantPast

    private func flick(with event: NSEvent) {
        // Which way the fingers went, on screen: with natural scrolling the
        // deltas run with the fingers, without it against them.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let step = CGVector(dx: sign * event.scrollingDeltaX, dy: -sign * event.scrollingDeltaY)
        // The glide after the fingers lift says nothing new.
        guard event.momentumPhase == [] else { return }

        if event.phase == [] {
            guard Date().timeIntervalSince(lastWheelFlick) > 0.4, step != .zero else { return }
            lastWheelFlick = Date()
            if DebugLog.pip { DebugLog.note("wheel", ["way": [Double(step.dx), Double(step.dy)]]) }
            send(step)
            return
        }
        // Fingers only resting, as a two-finger click's do: no swipe yet,
        // and the menu that click opens would take the end of it.
        if event.phase == .mayBegin { return }
        if event.phase.contains(.began) {
            stopGlide()
            if let window { _ = onCarry?(window.frame) }
            poke()
            swipe = .zero
            swipeStart = window?.frame
            swipeTrail = []
            follow(true)
            if DebugLog.pip {
                DebugLog.screens()
                DebugLog.note("swipe-begin", ["f": DebugLog.rect(window?.frame ?? .zero)])
            }
        }
        if swipeStart == nil { swipeStart = window?.frame }
        swipe.dx += step.dx
        swipe.dy += step.dy
        if step != .zero { poke() }
        swipeTrail.append((event.timestamp, swipe))
        swipeTrail.removeAll { event.timestamp - $0.time > 0.1 }
        // The window goes with the fingers, one to one, wherever they take
        // it: past a side too.
        if let window, let start = swipeStart {
            window.setFrameOrigin(NSPoint(x: (start.minX + swipe.dx).rounded(), y: (start.minY + swipe.dy).rounded()))
            onTravel?(window.frame)
            if DebugLog.pip {
                DebugLog.note("swipe", ["s": [Double(swipe.dx), Double(swipe.dy)], "f": DebugLog.rect(window.frame),
                                        "phase": Int(event.phase.rawValue)])
            }
        }
        let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        following.hush()
        if lifted {
            land(at: event.timestamp)
        } else if following.on {
            following.wait { [weak self] in self?.land(at: ProcessInfo.processInfo.systemUptime) }
        }
    }

    /// The fingers lifted: where the window was heading.
    private func land(at time: TimeInterval) {
        follow(false)
        if let window, let start = swipeStart {
            let speed = velocity(at: time)
            let aim = Self.landing(window.frame, from: start, swipe: swipe, velocity: speed,
                                   screens: Self.screens, snapToEdges: snapToEdges())
            if DebugLog.pip {
                DebugLog.note("land", ["f": DebugLog.rect(window.frame), "start": DebugLog.rect(start),
                                       "s": [Double(swipe.dx), Double(swipe.dy)], "v": [Double(speed.dx), Double(speed.dy)],
                                       "aim": aim.map { "\($0)" } ?? "stay"])
            }
            switch aim {
            case .tuck(let side)?: onTuck?(side)
            case .glide(let spot)?: glide(to: spot)
            case nil: break
            }
        }
        FeedbackDiagnostics.shared.record(.pipGesture)
        swipe = .zero
        swipeStart = nil
        swipeTrail = []
        returnFocusIfAway()
    }

    /// How fast the fingers were going, points a second, over their last
    /// tenth of a second: nothing if they had stopped.
    private func velocity(at now: TimeInterval) -> CGVector {
        guard let first = swipeTrail.first, let last = swipeTrail.last, now - last.time < 0.05 else { return .zero }
        let span = last.time - first.time
        guard span > 0.008 else { return .zero }
        return CGVector(dx: (last.at.dx - first.at.dx) / span, dy: (last.at.dy - first.at.dy) / span)
    }

    /// How long a let-go window would carry on at the fingers' speed: where
    /// it lands is where it was heading.
    static let carryOn: CGFloat = 0.2
    /// How far the swipe, with its speed carried on, goes before it means a
    /// way: a shorter one puts the window back.
    static let meant: CGFloat = 24

    /// Where two fingers lifting from the window at `frame`, carried there
    /// from `start` by `swipe` and going at `velocity`, send it. Carried a
    /// third past an outer side, or onto another display, as a let-go
    /// decides there; carried, or heading, over a side another display
    /// shares, on to that display, slow or quick; otherwise the way the
    /// whole swipe went, its speed carried on for `carryOn`: the corner that
    /// way, or, outward from a side it was docked at, behind it. A swipe too
    /// short to mean a way puts it back. Nil when it is where it goes.
    static func landing(_ frame: NSRect, from start: NSRect, swipe: CGVector, velocity: CGVector,
                        screens: [FloatPark.Screen], snapToEdges: Bool = true) -> Aim? {
        let settled = FloatPark.settle(frame, in: screens, snapToEdges: snapToEdges)
        if case .park(let side, _) = settled { return .tuck(side) }
        if !snapToEdges {
            if case .inside(let spot) = settled { return .glide(spot) }
            return nil
        }
        if let here = FloatPark.screen(for: frame, in: screens), here != FloatPark.screen(for: start, in: screens) {
            if case .inside(let spot) = settled { return .glide(spot) }
            return nil
        }
        let way = CGVector(dx: swipe.dx + velocity.dx * carryOn, dy: swipe.dy + velocity.dy * carryOn)
        // Slowly over the edge, most of it still on this display and cut
        // off there by separate Spaces, it was being taken across all the
        // same: it went back to this display's corner at that side, and
        // only a swipe quick enough to take most of it over went on.
        if let here = FloatPark.screen(for: frame, in: screens),
           let spot = FloatPark.onward(frame,
                                       from: here, toward: way, least: meant, in: screens) {
            return spot == frame.origin ? nil : .glide(spot)
        }
        let back: Aim? = frame.origin == start.origin ? nil : .glide(start.origin)
        guard hypot(way.dx, way.dy) >= meant else { return back }
        switch aim(way, from: start, settled: start, screens: screens) {
        case .glide(let spot)? where spot == frame.origin: return nil
        case let target?: return target
        case nil: return back
        }
    }

    private static var screens: [FloatPark.Screen] {
        NSScreen.screens.map { FloatPark.Screen(frame: $0.frame, visible: $0.visibleFrame) }
    }

    private func send(_ way: CGVector, started: NSRect? = nil) {
        guard snapToEdges(), let window else { return }
        // A second gesture can begin before the first glide ends. Read its
        // destination as the current dock, then finish that glide before tucking.
        // Two fingers stop that glide as they land, and hand its destination in.
        let settled = NSRect(origin: gliding == nil ? window.frame.origin : glideTo, size: window.frame.size)
        let aim = Self.aim(way, from: started ?? settled, settled: settled, screens: Self.screens)
        if DebugLog.pip { DebugLog.note("flick", ["f": DebugLog.rect(window.frame), "aim": aim.map { "\($0)" } ?? "stay"]) }
        switch aim {
        case .tuck(let side)?: if gliding != nil { pendingTuck = side } else { onTuck?(side) }
        case .glide(let spot)?: glide(to: spot)
        case nil: break
        }
    }

    enum Aim: Equatable {
        case tuck(FloatPark.Side)
        case glide(NSPoint)
    }

    /// What a flick does, judged from where it started, `from`, with the
    /// window now at `settled`: tucks it behind an outer side it is docked
    /// at, sends it on past a shared one, or to a side or corner of the
    /// display it started on, not of one its own carry has taken it over.
    /// Nil when it is there already.
    static func aim(_ way: CGVector, from: NSRect, settled: NSRect, screens: [FloatPark.Screen]) -> Aim? {
        guard let screen = FloatPark.screen(for: from, in: screens) else { return nil }
        let area = screen.visible
        if let side = outwardSide(for: from, in: area, toward: way), FloatPark.outer(side, of: screen, for: from, in: screens) {
            return .tuck(side)
        }
        // At an edge another display shares, on to that display.
        if let spot = FloatPark.passed(from, toward: way, in: screens) { return .glide(spot) }
        let target = corner(for: settled, in: area, toward: way)
        return target == settled.origin ? nil : .glide(target)
    }

    /// For the bench: two fingers flicked this way, flicks on or not.
    func flick(_ way: CGVector) { send(way) }

    /// Back out of hiding: the buttons, as a stopped video has them.
    func wake() { poke() }

    /// A menu took the events: what began under it never hears its end.
    func menuClosed() {
        holding = false
        follow(false)
        swipe = .zero
        swipeStart = nil
        swipeTrail = []
        refreshPointer()
    }

    /// A horizontal swipe changes side and keeps height. A vertical one
    /// changes height and uses the nearest side. A diagonal chooses both.
    static func corner(for frame: NSRect, in area: NSRect, toward way: CGVector, margin: CGFloat = 16) -> NSPoint {
        FloatPark.corner(for: frame, in: area, toward: way, margin: margin)
    }

    /// Only a clear horizontal swipe outward from an already docked side
    /// hides the window. Diagonals still mean a corner.
    static func outwardSide(for frame: NSRect, in area: NSRect, toward way: CGVector, margin: CGFloat = 16) -> FloatPark.Side? {
        guard abs(way.dx) > 1.5 * abs(way.dy) else { return nil }
        let side: FloatPark.Side = way.dx > 0 ? .right : .left
        let edge = side == .right ? area.maxX - margin - frame.width : area.minX + margin
        guard abs(frame.minX - edge) < 1 else { return nil }
        let target = corner(for: frame, in: area, toward: way, margin: margin)
        return abs(target.y - frame.minY) < 1 ? side : nil
    }

    /// A frame at a time off the display's own refresh, 120 a second on a
    /// ProMotion screen, on a critically damped spring: quick away, settling
    /// into the corner without passing it.
    private var gliding: CADisplayLink?
    private var pendingTuck: FloatPark.Side?
    private var glideFrom: NSPoint = .zero
    private var glideTo: NSPoint = .zero
    private var glideStart: CFTimeInterval = 0
    /// A debug build's count of the glide's frames: how many, the longest
    /// wait between two, and how many came late.
    private var glideFrames = (count: 0, last: CFTimeInterval(0), worst: CFTimeInterval(0), late: 0)

    private func glide(to target: NSPoint) {
        guard let window else { return }
        pendingTuck = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopGlide()
            window.setFrameOrigin(target)
            onTravel?(window.frame)
            return
        }
        glideFrom = window.frame.origin
        glideTo = target
        glideStart = CACurrentMediaTime()
        glideFrames = (0, 0, 0, 0)
        if DebugLog.pip { DebugLog.note("hand-glide", ["from": DebugLog.point(glideFrom), "to": DebugLog.point(target)]) }
        if gliding == nil {
            let link = displayLink(target: self, selector: #selector(glideStep))
            link.add(to: .main, forMode: .common)
            gliding = link
        }
    }

    @objc private func glideStep(_ link: CADisplayLink) {
        guard let window else { return stopGlide() }
        if DebugLog.pip {
            let gap = glideFrames.last > 0 ? link.timestamp - glideFrames.last : 0
            glideFrames.count += 1
            glideFrames.worst = max(glideFrames.worst, gap)
            if gap > (link.targetTimestamp - link.timestamp) * 1.5 { glideFrames.late += 1 }
            glideFrames.last = link.timestamp
        }
        // Placed for when the frame is on the screen, on whole pixels, and
        // over once it is under half a pixel from the corner.
        let t = CGFloat(link.targetTimestamp - glideStart)
        let omega: CGFloat = 15
        var done = t > 0.6
        var p = done ? 1 : 1 - (1 + omega * t) * exp(-omega * t)
        let scale = window.backingScaleFactor
        let span = max(abs(glideTo.x - glideFrom.x), abs(glideTo.y - glideFrom.y))
        if (1 - p) * span * scale < 0.5 { (p, done) = (1, true) }
        let spot = NSPoint(
            x: ((glideFrom.x + (glideTo.x - glideFrom.x) * p) * scale).rounded() / scale,
            y: ((glideFrom.y + (glideTo.y - glideFrom.y) * p) * scale).rounded() / scale
        )
        if spot != window.frame.origin { window.setFrameOrigin(spot) }
        onTravel?(window.frame)
        if done, DebugLog.pip {
            DebugLog.note("hand-glided", ["frames": glideFrames.count, "ms": DebugLog.ms(CACurrentMediaTime() - glideStart),
                                          "worst_ms": DebugLog.ms(glideFrames.worst), "late": glideFrames.late,
                                          "frame_ms": DebugLog.ms(link.targetTimestamp - link.timestamp),
                                          "f": DebugLog.rect(window.frame)])
        }
        if done {
            let tuck = pendingTuck
            stopGlide()
            if let tuck { onTuck?(tuck) }
            else { refreshPointer() }
        }
    }

    func stopGlide() {
        gliding?.invalidate()
        gliding = nil
        pendingTuck = nil
    }

    /// A pinch sizes it about the corner of the screen it is in: that corner
    /// of the window stays put and the rest grows away from it, so it never
    /// leaves its corner.
    private var pinching: CGFloat = 0
    /// A tiny lift grows the panel and its native shadow while the size is
    /// being chosen. Keep the intended frame separately so letting go does
    /// not add the lift to the requested size.
    private var resizeLogicalFrame: NSRect?
    private static let resizeLift: CGFloat = 1.012

    private func beginResizeFeedback(around anchor: NSPoint? = nil) {
        guard let window, resizeLogicalFrame == nil else { return }
        resizeLogicalFrame = window.frame
        resizeWhileLifted(to: window.frame.width, from: window.frame, around: anchor)
    }

    private func resizeWhileLifted(to width: CGFloat, from was: NSRect, around anchor: NSPoint? = nil) {
        guard let window else { return }
        let area = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let logical = Self.resized(was, to: width, minWidth: window.minSize.width, in: area, around: anchor)
        resizeLogicalFrame = logical
        let lifted = Self.resized(logical, to: logical.width * Self.resizeLift,
                                  minWidth: window.minSize.width, in: area, around: anchor)
        window.setFrame(lifted, display: false)
    }

    private func endResizeFeedback() {
        guard let window, let logical = resizeLogicalFrame else { return }
        resizeLogicalFrame = nil
        window.setFrame(logical, display: false)
        window.invalidateShadow()
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) { pinching = 0 }
        if !finished {
            resizingGesture = true
            beginResizeFeedback(around: pin())
        } else {
            resizingGesture = false
        }
        defer {
            if finished {
                endResizeFeedback()
                onLetGo?(nil)
                returnFocusIfAway()
            }
        }
        pinching += event.magnification
        // Every event would mean a window resize, a page relaid out and a
        // picture fitted again sixty times a second, which is the stutter.
        // Moving in steps of a fiftieth is below what an eye reads as a jump
        // and an order of magnitude less work.
        guard abs(pinching) > 0.02 else { return }
        let by = pinching
        pinching = 0
        let logical = resizeLogicalFrame ?? window.frame
        resizeWhileLifted(to: logical.width * (1 + by), from: logical, around: pin(logical))
    }

    /// Keep the shape, the point under the fingers, and the whole result on
    /// screen. Shared by pinch and the corner drag.
    static func resized(_ was: NSRect, to width: CGFloat, minWidth: CGFloat, in area: NSRect, around anchor: NSPoint? = nil) -> NSRect {
        guard was.width > 0 else { return was }
        // Keeps the shape: a window that can be squashed is a window showing
        // bars. And inside the screen both ways: an upright video sized by
        // its width alone ran off the top.
        let most = min(area.width * 0.85, area.height * 0.85 * was.width / was.height)
        let wide = min(max(minWidth, width), most)
        let tall = wide * was.height / was.width

        let spot: NSPoint
        if let anchor {
            // Where the pointer sits within the window, as a fraction, kept at
            // the same fraction of the new one.
            let across = (anchor.x - was.minX) / was.width
            let up = (anchor.y - was.minY) / was.height
            spot = NSPoint(x: anchor.x - across * wide, y: anchor.y - up * tall)
        } else {
            spot = NSPoint(x: was.minX, y: was.maxY - tall)
        }
        let fitted = NSPoint(
            x: min(max(spot.x, area.minX), max(area.minX, area.maxX - wide)),
            y: min(max(spot.y, area.minY), max(area.minY, area.maxY - tall))
        )
        return NSRect(x: fitted.x, y: fitted.y, width: wide, height: tall)
    }
}

/// A two-finger swipe's own events wherever they go while it carries a
/// floating window: AppKit sends the rest of a gesture to whatever is under
/// the pointer, and the window has left the pointer. The window's hand and
/// its lip behind a side both follow one this way.
@MainActor
final class SwipeFollow {
    private var monitors: [Any] = []
    /// A swipe whose end went somewhere no monitor hears is over once the
    /// fingers have been quiet for a second and a half.
    private var quiet: DispatchWorkItem?

    var on: Bool { !monitors.isEmpty }

    /// Each event from this app's windows to `local`, which answers nil to
    /// take it, and each from other apps' to `global`, until `stop`.
    func start(local: @escaping (NSEvent) -> NSEvent?, global: @escaping (NSEvent) -> Void) {
        stop()
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, self.on else { return event }
            return local(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, self.on else { return }
            global(event)
        }) { monitors.append(monitor) }
    }

    /// No more events, and no end waiting.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hush()
    }

    /// `done` once the fingers have been quiet a second and a half, in
    /// place of any end already waiting.
    func wait(_ done: @escaping () -> Void) {
        hush()
        let item = DispatchWorkItem(block: done)
        quiet = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// No end waiting.
    func hush() {
        quiet?.cancel()
        quiet = nil
    }
}
