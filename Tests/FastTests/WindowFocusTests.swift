import AppKit
import SwiftUI
import Testing
@testable import Fast

@Suite(.serialized)
struct WindowFocusTests {
    @MainActor @Test func hostedWindowKeepsNeutralStartupFocus() async throws {
        var ready = false
        let host = NSHostingView(rootView: Button("Close Tab") {}
            .frame(width: 300, height: 200)
            .background(WindowSetup { _ in ready = true }))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready)
        window.makeKey()
        #expect(window.initialFirstResponder is WindowSetup.Probe)
        #expect(window.firstResponder === window.initialFirstResponder)
    }

    @MainActor @Test func restoredWindowStartsWithoutFocusingCloseButton() {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let close = NSButton(title: "Close Tab", target: nil, action: nil)
        close.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
        let probe = WindowSetup.Probe(prepare: nil, ready: { _ in })
        content.addSubview(close)
        content.addSubview(probe)
        window.contentView = content
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.makeKey()

        #expect(window.initialFirstResponder === probe)
        #expect(window.firstResponder === probe)
        #expect(window.firstResponder !== close)
        #expect(!probe.canBecomeKeyView)
        #expect(probe.hitTest(.zero) == nil)

        // Keyboard navigation can still leave the neutral startup target.
        let input = NSTextView(frame: content.bounds)
        content.addSubview(input)
        probe.nextKeyView = input
        window.selectNextKeyView(probe)
        #expect(window.firstResponder === input)
    }

    @MainActor @Test func attachingProbePreservesFocusedInput() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = input
        #expect(window.makeFirstResponder(input))

        var ready = false
        input.addSubview(WindowSetup.Probe(prepare: nil, ready: { _ in ready = true }))
        for _ in 0..<100 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(ready)
        #expect(window.firstResponder === input)
    }
}
