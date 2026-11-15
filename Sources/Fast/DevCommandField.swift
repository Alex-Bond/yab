import AppKit
import SwiftUI

/// Quick Open owns a real field editor, including focus after the menu shortcut.
struct DevCommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let command: (Selector) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBordered = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.focusRingType = .none
        field.placeholderString = placeholder; field.stringValue = text
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                self.currentEditor()?.selectedRange = NSRange(location: self.stringValue.utf16.count, length: 0)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DevCommandField
        init(_ parent: DevCommandField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            parent.command(commandSelector)
        }
    }
}
