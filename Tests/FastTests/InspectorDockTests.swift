import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct InspectorDockTests {
    @Test func attachmentRunsAfterTheMoveAndCanBeCancelled() async throws {
        _ = NSApplication.shared
        let dock = InspectorDock(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        let window = NSWindow(contentRect: dock.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var attached = false
        dock.whenInWindow { attached = true }
        window.contentView = dock
        #expect(!attached) // Not reentrant inside AppKit's view move.
        try await Task.sleep(for: .milliseconds(50))
        #expect(attached)

        let cancelled = InspectorDock(frame: dock.frame)
        var ranCancelled = false
        cancelled.whenInWindow { ranCancelled = true }
        cancelled.cancelWaitingForWindow()
        window.contentView = cancelled
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ranCancelled)
    }
}
