import AppKit
import Testing
@testable import Fast

// Owns Questions.shared for every keyboard fixture, including nested QuitOmniboxKeysTests.
@Suite(.serialized)
struct QuestionKeysTests {
    @MainActor private func withMail(_ run: (ContentView, NSWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let id = UUID(), browser = Browser(windowID: id)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        tab.restore(url: MailPage.url, title: "Mail")
        browser.spaceID = Space.mailID
        browser.editing = false
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let previousBrowser = MailDesk.shared.browser
        defer {
            Questions.shared.answer(false)
            MailDesk.shared.browser = previousBrowser
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        try await run(ContentView(browser: browser), window)
    }

    @MainActor private func ask(_ question: Question) async throws -> Task<Bool, Never> {
        let answer = Task { @MainActor in await Questions.shared.ask(question) }
        for _ in 0..<100 {
            if Questions.shared.current?.id == question.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Questions.shared.current?.id == question.id)
        return answer
    }

    @MainActor private func press(_ code: UInt16, in window: NSWindow,
                                flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: code == 53 ? "\u{1b}" : "\r",
                                     charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
                                     isARepeat: false, keyCode: code))
    }

    @MainActor @Test(arguments: [UInt16(36), UInt16(76)])
    func dialogConfirmsBeforeMailOpensARow(_ code: UInt16) async throws {
        try await withMail { view, window in
            let answer = try await ask(Question(title: "Continue?", yes: "Continue"))
            #expect(view.take(try press(code, in: window)))
            #expect(Questions.shared.current == nil)
            // Clean up a missed key without leaving a continuation waiting.
            Questions.shared.answer(false)
            #expect(await answer.value)
        }
    }

    @MainActor @Test func dangerousDialogKeepsBareReturnThenConfirms() async throws {
        try await withMail { view, window in
            let question = Question(title: "Remove?", yes: "Remove", danger: true)
            let answer = try await ask(question)
            #expect(view.take(try press(36, in: window)))
            #expect(Questions.shared.current?.id == question.id)
            #expect(view.take(try press(36, in: window, flags: .command)))
            #expect(Questions.shared.current == nil)
            Questions.shared.answer(false)
            #expect(await answer.value)
        }
    }

    @MainActor @Test(arguments: [UInt16(36), UInt16(53)])
    func modalDialogKeepsKeysFromTheUnderlyingEditor(_ code: UInt16) async throws {
        try await withMail { view, window in
            let editor = MailWordsView.make()
            window.contentView = editor
            #expect(window.makeFirstResponder(editor))
            let answer = try await ask(Question(title: "Continue?", yes: "Continue"))
            #expect(view.take(try press(code, in: window)))
            #expect(Questions.shared.current == nil)
            Questions.shared.answer(false)
            #expect(await answer.value == (code == 36))
            #expect(window.firstResponder === editor)
        }
    }

    @MainActor @Test(arguments: [UInt16(36), UInt16(53)])
    func dialogFieldKeepsItsKeysFromMail(_ code: UInt16) async throws {
        try await withMail { view, window in
            let editor = NSTextView(frame: window.contentView!.bounds)
            window.contentView = editor
            #expect(window.makeFirstResponder(editor))
            let question = Question(title: "Name", yes: "Save", field: Question.Field("", prompt: "Name"))
            let answer = try await ask(question)
            #expect(!view.take(try press(code, in: window)))
            #expect(Questions.shared.current?.id == question.id)
            Questions.shared.answer(false)
            #expect(await answer.value == false)
        }
    }

    @MainActor @Test func undimmedQuestionLeavesTypingKeysInTheEditor() async throws {
        try await withMail { _, window in
            let editor = NSTextView(frame: window.contentView!.bounds)
            window.contentView = editor
            #expect(window.makeFirstResponder(editor))
            let question = Question(title: "Continue?", yes: "Continue", place: .plain)
            let answer = try await ask(question)
            #expect(!Questions.shared.key(try press(36, in: window), typing: true))
            #expect(Questions.shared.current?.id == question.id)
            Questions.shared.answer(false)
            #expect(await answer.value == false)
        }
    }

    @MainActor @Test(arguments: [UInt16(36), UInt16(76), UInt16(53)])
    func passwordImportButtonsAnswerTheirAdvertisedKeys(_ code: UInt16) async throws {
        try await withMail { view, window in
            let question = PasswordsToApple.question(count: 1164)
            #expect(question.place == .plain)
            #expect(question.yes == "Import")
            #expect(question.no == "Not Now")
            #expect(!question.danger)
            let answer = try await ask(question)
            #expect(view.take(try press(code, in: window)))
            #expect(Questions.shared.current == nil)
            Questions.shared.answer(false)
            #expect(await answer.value == (code != 53))
        }
    }

    @MainActor @Test(arguments: [UInt16(36), UInt16(53)])
    func passwordImportKeepsModifiedKeysForThePage(_ code: UInt16) async throws {
        try await withMail { _, window in
            let question = PasswordsToApple.question(count: 1)
            let answer = try await ask(question)
            #expect(!Questions.shared.key(try press(code, in: window, flags: .option)))
            #expect(Questions.shared.current?.id == question.id)
            Questions.shared.answer(false)
            #expect(await answer.value == false)
        }
    }

    @MainActor @Test func emptyDialogFieldKeepsReturnBeforeItGetsFocus() async throws {
        try await withMail { view, window in
            let field = Question.Field("   ", prompt: "Name")
            let question = Question(title: "Name", yes: "Save", field: field)
            let answer = try await ask(question)
            #expect(view.take(try press(36, in: window)))
            #expect(Questions.shared.current?.id == question.id)
            field.text = "New name"
            #expect(view.take(try press(36, in: window)))
            #expect(Questions.shared.current == nil)
            Questions.shared.answer(false)
            #expect(await answer.value)
        }
    }

    @MainActor @Test func undimmedDialogLeavesOtherTextFieldsTheirKeys() async throws {
        try await withMail { _, window in
            let editor = NSTextView(frame: window.contentView!.bounds)
            editor.isFieldEditor = true
            window.contentView = editor
            #expect(window.makeFirstResponder(editor))
            let question = Question(title: "Continue?", yes: "Continue", place: .plain)
            let answer = try await ask(question)
            #expect(!Questions.shared.key(try press(36, in: window)))
            #expect(Questions.shared.current?.id == question.id)
            Questions.shared.answer(false)
            #expect(await answer.value == false)
        }
    }
}
