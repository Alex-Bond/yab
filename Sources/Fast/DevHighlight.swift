import WebKit

// The node DevTools points at (a row of Elements under the pointer, the
// picker's node), drawn on the page as Chromium draws it: the inspector's page
// measures the node (dev-workbench.js, `highlightOf`), this draws it in Yab's
// own world (dev-highlight.js). Chrome's own overlay styles, as they are in
// devtools-frontend's inspector_overlay/tool_highlight.css and common.css.

extension Tab {
    /// Draws what the inspector measured, or hides it ("null").
    func drawHighlight(_ json: String) {
        page.run(DevHighlight.script + "(\(json), \(Double(page.pageZoom)));", in: .yab) { _ in }
    }
}

/// Inspect mode's hands, as Chromium's (inspect_tools.cc): the page gets no
/// mouse at all while picking (WebKit's own switch, `_ignoresNonWheelEvents`,
/// so no hover, no mouseover, no press or click, not even to the window's
/// listeners), the wheel still scrolls it natively; the pointer's place goes
/// to the picker in the page's world (dev-workbench.js PICKER_NATIVE), which
/// finds the node under it; the press picks. Without WebKit's switch the
/// picker's own layer does it (PICKER).
@MainActor enum DevPicker {
    private static var monitor: Any?
    private static weak var web: WKWebView?
    private static var swallowing = false
    static let ignore = NSSelectorFromString("_setIgnoresNonWheelEvents:")

    static var native: Bool { WKWebView.instancesRespond(to: ignore) }
    static var on: Bool { monitor != nil }

    /// What the last start answered, for the bench.
    static var lastStart = ""

    /// A BOOL argument, as the method takes it (perform(_:with:) would hand
    /// it an object's address, never NO).
    private static func set(_ page: WKWebView, ignoring: Bool) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        guard page.responds(to: ignore) else { return }
        unsafeBitCast(page.method(for: ignore), to: Setter.self)(page, ignore, ignoring)
    }

    static func start(_ page: WKWebView) {
        stop()
        guard native else { return }
        web = page
        set(page, ignoring: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]) { event in
            hand(event)
        }
    }

    static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        swallowing = false
        if let web { set(web, ignoring: false) }
        web = nil
    }

    /// The page's CSS point under an event, when the page itself is under it
    /// (not Yab's own views over it).
    static func point(_ event: NSEvent, in page: WKWebView) -> CGPoint? {
        guard let window = page.window, event.window === window, let content = window.contentView else { missed = "another window"; return nil }
        let local = page.convert(event.locationInWindow, from: nil)
        guard page.visibleRect.contains(local) else { missed = "outside \(local) \(page.visibleRect)"; return nil }
        // The page or a view of it; or a host the page is in, whose SwiftUI
        // overlay lies over it (the zone that takes a click back to the page
        // while the card has the keyboard). Not a view of Yab's of its own
        // over the page (the card floating over it, a panel).
        if let hit = (content.superview ?? content).hitTest(event.locationInWindow),
           !(hit === page || hit.isDescendant(of: page) || page.isDescendant(of: hit)) {
            missed = "under \(Swift.type(of: hit)) \(hit.convert(hit.bounds, to: nil))"
            return nil
        }
        let zoom = page.pageZoom * page.magnification
        return CGPoint(x: local.x / zoom, y: (page.isFlipped ? local.y : page.bounds.height - local.y) / zoom)
    }

    /// For the bench: what the hands saw (moves, presses told, presses
    /// let through as not on the page).
    static var seen = [0, 0, 0]
    /// For the bench: why the last event was not the page's.
    static var missed = ""

    private static func hand(_ event: NSEvent) -> NSEvent? {
        guard let page = web else { stop(); return event }
        if event.type == .scrollWheel {
            if point(event, in: page) != nil { tell(page, "scrolled()") }
            return event
        }
        let at = point(event, in: page)
        // Shift, as Chromium's inspect mode: pointer-events: none is hit too.
        let shift = event.modifierFlags.contains(.shift)
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            if let at { seen[0] += 1; tell(page, "move(\(at.x),\(at.y),\(shift))") }
            return event
        case .leftMouseDown:
            guard let at else { seen[2] += 1; return event }
            seen[1] += 1
            swallowing = true
            tell(page, "press(\(at.x),\(at.y),\(shift))")
            return nil
        case .leftMouseUp:
            guard swallowing else { return event }
            swallowing = false
            return nil
        default:
            // Other buttons on the page do nothing while picking, as in Chromium.
            return at == nil ? event : nil
        }
    }

    private static func tell(_ page: WKWebView, _ call: String) {
        page.evaluateJavaScript("window.__yabNativePicker&&window.__yabNativePicker.\(call);void 0", in: nil, in: .page) { _ in }
    }
}

enum DevHighlight {
    static let script = "(function (data, zoom) {\nif (data) data.zoom = zoom;\nvar CSS = " + quoted(css) + ";\n" + PageScript.load("dev-highlight") + "\n})"

    private static func quoted(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static let css = #"""
    :host { all: initial !important; position: fixed !important; inset: 0 !important; margin: 0 !important; padding: 0 !important;
            border: 0 !important; width: auto !important; height: auto !important; max-width: none !important; max-height: none !important;
            background: transparent !important; overflow: hidden !important; pointer-events: none !important; z-index: 2147483647 !important; }
    canvas { position: absolute; left: 0; top: 0; pointer-events: none; }
    .tips { position: absolute; inset: 0; pointer-events: none; margin: 0; padding: 0; font-size: 13px; color: rgb(48 57 66);
            font-family: system-ui, sans-serif; line-height: normal; text-align: left; letter-spacing: normal; word-spacing: normal;
            text-transform: none; font-weight: normal; font-style: normal; white-space: normal; direction: ltr;
            --arrow-width: 15px; --arrow-height: 8px; --arrow-down: polygon(0 0, 100% 0, 50% 100%); --arrow-up: polygon(50% 0, 0 100%, 100% 100%); }
    .tips > div { position: absolute; inset: 0; }
    .hidden { display: none !important; }
    .tooltip-content { position: absolute; user-select: none; background-color: #fff; padding: 5px 8px; border: 1px solid #fff;
            border-radius: 3px; box-sizing: border-box; min-width: 100px; max-width: min(300px, 100% - 4px); z-index: 2;
            background-clip: padding-box; will-change: transform; text-rendering: optimizelegibility; pointer-events: none;
            filter: drop-shadow(0 2px 4px rgb(0 0 0 / 35%)); }
    .tooltip-content::after { content: ''; background: #fff; width: var(--arrow-width); height: var(--arrow-height); clip-path: var(--arrow);
            position: absolute; top: var(--arrow-top); left: var(--arrow-left); visibility: var(--arrow-visibility); }
    .element-info-section { margin-top: 12px; margin-bottom: 6px; }
    .section-name { color: #333; font-weight: 500; font-size: 10px; text-transform: uppercase; letter-spacing: calc(10px / 20); line-height: 12px; }
    .element-info { display: flex; flex-direction: column; }
    .element-info-header { display: flex; align-items: center; }
    .element-info-body { display: flex; flex-direction: column; padding-top: 2px; margin-top: 2px; }
    .element-info-row { display: flex; line-height: 19px; }
    .separator-container { display: flex; align-items: center; flex: auto; margin-left: 7px; }
    .separator { border-top: 1px solid #ddd; width: 100%; }
    .element-info-name { flex-shrink: 0; color: #666; }
    .element-info-gap { flex: auto; }
    .element-info-value-color { display: flex; color: rgb(48 57 66); margin-left: 10px; align-items: baseline; }
    .a11y-icon { width: 16px; height: 16px; background-repeat: no-repeat; display: inline-block; }
    .element-info-value-contrast { display: flex; align-items: center; text-align: right; color: rgb(48 57 66); margin-left: 10px; }
    .element-info-value-contrast .a11y-icon { margin-left: 8px; }
    .element-info-value-icon { display: flex; align-items: center; }
    .element-info-value-text { text-align: right; color: rgb(48 57 66); margin-left: 10px; align-items: baseline; overflow: hidden;
            text-overflow: ellipsis; white-space: nowrap; }
    .color-swatch { display: flex; margin-right: 2px; width: 10px; height: 10px; line-height: 10px;
            background-image: url('data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAwAAAAMCAIAAADZF8uwAAAAGUlEQVQYV2M4gwH+YwCGIasIUwhT25BVBADtzYNYrHvv4gAAAABJRU5ErkJggg=='); }
    .color-swatch-inner { flex: auto; border: 1px solid rgb(128 128 128 / 60%); }
    .element-layout-type { margin-right: 10px; width: 16px; height: 16px; }
    .element-layout-type.grid { background-image: url('data:image/svg+xml,<svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><rect x="2.5" y="2.5" width="4" height="4" stroke="%231A73E8"/><rect x="9.5" y="2.5" width="4" height="4" stroke="%231A73E8"/><rect x="9.5" y="9.5" width="4" height="4" stroke="%231A73E8"/><rect x="2.5" y="9.5" width="4" height="4" stroke="%231A73E8"/></svg>'); }
    .element-layout-type.flex { background-image: url('data:image/svg+xml,<svg fill="none" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path fill-rule="evenodd" clip-rule="evenodd" d="M1 3.5h8v3H1v-3zm-1 0a1 1 0 011-1h8a1 1 0 011 1v3a1 1 0 01-1 1H1a1 1 0 01-1-1v-3zm12 0h3v3h-3v-3zm-1 0a1 1 0 011-1h3a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-3zm-7 6H1v3h3v-3zm-3-1a1 1 0 00-1 1v3a1 1 0 001 1h3a1 1 0 001-1v-3a1 1 0 00-1-1H1zm6 4v-3h8v3H7zm-1-3a1 1 0 011-1h8a1 1 0 011 1v3a1 1 0 01-1 1H7a1 1 0 01-1-1v-3z" fill="%231A73E8"/></svg>'); }
    .element-description { flex: 1 1; font-weight: bold; overflow-wrap: break-word; word-break: break-all; }
    .dimensions { text-align: right; margin-left: 10px; }
    .material-node-width { margin-right: 2px; }
    .material-node-height { margin-left: 2px; }
    .material-tag-name { color: rgb(136 18 128); }
    .material-class-name, .material-node-id { color: rgb(26 26 166); }
    .contrast-text { width: 16px; height: 16px; text-align: center; line-height: 16px; margin-right: 8px; border: 1px solid rgb(0 0 0 / 10%); padding: 0 1px; }
    .a11y-icon-not-ok { background-image: url('data:image/svg+xml,<svg fill="none" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg"><path d="m9 1.5c-4.14 0-7.5 3.36-7.5 7.5s3.36 7.5 7.5 7.5 7.5-3.36 7.5-7.5-3.36-7.5-7.5-7.5zm0 13.5c-3.315 0-6-2.685-6-6 0-1.3875.4725-2.6625 1.2675-3.675l8.4075 8.4075c-1.0125.795-2.2875 1.2675-3.675 1.2675zm4.7325-2.325-8.4075-8.4075c1.0125-.795 2.2875-1.2675 3.675-1.2675 3.315 0 6 2.685 6 6 0 1.3875-.4725 2.6625-1.2675 3.675z" fill="%239e9e9e"/></svg>'); }
    .a11y-icon-warning { background-image: url('data:image/svg+xml,<svg fill="none" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg"><path d="m8.25 11.25h1.5v1.5h-1.5zm0-6h1.5v4.5h-1.5zm.7425-3.75c-4.14 0-7.4925 3.36-7.4925 7.5s3.3525 7.5 7.4925 7.5c4.1475 0 7.5075-3.36 7.5075-7.5s-3.36-7.5-7.5075-7.5zm.0075 13.5c-3.315 0-6-2.685-6-6s2.685-6 6-6 6 2.685 6 6-2.685 6-6 6z" fill="%23e37400"/></svg>'); }
    .a11y-icon-ok { background-image: url('data:image/svg+xml,<svg fill="none" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg"><path d="m9 1.5c-4.14 0-7.5 3.36-7.5 7.5s3.36 7.5 7.5 7.5 7.5-3.36 7.5-7.5-3.36-7.5-7.5-7.5zm0 13.5c-3.3075 0-6-2.6925-6-6s2.6925-6 6-6 6 2.6925 6 6-2.6925 6-6 6zm-1.5-4.35-1.95-1.95-1.05 1.05 3 3 6-6-1.05-1.05z" fill="%230ca40c"/></svg>'); }
    """#
}
