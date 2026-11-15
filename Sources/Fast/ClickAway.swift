import AppKit
import SwiftUI

/// A menu of our own drawn in a window, not the Mac's: a click anywhere
/// but on it, or on what toggles it, puts it away, as a menu goes. The
/// click still does its own; only the menu is gone after it.
@MainActor
final class ClickAway {
    /// Where a click leaves the menu up (ClickZone): the menu, and the
    /// buttons that toggle it on their own on the mouse's way up.
    let zones = NSHashTable<NSView>.weakObjects()
    /// Only clicks in this window count, when set: one standing over a
    /// window's own content, which a click in a panel or another window
    /// leaves be.
    var within: (() -> NSWindow?)?
    private let away: () -> Void
    private let events: NSEvent.EventTypeMask
    private var clicks: Any?
    private var pressedOutside = false

    init(on events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
         away: @escaping () -> Void) {
        self.events = events
        self.away = away
    }

    /// Listening only while the menu is up.
    func watch(_ up: Bool) {
        if up, clicks == nil {
            // A release only counts if its press also began outside. Text
            // selected in a field can be dragged beyond the field's edge.
            let observed = events.contains(.leftMouseUp) ? events.union(.leftMouseDown) : events
            clicks = NSEvent.addLocalMonitorForEvents(matching: observed) { [weak self] event in
                self?.clicked(event)
                return event
            }
        } else if !up, let clicks {
            NSEvent.removeMonitor(clicks)
            self.clicks = nil
            pressedOutside = false
        }
    }

    private func clicked(_ event: NSEvent) {
        if event.type == .leftMouseDown { pressedOutside = false }
        if event.type == .leftMouseUp {
            guard pressedOutside else { return }
            pressedOutside = false
        }
        if let within, event.window == nil || event.window !== within() { return }
        for zone in zones.allObjects where zone.window === event.window {
            if zone.convert(zone.bounds, to: nil).contains(event.locationInWindow) { return }
        }
        if event.type == .leftMouseDown, events.contains(.leftMouseUp) {
            pressedOutside = true
            if !events.contains(.leftMouseDown) { return }
        }
        // After the click is taken: the menu gone, the click still does its own.
        DispatchQueue.main.async { self.away() }
    }
}

/// Where a click leaves a ClickAway's menu up, as a background of the
/// menu or its button. Draws nothing, takes no clicks.
struct ClickZone: NSViewRepresentable {
    let away: ClickAway

    final class Zone: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Zone {
        let zone = Zone()
        away.zones.add(zone)
        return zone
    }

    func updateNSView(_ zone: Zone, context: Context) {}
}
