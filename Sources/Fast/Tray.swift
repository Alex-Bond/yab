import AppKit
import SwiftUI

// A list that opens from a button: its own panel over the window, glass:
// the material, then a tone of the ground
// between it and the content, then the content, in one rounded frame with a
// hairline round it.
//
// Not a popover. A popover blends whatever is behind it without a tone: over
// the window it is the window's gray, past the window's edge it is the
// desktop, and a list that hangs over both comes out in two colors at once.
// The tone holds the whole panel near the ground whatever is behind it, and
// leaves enough of the blur to still be glass.
//
// The measures are the extensions list's, so the two read as one kind of
// thing: 280 wide, a 20-point corner, everything 8 in from the edge, and
// every rounded thing inside concentric with the corner.

@MainActor
final class Tray: NSPanel {
    static let corner: CGFloat = 20
    static let inset: CGFloat = 8
    static var inner: CGFloat { corner - inset }
    static let width: CGFloat = 280
    /// Between the button and the panel.
    static let gap: CGFloat = 6
    /// How long a list opened by the pointer waits for it to come back.
    static let linger: CFTimeInterval = 0.18

    init(content: some View, corner: CGFloat = Tray.corner) {
        host = TrayHost(rootView: AnyView(content.focusEffectDisabled()))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        // A click in the list shouldn't take the keyboard from the page.
        becomesKeyOnlyIfNeeded = true

        let frame = TrayFrame()
        frame.layer?.cornerRadius = corner
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let tone = TrayTone()
        frame.pin(glass)
        glass.pin(tone)
        glass.pin(host)
        contentView = frame

        host.sizingOptions = [.intrinsicContentSize]
        host.resized = { [weak self] in self?.fit() }
    }

    override var canBecomeKey: Bool { true }

    /// Escape, when it does have the keyboard.
    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: - coming and going

    private let host: TrayHost
    private weak var parentWindowRef: NSWindow?
    /// The button it opened from, on screen: a press there is the button's
    /// own, which closes it, not a press outside.
    private var anchor: NSRect = .zero
    private var up = true
    /// Down from a button on the left of the strip, its left edge on the
    /// button's rather than its right.
    private var leading = false
    private var closed: (() -> Void)?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var leaving = false
    private static let growKey = "tray-grow"
    private var followsPointer = false
    /// Its right edge exactly on the button's.
    private var followsEdge = false
    /// When the pointer left the list and the button, for the way across.
    private var awaySince: CFTimeInterval?
    private var pointer: Timer?

    /// Opens from `anchor` (screen coordinates): up from a button at the
    /// window's foot, its left edge on the button's; down from one at the
    /// top, its right edge on the button's, or its left with `leading`.
    /// `growing`: out of the button itself, from a tenth of its size round
    /// the button's middle, on the curve what rides into a row goes on.
    /// `hovered`: opened by the pointer, it goes when the pointer leaves.
    func present(over window: NSWindow, from anchor: NSRect, up: Bool, leading: Bool = false, growing: Bool = false, hovered: Bool = false, closed: @escaping () -> Void) {
        followsPointer = hovered
        followsEdge = growing
        self.anchor = anchor
        self.up = up
        self.leading = leading
        self.closed = closed
        appearance = window.effectiveAppearance
        generation += 1
        leaving = false

        WindowHosting.attach(self, to: window)
        parentWindowRef = window
        fit()
        watch()

        let layer = contentView?.layer
        layer?.removeAnimation(forKey: Tray.growKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else {
            alphaValue = 1
            orderFront(nil)
            return
        }
        // It grows the last few points out of the button while it fades in,
        // and goes back the same way, quicker, only on the presentation
        // layer, so AppKit's own geometry is never touched.
        if !isVisible { alphaValue = 0 }
        orderFront(nil)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = growing ? fromButton(scale: 0.1) : transform(scale: 0.94, in: layer)
        grow.toValue = CATransform3DIdentity
        grow.duration = growing ? 0.26 : 0.24
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        layer.add(grow, forKey: Tray.growKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = growing ? 0.14 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible, !leaving else { return }
        unwatch()
        generation += 1
        let generation = generation
        // Whoever opened it hears first; it may ask again to close, and
        // `leaving` already says it is.
        leaving = true
        let done = closed
        closed = nil
        done?()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = contentView?.layer else {
            leaving = false
            orderOut(nil)
            return
        }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        shrink.toValue = transform(scale: 0.96, in: layer)
        shrink.duration = 0.12
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: Tray.growKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Opened again before it had finished leaving: it stays.
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.leaving = false
                self.orderOut(nil)
                layer.removeAnimation(forKey: Tray.growKey)
                self.alphaValue = 1
            }
        }
    }

    /// A press anywhere else, Escape, or the app put behind another: it
    /// goes, the way a popover does.
    private func watch() {
        unwatch()
        let presses = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window !== self else { return event }
            let at = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            if !anchor.contains(at) { dismiss() }
            return event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, (event.window === self || event.window === parentWindowRef),
                  event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            dismiss()
            return nil
        }
        let away = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        monitors = [presses, keys].compactMap { $0 }
        observers = [away]
        awaySince = nil
        guard followsPointer else { return }
        let pointer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let at = NSEvent.mouseLocation
                // The gap between the button and the list counts as either,
                // and it waits a moment for a hand on its way to a row.
                if self.frame.union(self.anchor).contains(at) || NSEvent.pressedMouseButtons != 0 {
                    self.awaySince = nil
                } else if let since = self.awaySince {
                    if CACurrentMediaTime() - since >= Tray.linger { self.dismiss() }
                } else {
                    self.awaySince = CACurrentMediaTime()
                }
            }
        }
        RunLoop.main.add(pointer, forMode: .common)
        self.pointer = pointer
    }

    private func unwatch() {
        pointer?.invalidate()
        pointer = nil
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
        monitors = []
        observers = []
    }

    // MARK: - where it stands

    /// As tall as the list asks, standing off the button's edge: an upward
    /// list grows up from its foot, a downward one down from its top, both
    /// kept on the screen.
    private func fit() {
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return }
        var origin = NSPoint(
            x: up || leading ? anchor.minX - 2 : anchor.maxX + (followsEdge ? 0 : 2) - size.width,
            y: up ? anchor.maxY + Tray.gap : anchor.minY - Tray.gap - size.height
        )
        if let screen = (parentWindowRef?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        let frame = NSRect(origin: origin, size: size)
        // The list is drawn again with every step of a download while it is
        // open, and says its size each time. Moving a window and laying its
        // shadow again are calls to the window server that wait for an
        // answer: only when the size has actually changed.
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
        invalidateShadow()
    }

    /// A scale about the button's middle, wherever that is from the panel.
    private func fromButton(scale: CGFloat) -> CATransform3D {
        let x = anchor.midX - frame.minX, y = anchor.midY - frame.minY
        var transform = CATransform3DMakeTranslation(x * (1 - scale), y * (1 - scale), 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }

    /// A scale about the point of the panel's edge nearest the button. The
    /// content layer is anchored at its origin, bottom left.
    private func transform(scale: CGFloat, in layer: CALayer) -> CATransform3D {
        let x = min(max(anchor.midX - frame.minX, 0), layer.bounds.width)
        let y = up ? 0 : layer.bounds.height
        var transform = CATransform3DMakeTranslation(x * (1 - scale), y * (1 - scale), 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }
}

/// The rounded frame: clips everything to the corner, with the hairline on it.
private final class TrayFrame: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tray.corner
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// A dynamic color is fixed the moment it becomes a CGColor, so it is
    /// laid again whenever the appearance changes.
    override func updateLayer() {
        layer?.borderColor = Palette.NS.hairline.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The tone between the material and the content: enough of the ground to
/// keep the list's contrast over a dark window or desktop, little enough to
/// leave what is behind showing through.
private final class TrayTone: NSView {
    private static let strength: CGFloat = 0.7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Palette.NS.ground.withAlphaComponent(TrayTone.strength).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The list's host: tells the panel when the list changes height, and takes
/// the first click even though the panel isn't key.
private final class TrayHost: NSHostingView<AnyView> {
    var resized: (() -> Void)?

    private var asked = false

    /// However many times it changes in one pass, the panel is asked once.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !asked else { return }
        asked = true
        DispatchQueue.main.async { [weak self] in
            self?.asked = false
            self?.resized?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSView {
    func pin(_ view: NSView) {
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
