import AppKit
import SwiftUI
import Testing
@testable import Fast

/// The same Return route the chat's SwiftUI key callback uses, with real
/// AppKit marked text and synthetic send/newline/choice callbacks. No task,
/// provider, clipboard, real account or OS input-source change is involved.
@MainActor
@Suite(.serialized)
struct ChatReturnCommitTests {
    init() throws {
        try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private func withEditor(_ body: (NSWindow, NSTextView) throws -> Void) rethrows {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 360, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        window.contentView = editor
        window.makeFirstResponder(editor)
        defer { window.makeFirstResponder(nil); window.close() }
        try body(window, editor)
    }

    private func event(_ window: NSWindow, code: UInt16 = 36, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: code))
    }

    private func mark(_ value: String, in editor: NSTextView) {
        editor.setMarkedText(value, selectedRange: NSRange(location: (value as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func inputContextCommitBeforeTheChatCallbackCannotSubmitTheSameReturn(code: UInt16) throws {
        try withEditor { window, editor in
            let route = ChatReturn(), key = try event(window, code: code)
            mark("zhongwen", in: editor)
            try #require(InputMethod.composing(editor))
            // The field-local monitor runs before AppKit handles the key.
            route.hear(key, in: editor)
            // An input context can commit before forwarding its command.
            editor.insertText("zhongwen", replacementRange: editor.markedRange())
            try #require(!editor.hasMarkedText())
            var sends = 0, newlines = 0, picks = 0
            #expect(!route.run(key, in: editor, modifiers: [], newline: { newlines += 1 },
                               pick: { picks += 1; return true }, send: { _ in sends += 1 }))
            #expect(sends == 0 && newlines == 0 && picks == 0)
            #expect(editor.string == "zhongwen")
        }
    }

    @Test func theFollowingReturnSubmitsAndAnAlreadyCommittedCandidateIsNotSwallowed() throws {
        try withEditor { window, editor in
            let route = ChatReturn(), commit = try event(window)
            mark("nihao", in: editor)
            route.hear(commit, in: editor)
            editor.insertText("你好", replacementRange: editor.markedRange())
            var sends: [Bool] = []
            #expect(!route.run(commit, in: editor, modifiers: [], newline: {}, pick: { false }, send: { sends.append($0) }))

            let next = try event(window)
            route.hear(next, in: editor)
            #expect(route.run(next, in: editor, modifiers: [], newline: {}, pick: { false }, send: { sends.append($0) }))
            #expect(sends == [false])
            #expect(editor.string == "你好")

            // A candidate committed by an earlier, different event never
            // leaves a latch that swallows the next intentional Return.
            mark("shijie", in: editor)
            editor.insertText("世界", replacementRange: editor.markedRange())
            let alreadyCommitted = try event(window)
            route.hear(alreadyCommitted, in: editor)
            #expect(route.run(alreadyCommitted, in: editor, modifiers: .command,
                              newline: {}, pick: { false }, send: { sends.append($0) }))
            #expect(sends == [false, true])
        }
    }

    @Test func markedTextStillPresentCannotSendPickOrInsertANewline() throws {
        try withEditor { window, editor in
            let route = ChatReturn()
            mark("pinyin", in: editor)
            let combinations: [EventModifiers] = [[], .command, .shift, .option]
            for modifiers in combinations {
                let key = try event(window)
                route.hear(key, in: editor)
                var changes = 0
                #expect(!route.run(key, in: editor, modifiers: modifiers, newline: { changes += 1 },
                                   pick: { changes += 1; return true }, send: { _ in changes += 1 }))
                #expect(changes == 0)
                #expect(editor.hasMarkedText())
            }
        }
    }

    @Test func eventAndClientOwnershipDoNotLeaveAStickyCompositionFlag() throws {
        try withEditor { window, editor in
            let route = ChatReturn(), commit = try event(window)
            mark("abc", in: editor)
            route.hear(commit, in: editor)
            editor.insertText("abc", replacementRange: editor.markedRange())
            let other = NSTextView()
            var sends = 0
            #expect(route.run(commit, in: other, modifiers: [], newline: {}, pick: { false }, send: { _ in sends += 1 }))
            let next = try event(window)
            #expect(route.run(next, in: editor, modifiers: [], newline: {}, pick: { false }, send: { _ in sends += 1 }))
            route.clear() // The composer disappearing removes the monitor.
            #expect(route.run(commit, in: editor, modifiers: [], newline: {}, pick: { false }, send: { _ in sends += 1 }))
            #expect(sends == 3)
        }
    }

    @Test func existingNewlineChoiceAndQueueRoutingIsPreserved() throws {
        try withEditor { window, editor in
            let route = ChatReturn(), key = try event(window)
            route.hear(key, in: editor)
            var newlines = 0, picks = 0, sends: [Bool] = []
            let combinations: [EventModifiers] = [.shift, .option, [.command, .shift]]
            for modifiers in combinations {
                #expect(route.run(key, in: editor, modifiers: modifiers, newline: { newlines += 1 },
                                  pick: { picks += 1; return true }, send: { sends.append($0) }))
            }
            #expect(newlines == 3 && picks == 0 && sends.isEmpty)
            #expect(route.run(key, in: editor, modifiers: [], newline: {},
                              pick: { picks += 1; return true }, send: { sends.append($0) }))
            #expect(picks == 1 && sends.isEmpty)
            #expect(route.run(key, in: editor, modifiers: [], newline: {}, pick: { false }, send: { sends.append($0) }))
            #expect(route.run(key, in: editor, modifiers: .command, newline: {},
                              pick: { picks += 1; return true }, send: { sends.append($0) }))
            #expect(sends == [false, true] && picks == 1)
        }
    }
}
