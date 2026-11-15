import AppKit
import SwiftUI

/// A row of ⌘T's list, right-clicked: the row chosen, and ⌘K's panel up
/// with what it can have done to it, and not a menu of its own. A view over the row that takes
/// only a right-click or a control-click; every other press, and the
/// pointer's hover, go through to the row.
struct FieldRowMenu: NSViewRepresentable {
    /// The row's name for the bench: "row 3", "clip 0".
    let name: String
    let open: @MainActor () -> Void

    func makeNSView(context: Context) -> FieldRowMenuView { FieldRowMenuView() }

    func updateNSView(_ view: FieldRowMenuView, context: Context) {
        view.open = open
        FieldRowMenuView.shown.setObject(view, forKey: name as NSString)
    }

    /// Where each row is on screen, global and from the top-left as an
    /// event is posted, for the bench's hand.
    @MainActor static var frames: [String: [Double]] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var out: [String: [Double]] = [:]
        for case let name as NSString in FieldRowMenuView.shown.keyEnumerator() {
            guard let view = FieldRowMenuView.shown.object(forKey: name), let window = view.window, window.isVisible else { continue }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            out[name as String] = [rect.minX, top - rect.maxY, rect.width, rect.height]
        }
        return out
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FieldRowMenuView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class FieldRowMenuView: NSView {
    var open: (@MainActor () -> Void)?
    @MainActor static let shown = NSMapTable<NSString, FieldRowMenuView>.strongToWeakObjects()

    override func hitTest(_ point: NSPoint) -> NSView? {
        BookmarkBar.asksForMenu(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { open?() }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        MainActor.assumeIsolated { open?() }
    }

    /// No menu of AppKit's under the panel.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}
