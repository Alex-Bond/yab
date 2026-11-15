import AppKit
import Testing
@testable import Fast

/// The sidebar handles events inside a local monitor, before AppKit's
/// currentEvent necessarily names that move. Keep the real release point
/// even when the physical pointer and the previous move are elsewhere.
@MainActor
@Suite(.serialized)
struct SidebarTearOffPointerTests {
    private final class Surface: NSView {
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
    }

    @Test(arguments: [CGPoint(x: -1600, y: 0), CGPoint(x: 1600, y: 0),
                      CGPoint(x: 0, y: 1000), CGPoint(x: 0, y: -1000)])
    func sidebarReleaseUsesItsOwnEventOnAnotherDisplay(_ offset: CGPoint) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = Surface(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = surface
        let grip = ColumnGrip()
        grip.view = surface
        grip.attempt = { _ in true }
        grip.watch(true)
        defer { grip.watch(false); window.close() }

        let destination = CGRect(x: window.frame.minX + offset.x,
                                 y: window.frame.minY + offset.y, width: 1200, height: 900)
        let drop = CGPoint(x: destination.midX, y: destination.maxY - 180)
        var release: CGPoint?
        var states: [ColumnGrip.State] = []
        grip.changed = { grip in
            states.append(grip.state)
            if grip.state == .ended {
                // This is the same event handoff rowEnded gives finish.
                release = TearOff.pointer(in: window, event: grip.event)
            }
        }

        func send(_ type: NSEvent.EventType, at screen: CGPoint, number: Int) throws {
            let event = try #require(NSEvent.mouseEvent(with: type,
                location: window.convertPoint(fromScreen: screen), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + Double(number) / 100,
                windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.sendEvent(event)
            #expect(grip.event == nil, "an autoscroll tick must not reuse a stale mouse event")
        }

        let start = window.convertPoint(toScreen: CGPoint(x: 100, y: 300))
        try send(.leftMouseDown, at: start, number: 1)
        // The last move is still on the source display; release carries
        // the final position across the display boundary in its own event.
        try send(.leftMouseDragged, at: CGPoint(x: start.x + 30, y: start.y), number: 2)
        try send(.leftMouseUp, at: drop, number: 3)
        #expect(states == [.began, .ended])
        let pointer = try #require(release)
        #expect(pointer == drop)
        let frame = TearRules.newWindow(pointer: pointer, grab: CGPoint(x: 100, y: 100),
                                        size: CGSize(width: 800, height: 600), visible: destination)
        #expect(destination.contains(frame))
        #expect(!window.frame.intersects(frame))
    }
}
