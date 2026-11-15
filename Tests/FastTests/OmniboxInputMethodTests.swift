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

    /// #1519: Edit › Copy, the field's menu and a drag write the selection
    /// through the editor, and took the shortened "example.com/page" ⌘L
    /// shows, without its https://. Only ⌘C, in the window's key monitor,
    /// put the scheme back.
    @Test func copyingTheUntouchedAddressKeepsItsScheme() throws {
        try withField { browser, _, field, editor in
            let url = try #require(URL(string: "https://www.example.com/page?q=1#top"))
            let tab = Tab()
            tab.restore(url: url, title: "Copy")
            browser.lay([tab])
            browser.activeID = tab.id
            browser.query.here = url
            browser.query.typed = Address.whole(url)
            field.stringValue = browser.typed
            editor.string = browser.typed
            let board = NSPasteboard(name: NSPasteboard.Name("yab-copy-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            func copied(_ range: NSRange) -> String? {
                editor.setSelectedRange(range)
                board.clearContents()
                _ = editor.writeSelection(to: board, types: [.string])
                return board.string(forType: .string)
            }
            let shown = editor.string as NSString
            #expect(shown == "www.example.com/page?q=1#top")
            #expect(copied(NSRange(location: 0, length: shown.length)) == "https://www.example.com/page?q=1#top")
            // A start of it, copied as Chromium copies one: the scheme put back.
            #expect(copied(NSRange(location: 0, length: 15)) == "https://www.example.com")
            // Words from its middle are AppKit's to copy, as they are.
            #expect(AddressEditor.copied(editor.string, NSRange(location: 4, length: 7), here: browser.untouched) == nil)
            // Typed over, the address is no longer the page's.
            browser.query.typed = "example.com/other"
            editor.string = browser.typed
            #expect(browser.untouched == nil)
            #expect(AddressEditor.copied(editor.string, NSRange(location: 0, length: (editor.string as NSString).length),
                                         here: url) == nil)
        }
        let here = URL(string: "http://localhost:3000/app")!
        #expect(AddressEditor.copied("localhost:3000/app", NSRange(location: 0, length: 18), here: here) == "http://localhost:3000/app")
        #expect(AddressEditor.copied("about:blank", NSRange(location: 0, length: 6), here: URL(string: "about:blank")!) == nil)
        #expect(AddressEditor.copied("localhost:3000/app", NSRange(location: 0, length: 18), here: nil) == nil)
    }
}
