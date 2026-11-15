import AppKit
import YabCoreClient

/// A Chromium page's pointer lock, held where Chrome holds it (R2472, #1921).
///
/// Chrome's own window freezes and hides the pointer while a page holds it
/// (RenderWidgetHostViewCocoa setCursorLocked:) and reads each move's deltas.
/// A Chromium tab's view lives in YabCore, a background process, where the
/// freeze and the hide change nothing on screen, and Yab sent its moves as
/// positions alone, so a page saw movementX/Y 0 under a frozen pointer and a
/// pointer that wandered off the page under a free one. YabCore now says when
/// the page takes and gives back the pointer (page.pointerLock); Yab, the
/// front app, freezes and hides it for that time, and sends the page's mouse
/// events whole (`fields`), which YabCore hands to Chrome's view to read.
/// The lock ends where Chromium ends it (Esc, the page, a hidden tab, lost
/// focus); Yab lets the pointer go at once when the page leaves the key
/// window or its tab, without waiting for that word.
@MainActor
enum ChromiumPointerLock {
    private static weak var holder: ChromiumPage?
    private static var frozen = false
    /// Where the pointer was when it was moved onto the page to lock it.
    private static var returnTo: CGPoint?
    /// The first move after that carries the jump; Chrome drops it too.
    private static var skipNext = false

    static func page(_ page: ChromiumPage, locked: Bool) {
        page.pointerLocked = locked
        if locked { hold(page) } else { release(page) }
    }

    /// Whether the page is the one holding the pointer right now.
    static func holds(_ page: ChromiumPage) -> Bool { frozen && holder === page }

    private static func hold(_ page: ChromiumPage) {
        guard NSApp.isActive, let window = page.window, window.isKeyWindow, !page.isHiddenOrHasHiddenAncestor else { return }
        if frozen, holder !== page { release(holder) }
        holder = page
        guard !frozen else { return }
        let inView = page.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !page.bounds.contains(inView) {
            // As Chromium: a pointer off the page goes to its middle first.
            returnTo = CGEvent(source: nil)?.location
            let middle = window.convertPoint(toScreen: page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil))
            CGWarpMouseCursorPosition(CGPoint(x: middle.x, y: (NSScreen.screens.first?.frame.height ?? 0) - middle.y))
            skipNext = true
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        frozen = true
    }

    /// Gives the pointer back if `page` (or nobody) holds it.
    static func release(_ page: ChromiumPage?) {
        guard holder == nil || holder === page else { return }
        holder = nil
        skipNext = false
        guard frozen else { return }
        frozen = false
        if let returnTo { CGWarpMouseCursorPosition(returnTo) }
        returnTo = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    /// True for the one move to drop after the pointer was moved onto the page.
    static func dropsMove() -> Bool {
        guard skipNext else { return false }
        skipNext = false
        return true
    }

    /// The fields of a locked page's mouse event: its own CGEvent, whole.
    static func fields(_ event: NSEvent) -> [String: JSONValue] {
        guard let data = event.cgEvent?.data as Data?, !data.isEmpty else { return [:] }
        return ["event": .string(data.base64EncodedString())]
    }
}
