import AppKit
import Testing
@testable import Fast

/// Feedback 803: a Return which finishes Pinyin must not also open a search.
/// These use the product's own field cell/editor and its real AppKit delegate.
@MainActor @Suite(.serialized)
struct OmniboxInputMethodTests {
    private func withField(_ body: (Browser, NSWindow, AddressTextField, AddressEditor) throws -> Void) throws {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        browser.editing = true
        browser.prefs.searchSuggest = false
        let coordinator = AddressField.Coordinator(browser: browser)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let field = AddressTextField(frame: NSRect(x: 10, y: 10, width: 350, height: 24))
        field.delegate = coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? AddressEditor)
        defer {
            coordinator.cancelFocus()
            window.makeFirstResponder(nil)
            window.close()
            for tab in browser.tabs { tab.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        try body(browser, window, field, editor)
        withExtendedLifetime(coordinator) {}
    }

    private func mark(_ words: String, in editor: AddressEditor) {
        editor.setMarkedText(words, selectedRange: NSRange(location: (words as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func returnCommandCommitsRawPinyinAndKeepsTheFieldOpen() throws {
        try withField { browser, window, field, editor in
            mark("zhongwen", in: editor)
            #expect(editor.hasMarkedText())
            browser.query.offers = [Suggestion(key: "zhongwen", title: "Pinyin", url: URL(string: "about:blank"), kind: .address)]
            browser.query.lead = 0
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(!editor.hasMarkedText())
            #expect(editor.string == "zhongwen")
            #expect(field.stringValue == "zhongwen")
            let typed = browser.typed, editing = browser.editing, tabs = browser.tabs.count
            #expect(typed == "zhongwen")
            #expect(editing)
            #expect(tabs == 0)
            #expect(window.firstResponder === editor)
        }
    }

    @Test func returnKeyCommitsOnceThenTheNextReturnSubmits() throws {
        try withField { browser, window, field, editor in
            mark("pinyin", in: editor)
            browser.query.offers = [Suggestion(key: "pinyin", title: "Pinyin", url: URL(string: "about:blank"), kind: .address)]
            browser.query.lead = 0
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            editor.keyDown(with: event)
            #expect(!editor.hasMarkedText())
            #expect(editor.string == "pinyin")
            #expect(field.stringValue == "pinyin")
            #expect(browser.editing)
            #expect(browser.tabs.isEmpty)
            // Pick a deterministic local address; no remote site or account.
            browser.query.offers = [Suggestion(key: "pinyin", title: "Pinyin", url: URL(string: "about:blank"), kind: .address)]
            browser.query.lead = 0
            editor.keyDown(with: event)
            #expect(browser.tabs.count == 1)
            #expect(!browser.editing)
        }
    }

    @Test func previouslyCommittedCandidateDoesNotSwallowTheNextReturn() throws {
        try withField { browser, _, _, editor in
            mark("nihao", in: editor)
            editor.insertText("你好", replacementRange: editor.markedRange())
            #expect(!editor.hasMarkedText())
            browser.query.offers = [Suggestion(key: "你好", title: "Hello", url: URL(string: "about:blank"), kind: .address)]
            browser.query.lead = 0
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(browser.tabs.count == 1)
            #expect(!browser.editing)
        }
    }
}
