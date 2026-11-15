import AppKit
import SwiftUI
import Testing
@testable import Fast

/// 0.0.9: ⌘Z raised "-[NSView _undoRedoTextOperation:]: unrecognized
/// selector". AppKit filed a reply's keys in the window's undo, against the
/// words' text storage, and left them there when the reply went: hours
/// later ⌘Z on a page undid them on freed memory. The words keep their own
/// undo, which goes with them, and ⌘Z in them still undoes what was typed.
@Suite(.serialized)
@MainActor
struct MailWordsUndoTests {
    final class Gone {
        weak var words: NSTextView?
    }

    @Test func aRepliesKeysGoWithIt() async throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let gone = try await write(in: window)
        // The reply put away: nothing of it is left in the window's undo.
        for _ in 0..<50 where gone.words != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gone.words == nil)
        #expect(window.undoManager?.canUndo != true)
    }

    /// A reply's words in the window, typed in, ⌘Z'd, typed in again and
    /// taken out of the window, as a reply sent or closed is.
    private func write(in window: NSWindow) async throws -> Gone {
        let gone = Gone()
        let host = NSHostingView(rootView: MailWords(body: "", html: "", focus: 0, toFirst: true, live: false)
            .frame(width: 300, height: 100))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(host)
        var found: MailWordsView?
        func walk(_ view: NSView) {
            if let words = view as? MailWordsView { found = words }
            view.subviews.forEach(walk)
        }
        // SwiftUI puts the words in after the hosting view's first turn.
        for _ in 0..<100 where found == nil {
            host.layoutSubtreeIfNeeded()
            walk(host)
            if found == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let words = try #require(found)
        gone.words = words
        #expect(window.makeFirstResponder(words))
        #expect(words.undoManager != nil)
        #expect(words.undoManager !== window.undoManager)

        words.insertText("typed", replacementRange: words.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        #expect(words.string == "typed")
        #expect(words.undoManager?.canUndo == true)
        #expect(window.undoManager?.canUndo != true)

        // ⌘Z as the Edit menu sends it, up the chain from the words.
        let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        #expect(words.tryToPerform(Selector(("undo:")), with: item))
        #expect(words.string == "")

        words.insertText("again", replacementRange: words.selectedRange())
        try await Task.sleep(for: .milliseconds(50))
        #expect(words.string == "again")
        _ = window.makeFirstResponder(nil)
        host.removeFromSuperview()
        return gone
    }
}
