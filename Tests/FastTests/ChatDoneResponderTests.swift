import AppKit
import Testing
@testable import Fast

/// Native responder values only. No chat, router, browser or key event is made.
@MainActor
struct ChatDoneResponderTests {
    @Test func readOnlySelectableTextLeavesDoneAvailable() {
        let text = NSTextView(frame: .zero)
        text.string = "A finished answer can be selected."
        text.isEditable = false
        text.isSelectable = true
        #expect(text.isSelectable && !text.isEditable)
        #expect(!ContentView.textResponderOwnsDone(text))
    }

    @Test func anEditableTextViewKeepsDoneWithItsEditor() {
        let text = NSTextView(frame: .zero)
        text.isEditable = true
        #expect(text.isEditable)
        #expect(ContentView.textResponderOwnsDone(text))
    }

    @Test func theSameResponderFollowsItsCurrentEditingMode() {
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        #expect(!ContentView.textResponderOwnsDone(text))
        text.isEditable = true
        #expect(ContentView.textResponderOwnsDone(text))
        text.isEditable = false
        #expect(!ContentView.textResponderOwnsDone(text))
    }

    @Test func nilAndNonTextRespondersDoNotTakeDone() {
        #expect(!ContentView.textResponderOwnsDone(nil))
        #expect(!ContentView.textResponderOwnsDone(NSResponder()))
        #expect(!ContentView.textResponderOwnsDone(NSView(frame: .zero)))
    }
}
