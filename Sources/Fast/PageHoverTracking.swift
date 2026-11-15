import AppKit
import ObjectiveC

/// WebKit's hover tracking owner is separate from WKWebView. Its rectangle
/// still covers sibling UI floating above the page, so gate that owner rather
/// than swallowing the window's event (which the sidebar itself still needs).
@MainActor
enum PageHoverTracking {
    final class Entry {
        let original: NSTrackingArea
        let area: NSTrackingArea
        let keeper: NSResponder
        init(original: NSTrackingArea, area: NSTrackingArea, keeper: NSResponder) {
            self.original = original; self.area = area; self.keeper = keeper
        }
    }
    private final class State: NSObject { var entries: [ObjectIdentifier: Entry] = [:] }
    private static var key: UInt8 = 0

    static func wrap(_ area: NSTrackingArea, in page: NSView) -> NSTrackingArea {
        // Leave the separate enter/exit-only modifier monitor and tooltip
        // tracking untouched: WebKit compares those areas by identity.
        guard area.options.contains(.mouseMoved), let owner = area.owner as? NSObject,
              owner !== page, owner.responds(to: #selector(NSResponder.mouseMoved(with:))) else { return area }
        let state: State
        if let kept = objc_getAssociatedObject(page, &key) as? State { state = kept }
        else { state = State(); objc_setAssociatedObject(page, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        if let entry = state.entries[ObjectIdentifier(area)] { return entry.area }
        let proxy = Owner(page: page, target: owner)
        let replacement = NSTrackingArea(rect: area.rect, options: area.options, owner: proxy, userInfo: area.userInfo)
        // Retain both the original area and the proxy until removal. Tracking
        // areas do not retain their owners, and callers may drop their area.
        state.entries[ObjectIdentifier(area)] = Entry(original: area, area: replacement, keeper: proxy)
        return replacement
    }

    static func take(_ area: NSTrackingArea, from page: NSView) -> Entry? {
        guard let state = objc_getAssociatedObject(page, &key) as? State,
              let id = state.entries.first(where: { $0.value.original === area || $0.value.area === area })?.key else { return nil }
        return state.entries.removeValue(forKey: id)
    }

    static func owns(_ page: NSView, at point: NSPoint) -> Bool {
        guard !page.isHiddenOrHasHiddenAncestor, let content = page.window?.contentView,
              let frame = content.superview,
              let hit = content.hitTest(frame.convert(point, from: nil)) else { return false }
        return hit === page || hit.isDescendant(of: page)
    }

    private final class Owner: NSResponder {
        weak var page: NSView?
        weak var target: NSObject?
        private var inside = false
        init(page: NSView, target: NSObject) { self.page = page; self.target = target; super.init() }
        required init?(coder: NSCoder) { nil }

        private func send(_ selector: Selector, _ event: NSEvent) {
            guard let target, target.responds(to: selector) else { return }
            typealias Send = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            unsafeBitCast(target.method(for: selector), to: Send.self)(target, selector, event)
        }
        private func exitEvent(_ event: NSEvent) -> NSEvent? {
            guard let page else { return nil }
            // WebKit translates NSEvent.mouseExited into a mouse move. An
            // overlay is still inside the page's rectangle, so give that
            // logical leave a point outside it or WebKit can re-enter :hover.
            let outside = page.convert(NSPoint(x: page.bounds.minX - 1, y: page.bounds.minY - 1), to: nil)
            return NSEvent.enterExitEvent(with: .mouseExited, location: outside,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        private func admit(_ event: NSEvent) -> Bool {
            // Agent input intentionally works in its owned offscreen page.
            if PageView.agentActing { return true }
            guard let page, PageHoverTracking.owns(page, at: event.locationInWindow) else {
                if inside, let exit = exitEvent(event) {
                    inside = false
                    send(#selector(NSResponder.mouseExited(with:)), exit)
                }
                return false
            }
            inside = true
            return true
        }
        override func mouseMoved(with event: NSEvent) {
            if admit(event) { send(#selector(NSResponder.mouseMoved(with:)), event) }
        }
        override func mouseEntered(with event: NSEvent) {
            if admit(event) { send(#selector(NSResponder.mouseEntered(with:)), event) }
        }
        override func mouseExited(with event: NSEvent) {
            inside = false
            if let exit = exitEvent(event) { send(#selector(NSResponder.mouseExited(with:)), exit) }
        }
        override func cursorUpdate(with event: NSEvent) {
            if admit(event) { send(#selector(NSResponder.cursorUpdate(with:)), event) }
        }
    }
}
