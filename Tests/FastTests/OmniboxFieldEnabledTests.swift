import AppKit
import Testing
@testable import Fast

/// Crash #112 (0.39.2): the address field was disabled from SwiftUI's layout
/// pass while it was editing, which ends the editing inside that pass.
@MainActor
struct OmniboxFieldEnabledTests {
    @Test func aFieldBeingEditedIsDisabledAfterThePassNotInIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 10, y: 40, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)

        AddressField.follow(showing: false, field: field) { false }
        #expect(field.isEnabled, "disabling must wait while the field edits")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!field.isEnabled)

        // A field not being edited changes at once, both ways.
        AddressField.follow(showing: true, field: field) { true }
        #expect(field.isEnabled)
        AddressField.follow(showing: false, field: field) { false }
        #expect(!field.isEnabled)
    }
}
