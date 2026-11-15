import AppKit
import Testing
@testable import Fast

// Words an input method is composing (feedback #658: Return in Find on Page
// went to the next match and left Pinyin uncommitted): fields that take
// Return, Escape or the arrows themselves let the key go while there is
// marked text.
@MainActor
struct InputMethodTests {
    /// #524/#636/#644: the app's update notification rechecks a composition
    /// before returning to AppKit, including when it was silently unmarked.
    @Test func updateNotificationClearsSilentlyUnmarkedTextSynchronously() throws {
        let center = NotificationCenter()
        let marking = InputMethod.Marking(center: center)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        center.post(name: NSText.didChangeNotification, object: editor)
        #expect(marking.composing)
        editor.unmarkText()
        center.post(name: NSApplication.didUpdateNotification, object: NSApp)
        #expect(!marking.composing)
    }

    @Test func backgroundEditingNotificationIsDeliveredOnMain() async {
        let center = NotificationCenter()
        let marking = InputMethod.Marking(center: center)
        // Empty/non-text objects are valid notifications too. Neither may
        // cause the observer to touch AppKit from the posting thread.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                center.post(name: NSText.didEndEditingNotification, object: nil)
                center.post(name: NSApplication.didUpdateNotification, object: nil)
                done.resume()
            }
        }
        #expect(!marking.composing)
    }

    @Test func markedTextIsComposing() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        #expect(!InputMethod.composing(editor))
        editor.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(InputMethod.composing(editor))
        // A candidate committed: the next Return is the field's again.
        editor.insertText("你好", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(!InputMethod.composing(editor))
        #expect(editor.string == "你好")
    }

    @Test func typedWordsAreNotComposing() {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        editor.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!InputMethod.composing(editor))
    }

    @Test func fieldEditorInAWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(!InputMethod.composing(window.firstResponder))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(InputMethod.composing(window.firstResponder))
        editor.unmarkText()
        #expect(!InputMethod.composing(window.firstResponder))
    }

    @Test func nothingHoldingTheKeyboard() {
        #expect(!InputMethod.composing(nil))
        #expect(!InputMethod.composing(NSView()))
    }

    // Row 1014: a placeholder drawn over a field stayed over Kana being
    // composed, since the field's binding gets its words only once they are
    // committed. It now hides while the field holding the keyboard has
    // marked text.
    @Test func placeholderGoesWhileComposing() throws {
        let marking = InputMethod.Marking.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)

        editor.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(marking.composing)
        #expect(InputMethod.composing(focused: true))
        // Another field's placeholder, not holding the keyboard, stays.
        #expect(!InputMethod.composing(focused: false))

        // A transcript's selection moving says nothing about the field.
        let other = NSTextView(frame: NSRect(x: 0, y: 30, width: 200, height: 20))
        other.string = "a reply"
        other.setSelectedRange(NSRange(location: 2, length: 3))
        #expect(marking.composing)

        // Committed: the field's words are its own, the placeholder's call again.
        editor.insertText("日本", replacementRange: editor.markedRange())
        #expect(!marking.composing)
        #expect(!InputMethod.composing(focused: true))
        #expect(field.stringValue == "日本")
    }

    @Test func droppedOrLeftEndsComposing() throws {
        let marking = InputMethod.Marking.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        let next = NSTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 22))
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(next)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)

        // Escape in the input method drops the words: empty again.
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(marking.composing)
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        // Unmarked with no change told: caught once the key's event is
        // handled, as the app says after each one.
        NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: NSApp)
        #expect(!editor.hasMarkedText())
        #expect(!marking.composing)
        #expect(field.stringValue.isEmpty)

        // Leaving the field mid-word ends it too.
        editor.setMarkedText("さ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(marking.composing)
        #expect(window.makeFirstResponder(next))
        #expect(!marking.composing)
    }
}
