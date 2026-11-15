import AppKit
import Testing
@testable import Fast

/// Feedback 1905: nothing pasted into Bitwarden's popup on a Chromium tab.
/// Edit commands reach the popup's view by name, never as a raw ⌘ key.
struct ChromiumPopupEditTests {
    @Test func editingKeysNameTheViewsCommand() {
        #expect(ChromiumPopupEdit.command(letter: "v", flags: .command) == .paste)
        #expect(ChromiumPopupEdit.command(letter: "v", flags: [.command, .shift, .option]) == .pasteAndMatchStyle)
        #expect(ChromiumPopupEdit.command(letter: "c", flags: .command) == .copy)
        #expect(ChromiumPopupEdit.command(letter: "x", flags: .command) == .cut)
        #expect(ChromiumPopupEdit.command(letter: "a", flags: .command) == .selectAll)
        #expect(ChromiumPopupEdit.command(letter: "z", flags: .command) == .undo)
        #expect(ChromiumPopupEdit.command(letter: "z", flags: [.command, .shift]) == .redo)
        // Caps Lock and the function key don't change what was meant.
        #expect(ChromiumPopupEdit.command(letter: "v", flags: [.command, .capsLock, .function]) == .paste)
    }

    @Test func otherKeysStayThePopupsOwn() {
        #expect(ChromiumPopupEdit.command(letter: "v", flags: []) == nil)
        #expect(ChromiumPopupEdit.command(letter: "v", flags: .control) == nil)
        #expect(ChromiumPopupEdit.command(letter: "v", flags: [.command, .shift]) == nil)
        #expect(ChromiumPopupEdit.command(letter: "k", flags: .command) == nil)
        #expect(ChromiumPopupEdit.command(letter: "f", flags: .command) == nil)
    }

    /// The names are the selectors YabCore sends to Chrome's popup view.
    @Test func commandsAreTheViewsActionNames() {
        #expect(ChromiumPopupEdit.allCases.map(\.rawValue).sorted() ==
                ["copy", "cut", "paste", "pasteAndMatchStyle", "redo", "selectAll", "undo"])
    }
}
