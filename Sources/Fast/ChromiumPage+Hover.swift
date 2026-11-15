import AppKit

/// The link under the pointer on a Chromium page, for the pill at the
/// page's bottom left (LinkStatus), as WebKit's mouseDidMoveOverElement
/// tells it on a WebKit page.
///
/// Chromium says it through CEF's status message (OnStatusMessage), whose
/// words are the link's address or nothing. Only the pointer's own moves
/// inside this page admit them: a page laid out under a pointer at rest,
/// or one the pointer has left, says nothing to the pill. LinkStatus.Rule
/// still decides what a scroll's message shows.
extension ChromiumPage {
    /// The helper's status message for this page: a link's address, or "".
    /// Retired pages and other tabs' messages never get here (receive).
    func hoverStatus(_ text: String) {
        hoverCounts.status += 1; hoverCounts.last = text; hoverCounts.heard = Array((hoverCounts.heard + [text]).suffix(12))
        guard hoverAdmitted, let tab = navigationTab else { return }
        if LinkGap.cut("hover") { return }
        let url = Self.hoverLink(text)
        // CEF's empty status and its link arrive asynchronously, sometimes
        // after the last native move. Keep that move's admission through the
        // empty status, then consume it for the first actual link. Later
        // layout-only status changes cannot manufacture another move.
        if ProcessInfo.processInfo.systemUptime - hoverMovedAt > 0.25 { hoverMovePending = false }
        if url != nil, hoverMovePending {
            LinkStatus.shared.pointerMoved()
            hoverMovePending = false
        }
        LinkStatus.shared.pointed(at: url, in: tab.id, keys: NSEvent.modifierFlags)
    }

    /// A status message names a link only as an absolute address; any
    /// other words a page might set are not a link.
    nonisolated static func hoverLink(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty,
              text.lowercased().hasPrefix(scheme.lowercased() + ":") else { return nil }
        return url
    }

    /// The pointer moved or dragged inside this page.
    func hoverMoved() {
        hoverAdmitted = true
        hoverMovePending = true
        hoverMovedAt = ProcessInfo.processInfo.systemUptime
        hoverCounts.moved += 1
    }

    func hoverScrolled() {
        hoverMovePending = false
        LinkStatus.shared.scrolled()
    }

    /// The pointer left the page, or the page left the screen: what it
    /// pointed at is no longer under the pointer.
    func hoverLeft() {
        hoverAdmitted = false
        hoverMovePending = false
        if let tab = navigationTab { LinkStatus.shared.forget(tab.id) }
    }
}
