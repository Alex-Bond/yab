import AppKit

// The disk image's window and the browser's first one are meant to be one
// place: the same dark ground, the same light from the top-left corner. So
// yab is told where the image's window is, and opens its first window right
// there before growing to its own size, the Finder window seems to become
// the browser. Where that window is has to be read from the window list,
// which gives any app every window's owner and frame but, without the
// screen-recording permission nobody should be asked for here, no titles.
// So it is recognized by its size, which Installer/dmg.py sets. If it can't
// be found, or has been resized, yab opens the way it always does.

enum Handoff {
    /// The image window's content, as Installer/dmg.py and
    /// Installer/background.swift lay it out.
    static let content = CGSize(width: 640, height: 400)

    /// The Finder window showing the image, in the window server's
    /// coordinates, from the top-left of the main display, as the
    /// argument yab reads: "x,y,width,height".
    static func finderWindow() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back: the one just double-clicked in is the front one.
        for window in list {
            guard window[kCGWindowOwnerName as String] as? String == "Finder",
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            // Width exact; height with room for a title bar and, when the
            // user keeps them, Finder's tabs.
            guard abs(frame.width - content.width) <= 1,
                  frame.height >= content.height, frame.height <= content.height + 64 else { continue }
            return [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
        }
        return nil
    }

    /// Until the app just opened has a window on screen, or a few seconds
    /// have gone by: the image is put away only then, so its window closes
    /// behind the browser's and never before it is there.
    static func waitForWindow(of pid: pid_t, timeout: TimeInterval = 6, then done: @escaping () -> Void) {
        let started = Date()
        func look() {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let shown = list.contains {
                ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
                    && $0[kCGWindowLayer as String] as? Int == 0
                    && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
            }
            if shown || Date().timeIntervalSince(started) > timeout {
                // A beat more, for the window to have grown past the Finder's.
                DispatchQueue.main.asyncAfter(deadline: .now() + (shown ? 0.9 : 0), execute: done)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: look)
            }
        }
        look()
    }
}
