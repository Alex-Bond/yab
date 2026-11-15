import AppKit
import SwiftUI
import YabCoreClient

/// Uses the same popover and button anchor as WebKit's extension popup,
/// while the content and input remain owned by Chromium's native widget.
@MainActor
final class ChromiumPopupHost: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = ChromiumPopupHost()
    private var popover: NSPopover?
    private var popup: ChromiumExtensionPopup?
    private weak var page: ChromiumPage?
    private weak var anchor: ChromiumPopupAnchor.View?
    private var following: Timer?
    private var closedOnButton: (String, Date)?
    @Published private(set) var shownExtensionID: String?
    var isShown: Bool { popover?.isShown == true }

    func shownExtension(for tab: Tab) -> String? {
        guard page?.navigationTab === tab, isShown else { return nil }
        return shownExtensionID
    }

    func toggleClosed(page: ChromiumPage, extensionID: String) -> Bool {
        if let closedOnButton, closedOnButton.0 == extensionID, Date().timeIntervalSince(closedOnButton.1) < 0.3 {
            self.closedOnButton = nil
            return true
        }
        if self.page === page, popup?.extensionID == extensionID { close(); return true }
        close()
        return false
    }

    func receive(_ popup: ChromiumExtensionPopup, page: ChromiumPage) {
        guard !popup.closed, popup.contextID != 0, popup.pointSize.width > 0, popup.pointSize.height > 0 else { return }
        if self.popup !== popup {
            close()
            // Its pin, or, with no pin drawn (pressed in the Site Controls
            // list, or by a command), the sliders, as on WebKit.
            guard let tab = page.navigationTab,
                  let anchor = ChromiumPopupAnchor.View.find(tab: tab, id: popup.extensionID)
                    ?? ChromiumPopupAnchor.View.find(tab: tab, id: ChromiumPopupAnchor.sliders),
                  let browser = tab.delegate as? Browser, browser.activeID == tab.id,
                  anchor.window === page.window else { popup.close(); return }
            self.popup = popup; self.page = page; self.anchor = anchor
            let content = ChromiumPopupInput(frame: CGRect(origin: .zero, size: popup.pointSize))
            content.popup = popup
            content.wantsLayer = true
            content.layer?.addSublayer(popup.layer)
            let controller = NSViewController()
            controller.view = content
            controller.preferredContentSize = popup.pointSize
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = popup.pointSize
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            shownExtensionID = popup.extensionID
            content.window?.makeFirstResponder(content)
            following = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        } else {
            popover?.contentViewController?.preferredContentSize = popup.pointSize
            popover?.contentViewController?.view.setFrameSize(popup.pointSize)
            popover?.contentSize = popup.pointSize
        }
    }

    private func follow() {
        guard let page, let tab = page.navigationTab, !tab.gone,
              let browser = tab.delegate as? Browser, browser.activeID == tab.id,
              page.extensionPopup === popup, let anchor, anchor.window === page.window,
              anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { close(); return }
        popover?.positioningRect = anchor.bounds
    }

    func nativeClosed(_ token: String) { if popup?.token == token { close() } }
    func retire(_ page: ChromiumPage) { if self.page === page { close() } }

    func close() {
        following?.invalidate(); following = nil
        let old = popup; popup = nil; page = nil; anchor = nil
        shownExtensionID = nil
        let popover = popover; self.popover = nil
        popover?.delegate = nil
        popover?.close()
        old?.layer.removeFromSuperlayer()
        old?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if let popup, let anchor, let window = anchor.window {
            let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            if anchor.bounds.contains(anchor.convert(mouse, from: nil)) { closedOnButton = (popup.extensionID, Date()) }
        }
        close()
    }

    /// Deliver only to the original current view, as its AppKit mouse path does.
    /// This is not a native IPC acknowledgement; the probe must observe the real product effect.
    func benchPointer(_ input: ChromiumPopupProbeInput, owner: ChromiumPage) -> [String: Any] {
        func refused(_ reason: String, delivered: Int = 0) -> [String: Any] {
            ["eventsDeliveredToOriginalView": delivered, "nativeAcknowledged": false, "refused": reason]
        }
        guard Store.testing, page === owner, let popup, !popup.closed, isShown,
              owner.extensionPopup === popup, let tab = owner.navigationTab, !tab.gone,
              (tab.delegate as? Browser)?.activeID == tab.id,
              let originalPopover = popover,
              let content = originalPopover.contentViewController?.view as? ChromiumPopupInput,
              content.popup === popup, let window = content.window,
              input.matches(token: popup.token, extensionID: popup.extensionID, context: popup.contextID,
                            window: window.windowNumber, size: content.bounds.size) else {
            return refused("original-popup-view-or-lease-unavailable")
        }
        let point = content.convert(CGPoint(x: input.x, y: content.bounds.height - input.y), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            return refused("original-popup-event-unavailable")
        }
        content.mouseDown(with: down)
        guard self.popup === popup, !popup.closed, self.page === owner, isShown,
              owner.extensionPopup === popup, owner.navigationTab === tab, !tab.gone,
              (tab.delegate as? Browser)?.activeID == tab.id,
              self.popover === originalPopover, originalPopover.contentViewController?.view === content,
              content.popup === popup, content.window === window,
              input.matches(token: popup.token, extensionID: popup.extensionID, context: popup.contextID,
                            window: window.windowNumber, size: content.bounds.size) else {
            return refused("original-popup-retired-after-down", delivered: 1)
        }
        content.mouseUp(with: up)
        return ["eventsDeliveredToOriginalView": 2, "nativeAcknowledged": false,
                "forwarding": "original-AppKit-popup-input", "token": popup.token, "context": popup.contextID]
    }

    var state: [String: Any] {
        guard let popup else { return ["shown": false] }
        let rect = popover?.contentViewController?.view.window?.frame ?? .zero
        let from = anchor.flatMap { a in a.window.map { $0.convertToScreen(a.convert(a.bounds, to: nil)) } } ?? .zero
        let content = popover?.contentViewController?.view
        let contentScreen = content.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } } ?? .zero
        // Popup top-left points relative to the ORIGINAL whole window, matching captured pixels.
        let inset = CGRect(x: contentScreen.minX - rect.minX, y: rect.maxY - contentScreen.maxY,
                           width: contentScreen.width, height: contentScreen.height)
        return ["shown": isShown, "token": popup.token, "extension": popup.extensionID,
                "context": popup.contextID, "size": [popup.pointSize.width, popup.pointSize.height],
                "frame": [rect.minX, rect.minY, rect.width, rect.height],
                "contentFrameInWindow": [inset.minX, inset.minY, inset.width, inset.height],
                "inputSize": [content?.bounds.width ?? 0, content?.bounds.height ?? 0],
                "anchor": [from.minX, from.minY, from.width, from.height],
                "window": popover?.contentViewController?.view.window?.windowNumber ?? 0]
    }
}

struct ChromiumPopupAnchor: NSViewRepresentable {
    /// The Site Controls door's id here: what a popup without a pin hangs from.
    static let sliders = "site-controls"
    let id: String
    let tab: Tab
    func makeNSView(context: Context) -> View { View(tab: tab, id: id) }
    func updateNSView(_ view: View, context: Context) {
        view.tab = tab
        view.id = id
    }

    @MainActor final class View: NSView {
        weak var tab: Tab?
        var id: String
        private static let all = NSHashTable<View>.weakObjects()
        init(tab: Tab, id: String) { self.tab = tab; self.id = id; super.init(frame: .zero); Self.all.add(self) }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        static func find(tab: Tab, id: String) -> View? {
            all.allObjects.last { $0.tab === tab && $0.id == id && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        }
    }
}

@MainActor
private final class ChromiumPopupInput: NSView {
    weak var popup: ChromiumExtensionPopup?
    override var acceptsFirstResponder: Bool { true }
    private func pointer(_ kind: String, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        popup?.send(["kind": .string(kind), "x": .number(point.x), "y": .number(bounds.height - point.y),
                     "clickCount": .number(Double(event.clickCount)), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer("mouseDown", event) }
    override func mouseUp(with event: NSEvent) { pointer("mouseUp", event) }
    override func mouseDragged(with event: NSEvent) { pointer("mouseDrag", event) }
    override func rightMouseDown(with event: NSEvent) { pointer("rightDown", event) }
    override func rightMouseUp(with event: NSEvent) { pointer("rightUp", event) }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        popup?.send(["kind": .string("wheel"), "x": .number(point.x), "y": .number(bounds.height - point.y),
                     "deltaX": .number(event.scrollingDeltaX), "deltaY": .number(event.scrollingDeltaY),
                     "phase": .number(Double(event.phase.rawValue)), "momentumPhase": .number(Double(event.momentumPhase.rawValue))])
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { ChromiumPopupHost.shared.close(); return }
        key("keyDown", event)
    }
    override func keyUp(with event: NSEvent) { key("keyUp", event) }
    private func key(_ kind: String, _ event: NSEvent) {
        popup?.send(["kind": .string(kind), "keyCode": .number(Double(event.keyCode)),
                     "characters": .string(event.characters ?? ""), "unmodified": .string(event.charactersIgnoringModifiers ?? ""),
                     "repeat": .bool(event.isARepeat), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
}
