import AppKit
import WebKit

// A site's menu at the top of the page moves the window, as in Arc (register
// #454, mail #714): its words and the room between them, never a
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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let grab = body["grab"] as? Bool else { return }
        MainActor.assumeIsolated {
            (message.webView as? PageView)?.topGrab = grab
        }
    }
}

/// A press on the page's top, from the press to the drag or the click.
struct TopPress {
    let down: NSEvent
    var moved = false

    /// The press is one to hold: the page said the pointer is on its menu, the press is a plain one, and the point is in the band.
    @MainActor static func holds(_ event: NSEvent, in page: PageView) -> Bool {
        guard page.topGrab, !PageView.agentActing,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let window = page.window, !window.styleMask.contains(.fullScreen) else { return false }
        let point = page.convert(event.locationInWindow, from: nil)
        let fromTop = page.isFlipped ? point.y : page.bounds.height - point.y
        return fromTop >= 0 && fromTop <= TopDragRelay.band * max(page.pageZoom, 0.25) + 2
    }
}
