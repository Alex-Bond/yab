import AppKit
import Foundation
import Testing
@testable import Fast

/// Crash #64 (0.35.13): ⌘Z in a text field ran -[NSCellUndoManager undo]
/// into freed memory. A plain field's session undo hands on to the window's
/// once it has nothing of its own, and the address field's own editor filed
/// its typing straight in the window's, where it stayed after the field was
/// freed. Measured with AppKit alone in evals/undo-crash/cells.swift.
@Suite(.serialized)
struct FieldUndoTests {
    @MainActor private func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    @MainActor private func edit(_ field: NSTextField, in window: NSWindow) -> NSTextView? {
        window.makeFirstResponder(field)
        return field.currentEditor() as? NSTextView
    }

    @MainActor @Test func theAddressFieldLeavesNothingInTheWindowsUndo() throws {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let plain = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(plain)
        let undo = try #require(window.undoManager)
        undo.removeAllActions()

        var address: AddressTextField? = AddressTextField(frame: NSRect(x: 10, y: 50, width: 200, height: 24))
        window.contentView?.addSubview(address!)
        let editor = try #require(edit(address!, in: window))
        editor.insertText("gone", replacementRange: editor.selectedRange())
        spin()
        // Its typing undoes in the field itself.
        #expect(editor.undoManager?.canUndo == true)
        #expect(!undo.canUndo, "the address field's typing went into the window's undo")

        _ = edit(plain, in: window)
        address?.removeFromSuperview()
        autoreleasepool { address = nil }
        spin()
        #expect(!undo.canUndo, "the freed address field's typing stayed in the window's undo")

        // ⌘Z in the plain field: nothing of its own, nothing of the window's.
        let typed = try #require(edit(plain, in: window))
        #expect(typed.undoManager?.canUndo != true)
    }
}
