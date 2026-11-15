import AppKit
import SwiftUI

/// Enter SwiftUI's hover dispatcher from a real main-actor task. On macOS
/// 27.2 it consults the current Swift executor even for AppKit tracking-area
/// callbacks; those callbacks have no Swift task (#1016–1017, #1026, #1030–1031).
/// Preserve event order, including exits, and discard work after detachment.
/// A pin or folder preview covering the rows keeps their hover suppressed;
/// off that card, the next move sets the rows right (TabGlance.covers).
@MainActor
class ColumnHoverHost<Content: View>: NSHostingView<Content> {
    weak var browser: Browser?
    private var pending: [NSEvent] = []
    private var delivery: Task<Void, Never>?

    override func mouseMoved(with event: NSEvent) { enqueue(event) }
    override func mouseEntered(with event: NSEvent) { enqueue(event) }
    override func mouseExited(with event: NSEvent) { enqueue(event) }

    private func enqueue(_ event: NSEvent) {
        guard window != nil else { return }
        if event.type != .mouseExited, browser?.glance.covers(event) == true { return }
        pending.append(event)
        guard delivery == nil else { return }
        delivery = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        let events = pending
        pending.removeAll()
        delivery = nil
        for event in events {
            guard let window, event.window === window else { continue }
            if event.type != .mouseExited, browser?.glance.covers(event) == true { continue }
            switch event.type {
            case .mouseMoved: super.mouseMoved(with: event)
            case .mouseEntered: super.mouseEntered(with: event)
            case .mouseExited: super.mouseExited(with: event)
            default: break
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pending.removeAll()
        delivery?.cancel()
        delivery = nil
    }
}
