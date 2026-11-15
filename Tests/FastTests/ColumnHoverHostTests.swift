import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ColumnHoverHostTests {
    private final class RecordingHost<Content: View>: ColumnHoverHost<Content> {
        var native: [NSEvent.EventType] = []
        var nativeTasks: [Bool] = []
        var insideMove: NSEvent?

        private func record(_ event: NSEvent) {
            native.append(event.type)
            nativeTasks.append(withUnsafeCurrentTask { $0 != nil })
            if event.type == .mouseMoved, bounds.contains(convert(event.locationInWindow, from: nil)) {
                insideMove = event
            }
        }
        override func mouseMoved(with event: NSEvent) { record(event); super.mouseMoved(with: event) }
        override func mouseEntered(with event: NSEvent) { record(event); super.mouseEntered(with: event) }
        override func mouseExited(with event: NSEvent) { record(event); super.mouseExited(with: event) }
    }

    @Test func nativeHoverEntersSwiftUIFromATaskAndDetachedEventsAreDiscarded() async throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        try #require(app.isRunning, "Run with scripts/runs/appkit_gate_tests.py: native SwiftUI hover requires a synchronous AppKit host")
        let screen = try #require(TestScreen.screen)
        // In the middle of the screen: at its bottom-left corner the Dock's
        // window (layer 20) lay over the fixture on m4 and took the hover, so
        // the pointer helper's move ended in mouseExited (0.46.33's batch).
        let window = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 120,
            y: screen.visibleFrame.midY - 120, width: 240, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        var heard: [Bool] = []
        var taskBacked: [Bool] = []
        let host = RecordingHost(rootView: Color.blue.onHover { inside in
            heard.append(inside)
            taskBacked.append(withUnsafeCurrentTask { $0 != nil })
        })
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if app.isActive && window.isKeyWindow && !host.trackingAreas.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(app.isActive && window.isKeyWindow && !host.trackingAreas.isEmpty,
                     "The native fixture must be active, key, and tracking before input")

        func move(_ point: NSPoint, until condition: () -> Bool) async throws {
            let onScreen = window.convertPoint(toScreen: point)
            let top = try #require(NSScreen.screens.first).frame.maxY
            // The farm grants its Python hand permission to post events;
            // a newly compiled test helper does not inherit that permission.
            // The release's QA names the Python the farm validated, with
            // PyObjC (qa_prepare.py); the PATH's first python3 there is
            // Xcode's, which has no AppKit.
            let hand = Process()
            hand.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            let python = ProcessInfo.processInfo.environment["YAB_QA_PYTHON"].flatMap { $0.isEmpty ? nil : $0 } ?? "python3"
            hand.arguments = [python, "evals/window-tiling/pointer.py", "move-to-pid",
                              String(ProcessInfo.processInfo.processIdentifier), String(window.windowNumber),
                              String(Double(onScreen.x)), String(Double(top - onScreen.y))]
            try hand.run()
            hand.waitUntilExit()
            try #require(hand.terminationStatus == 0, "The farm pointer helper must deliver real input")
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(20))
                if condition() { return }
            }
            try #require(condition(), "Native hover missing: active=\(app.isActive), key=\(window.isKeyWindow), frame=\(window.frame), pointer=\(NSEvent.mouseLocation), events=\(host.native), hover=\(heard)")
        }

        // Fabricated NSEvents (trackingNumber: 0, no real tracking area)
        // do not exercise SwiftUI hover, even in a running AppKit host.
        // Enter, move within, and leave a real window instead.
        try await move(NSPoint(x: -20, y: -20), until: { window.isVisible })
        heard.removeAll(); taskBacked.removeAll(); host.native.removeAll(); host.nativeTasks.removeAll()
        try await move(NSPoint(x: 120, y: 120), until: { heard.contains(true) })
        try await move(NSPoint(x: 140, y: 120), until: { host.insideMove != nil })
        #expect(host.native.contains(.mouseEntered))
        #expect(host.native.contains(.mouseMoved))
        #expect(!host.nativeTasks.isEmpty && host.nativeTasks.allSatisfy { !$0 }, "Exercise task-free native tracking callbacks")
        try await move(NSPoint(x: -20, y: -20), until: { heard.last == false })
        #expect(host.native.contains(.mouseExited))
        #expect(!taskBacked.isEmpty && taskBacked.allSatisfy { $0 }, "SwiftUI entry and exit must execute inside a main-actor task")

        let moved = try #require(host.insideMove)
        heard.removeAll()
        host.mouseMoved(with: moved)
        host.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!heard.contains(true), "Detachment cancels pending hover")
    }
}
