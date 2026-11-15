import AppKit
import Testing
@testable import Fast

// A separate serialized suite could still answer QuestionKeysTests' shared question.
// Nest it under the same serialized owner so those fixtures cannot overlap.
extension QuestionKeysTests {
    @Suite(.serialized)
    struct QuitOmniboxKeysTests {
        @MainActor private func withOmnibox(
            _ run: (Browser, ContentView, NSWindow, NSTextView, NSTextField, AddressField.Coordinator) async throws -> Void
        ) async throws {
            _ = NSApplication.shared
            let id = UUID(), browser = Browser(windowID: id)
            browser.editing = true
            browser.query.offers = [
                Suggestion(key: "First", title: "First", url: URL(string: "https://example.com/first"), kind: .visited),
                Suggestion(key: "Second", title: "Second", url: URL(string: "https://example.com/second"), kind: .visited),
            ]
            browser.query.lead = nil
            browser.walk(1)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let editor = NSTextView(frame: window.contentView!.bounds)
            editor.isFieldEditor = true
            editor.string = browser.completed
            window.contentView = editor
            #expect(window.makeFirstResponder(editor))
            let field = NSTextField(string: browser.completed)
            let coordinator = AddressField.Coordinator(browser: browser)
            defer {
                Questions.shared.answer(false)
                coordinator.cancelFocus()
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            try await run(browser, ContentView(browser: browser), window, editor, field, coordinator)
        }

        @MainActor private func ask() async throws -> Task<Bool, Never> {
            let question = Question(title: "Quit Yab?", yes: "Quit", box: "Don’t ask again")
            let answer = Task { @MainActor in await Questions.shared.ask(question) }
            for _ in 0..<100 {
                if Questions.shared.current?.id == question.id { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(Questions.shared.current?.id == question.id)
            return answer
        }

        @MainActor private func press(_ code: UInt16, in window: NSWindow,
                                     flags: NSEvent.ModifierFlags = [], words: String = "") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: words, charactersIgnoringModifiers: words,
                                         isARepeat: false, keyCode: code))
        }

        @MainActor @Test(arguments: [UInt16(36), UInt16(76)])
        func returnAnswersQuitInsteadOfOpeningTheSelectedLink(_ code: UInt16) async throws {
            try await withOmnibox { browser, view, window, editor, field, coordinator in
                let answer = try await ask()
                let taken = view.take(try press(code, in: window, words: "\r"))
                // The native editor receives only keys the window's router leaves it.
                if !taken {
                    _ = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                }
                #expect(taken)
                #expect(Questions.shared.current == nil)
                #expect(browser.tabs.isEmpty)
                #expect(browser.editing)
                Questions.shared.answer(false)
                #expect(await answer.value)
            }
        }

        @MainActor @Test func escapeCancelsQuitAndReturnsToTheSameOmnibox() async throws {
            try await withOmnibox { browser, view, window, editor, field, coordinator in
                let words = browser.completed, picked = browser.query.picked
                let answer = try await ask()
                #expect(view.take(try press(53, in: window, words: "\u{1b}")))
                #expect(Questions.shared.current == nil)
                #expect(browser.editing)
                #expect(browser.completed == words)
                #expect(browser.query.picked == picked)
                #expect(window.firstResponder === editor)
                Questions.shared.answer(false)
                #expect(await answer.value == false)

                // Cancellation has already returned the next arrow to the field.
                let down = try press(125, in: window, words: "\u{f701}")
                #expect(!view.take(down))
                #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
                #expect(browser.query.picked == 1)
            }
        }

        @MainActor @Test(arguments: [UInt16(123), UInt16(124), UInt16(125), UInt16(126)])
        func arrowsCannotMoveTheMenuOrItsCaret(_ code: UInt16) async throws {
            try await withOmnibox { browser, view, window, editor, field, coordinator in
                let words = browser.completed, picked = browser.query.picked, selection = editor.selectedRange()
                let answer = try await ask()
                let question = Questions.shared.current?.id
                let taken = view.take(try press(code, in: window))
                if !taken {
                    switch code {
                    case 125: _ = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
                    case 126: _ = coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
                    case 123: editor.moveLeft(nil)
                    default: editor.moveRight(nil)
                    }
                }
                #expect(taken)
                #expect(Questions.shared.current?.id == question)
                #expect(browser.query.picked == picked)
                #expect(browser.completed == words)
                #expect(editor.selectedRange() == selection)
                Questions.shared.answer(false)
                #expect(await answer.value == false)
            }
        }

        @MainActor @Test func typingAndBrowserShortcutsStayBehindTheModal() async throws {
            try await withOmnibox { browser, view, window, _, _, _ in
                let words = browser.completed, focus = browser.focusRequest
                let answer = try await ask()
                #expect(view.take(try press(0, in: window, words: "a")))
                #expect(view.take(try press(37, in: window, flags: .command, words: "l")))
                #expect(browser.completed == words)
                #expect(browser.focusRequest == focus)
                // The app's second ⌘Q must still reach Links.applicationShouldTerminate.
                #expect(!view.take(try press(12, in: window, flags: .command, words: "q")))
                #expect(Questions.shared.current != nil)
                Questions.shared.answer(false)
                #expect(await answer.value == false)
            }
        }
    }
}
