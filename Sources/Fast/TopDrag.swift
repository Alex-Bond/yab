import AppKit
import WebKit

// A site's menu at the top of the page moves the window, as in Arc (register
// #454, Mike's mail #714): only empty background, never header words or a
// link, button or menu, whose press the page must have at once. The page says where it may be grabbed as the pointer goes
// (top-drag.js); a press there is held back from the page, and moved past
// the slack it is the window's, handed to the window server as a title
// bar's is (StripPress, NSWindow.performDrag), so the screen's edges tile
// it. Let go without moving and the page gets its click after all, the
// press first: a link still opens, a menu the site has open still closes.

/// The page telling where its top may be grabbed, for whichever page it came from.
final class TopDragRelay: NSObject, WKScriptMessageHandler {
    static let name = "yabTopDrag"
    static let shared = TopDragRelay()

    /// How far down the page the band goes, in the page's own points: a
    /// site's header, the one Arc moves the window by.
    static let band: CGFloat = 60

    @MainActor static let script = WKUserScript(
        source: PageScript.load("top-drag", vars: ["BAND": String(Int(band))]),
        injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)

    /// A positive hover is useful only for the point the page inspected.
    /// Missing/invalid coordinates never authorize withholding a page press.
    static func point(grab: Bool, x: Double?, y: Double?) -> CGPoint? {
        guard grab, let x, let y, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let grab = body["grab"] as? Bool else { return }
        MainActor.assumeIsolated {
            guard let page = message.webView as? PageView else { return }
            page.topGrab = grab
            page.topGrabPoint = Self.point(grab: grab, x: body["x"] as? Double, y: body["y"] as? Double)
        }
    }
}

/// A press on the page's top, from the press to the drag or the click.
@MainActor
final class TopPress {
    private enum State { case checking, handle, finished }
    private var state = State.checking
    private let down: NSEvent
    private var pending: [NSEvent] = []
    private var moved = false
    private let forward: (NSEvent) -> Void
    private let drag: (NSEvent) -> Void
    private let finished: () -> Void

    init(down: NSEvent, forward: @escaping (NSEvent) -> Void,
         drag: @escaping (NSEvent) -> Void, finished: @escaping () -> Void) {
        self.down = down
        self.forward = forward
        self.drag = drag
        self.finished = finished
    }

    /// A hover permission is not a press permission. The DOM may have
    /// replaced empty background with an account control at the same point.
    /// Ask the isolated-world hit test for this down, keeping its event order
    /// until the answer. No timer, synthetic DOM event or cached authorization.
    func check(in page: any PageScriptTarget, zoom: CGFloat) {
        // The hover hint permits a subpixel match; the actual native down,
        // not that sample, supplies the CSS point for the current hit test.
        let local = page.convert(down.locationInWindow, from: nil)
        let scale = max(zoom, 0.25)
        let point = CGPoint(x: local.x / scale,
                            y: (page.isFlipped ? local.y : page.bounds.height - local.y) / scale)
        page.call("return typeof window.__yabTopDragHit === 'function' && window.__yabTopDragHit(x, y)",
                  arguments: ["x": Double(point.x), "y": Double(point.y)], in: .yab, gesture: false) { [weak self] result in
            switch result {
            case .success(let value): self?.resolve(value as? Bool == true)
            // An unavailable hit test cannot claim the page's original input.
            case .failure: self?.resolve(false)
            }
        }
    }

    func resolve(_ handle: Bool) {
        guard state == .checking else { return }
        let events = pending
        pending.removeAll()
        // A completed gesture cannot be handed to the window server after
        // release. Give the page its entire original sequence in order.
        if !handle || events.contains(where: { $0.type == .leftMouseUp }) {
            state = .finished
            finished()
            forward(down)
            events.forEach(forward)
            return
        }
        state = .handle
        events.forEach(receive)
    }

    func receive(_ event: NSEvent) {
        switch state {
        case .checking:
            pending.append(event)
        case .handle:
            if event.type == .leftMouseUp {
                state = .finished
                finished()
                if !moved { forward(down); forward(event) }
            } else if event.type == .leftMouseDragged, !moved {
                let from = down.locationInWindow, now = event.locationInWindow
                if StripPress.drags(now.x - from.x, now.y - from.y) {
                    moved = true
                    drag(down)
                }
            }
        case .finished:
            break
        }
    }

    @MainActor static var replaySupported: Bool {
        if #available(macOS 26, *) {
            return Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool != true
        }
        return false
    }

    /// A hover hint worth checking against the current DOM. It never
    /// authorizes a window gesture by itself.
    @MainActor static func holds(_ event: NSEvent, in page: PageView) -> Bool {
        holds(event, in: page, grab: page.topGrab, zoom: page.pageZoom, at: page.topGrabPoint)
    }

    @MainActor static func holds(_ event: NSEvent, in page: NSView, grab: Bool, zoom: CGFloat, at inspected: CGPoint? = nil) -> Bool {
        // WebKit 620/621 can lose a mouseDown replayed from mouseUp. Never
        // enter the hold/replay path on Sequoia. The older-design probe uses
        // the same safe path even on a newer worker; it is not old WebKit.
        guard replaySupported, grab, let inspected, !PageView.agentActing,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let window = page.window, !window.styleMask.contains(.fullScreen) else { return false }
        let point = page.convert(event.locationInWindow, from: nil)
        let fromTop = page.isFlipped ? point.y : page.bounds.height - point.y
        // A move onto a link can reach AppKit before its asynchronous DOM
        // hover reply. A Boolean from a previous gap must not take that press
        // and turn a small hand movement into a window drag. Default to the
        // page unless this exact point was approved. Keep the drag slack itself.
        let scale = max(zoom, 0.25)
        return inspected.x.isFinite && inspected.y.isFinite && page.bounds.contains(point)
            && abs(point.x - inspected.x * scale) < 0.5
            && abs(fromTop - inspected.y * scale) < 0.5
            && fromTop >= 0 && fromTop <= TopDragRelay.band * scale + 2
    }
}
