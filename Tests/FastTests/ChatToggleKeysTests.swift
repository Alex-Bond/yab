import AppKit
import Testing
@testable import Fast

// Share the modal fixture's serialized owner; this tests the real window
// key router without showing a window or starting an agent.
extension QuestionKeysTests {
    @MainActor @Suite(.serialized)
    struct ChatToggleKeysTests {
        private func press(_ code: UInt16 = 53, flags: NSEvent.ModifierFlags = .shift,
                           words: String = "\u{1b}", repeated: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: words, charactersIgnoringModifiers: words,
                                         isARepeat: repeated, keyCode: code))
        }

        private func withKeys(_ run: (Browser, ContentView, Keymap) async throws -> Void) async throws {
            _ = NSApplication.shared
            let map = Keymap.shared, saved = map.chosen[Shortcut.Action.closeChat.rawValue]
            let system = Hotkeys.userKeys(), browser = Browser(windowID: UUID())
            // Show Chat waits for an agent; a Mac without one isn't the test.
            Agents.assumedInTests = true
            map.take(system: [:])
            map.reset(.closeChat)
            browser.chatOpen = false
            defer {
                Agents.assumedInTests = nil
                if let saved { map.set(Hotkey(stored: saved), for: .closeChat) }
                else { map.reset(.closeChat) }
                map.take(system: system)
                browser.tabs.forEach { $0.close() }
            }
            try await run(browser, ContentView(browser: browser), map)
        }

        @Test func shiftEscapeOpensClosesAndReopensChat() async throws {
            try await withKeys { browser, view, _ in
                for open in [true, false, true] {
                    #expect(view.take(try press()))
                    try await Task.sleep(for: .milliseconds(60))
                    #expect(browser.chatOpen == open)
                }
                #expect(view.take(try press(repeated: true)))
                #expect(browser.chatOpen, "holding the key does not repeatedly toggle")
                #expect(view.take(try press()))
                #expect(view.take(try press()))
                try await Task.sleep(for: .milliseconds(60))
                #expect(browser.chatOpen, "a rapid second press cancels the queued close")
            }
        }

        @Test func chosenKeyKeepsItsAssignmentAndOrdinaryTypingDoesNotToggle() async throws {
            try await withKeys { browser, view, map in
                let ask = map.keys(.agentAsk)
                map.set(Hotkey("h", [.control, .option, .command]), for: .closeChat)
                #expect(!map.matches(try press(), .closeChat))
                #expect(!view.take(try press(0, flags: [], words: "a")))
                #expect(!browser.chatOpen)
                #expect(view.take(try press(4, flags: [.control, .option, .command], words: "h")))
                try await Task.sleep(for: .milliseconds(60))
                #expect(browser.chatOpen)
                _ = view.take(try press(flags: []))
                #expect(browser.chatOpen, "plain Escape keeps its existing page/field behavior")
                #expect(map.keys(.agentAsk) == ask)
            }
        }

        // Register 1130: ⌘J again from the field it put the keys in takes
        // the column away; from anywhere else it asks as before.
        @Test func askKeyAgainFromTheChatFieldClosesTheColumn() async throws {
            try await withKeys { browser, view, map in
                let saved = map.chosen[Shortcut.Action.agentAsk.rawValue]
                map.reset(.agentAsk)
                defer {
                    if let saved { map.set(Hotkey(stored: saved), for: .agentAsk) } else { map.reset(.agentAsk) }
                    browser.chatAttach.typing = false
                }
                let ask = try press(38, flags: .command, words: "j")
                #expect(map.matches(ask, .agentAsk))
                #expect(view.take(try press()))
                // Out and arrived: while it is still coming out ⌘J takes it back.
                try await Task.sleep(for: .milliseconds(1600))
                #expect(browser.chatOpen && !browser.chatMoving)
                browser.chatAttach.typing = false
                _ = view.take(ask)
                try await Task.sleep(for: .milliseconds(60))
                #expect(browser.chatOpen, "keys elsewhere: ⌘J is still the ask")
                browser.chatAttach.typing = true
                #expect(view.take(ask))
                try await Task.sleep(for: .milliseconds(60))
                #expect(!browser.chatOpen)
                browser.chatAttach.typing = false
                #expect(!browser.askClosesChat, "a closed column is never closed again by ⌘J")
            }
        }

        @Test func pageModalKeepsShiftEscapeAheadOfChat() async throws {
            try await withKeys { browser, view, _ in
                let question = Question(title: "Continue?", yes: "Continue")
                let answer = Task { @MainActor in await Questions.shared.ask(question) }
                for _ in 0..<100 {
                    if Questions.shared.current?.id == question.id { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                defer { Questions.shared.answer(false) }
                #expect(Questions.shared.current?.id == question.id)
                _ = view.take(try press())
                #expect(!browser.chatOpen && !browser.chatMoving)
                Questions.shared.answer(false)
                #expect(await answer.value == false)
            }
        }
    }
}
