import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct CommandHotkeyTests {
    private func withKeys(_ body: (Keymap) throws -> Void) rethrows {
        _ = NSApplication.shared
        let saved = Store.settings.object(forKey: "shortcuts")
        let keymap = Keymap.shared
        defer {
            if let saved { Store.settings.set(saved, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            keymap.adoptStored()
            keymap.take(system: Hotkeys.userKeys())
        }
        Store.settings.set([String: String](), forKey: "shortcuts")
        keymap.adoptStored()
        keymap.take(system: [:])
        try body(keymap)
    }

    @Test func everyCommandHasExactlyOneShortcutRow() {
        for command in Command.allCases {
            if MenuCommands.entries[command] != nil, !MenuCommands.everyone.contains(command.shortcutCommand) {
                #expect(!CommandHotkeys.commands.contains(command.shortcutCommand), "\(command)")
            } else if let action = command.shortcutAction {
                #expect(Shortcut.items.filter { $0.action == action }.count == 1, "\(command)")
            } else {
                #expect(CommandHotkeys.commands.filter { $0 == command.shortcutCommand }.count == 1, "\(command)")
            }
        }
        #expect(Command.muteTab.shortcutAction == Command.unmuteTab.shortcutAction)
        #expect(Command.keepTab.shortcutAction == Command.releaseTab.shortcutAction)
        #expect(Command.showChat.shortcutAction == Command.hideChat.shortcutAction)
        #expect(Command.customizationOn.shortcutID == Command.customizationOff.shortcutID)
        #expect(Command.muteSite.shortcutID == Command.unmuteSite.shortcutID)
        #expect(CommandHotkeys.commands.contains(.tidyTabs))
        #expect(CommandHotkeys.commands.allSatisfy { $0 == .tidyTabs || $0.defaultHotkey == nil })
    }

    @Test func savesLoadsRemovesResetsAndShowsKeys() throws {
        try withKeys { keymap in
            let command = Command.clearCookies
            let key = Hotkey("k", [.control, .option, .command])
            #expect(keymap.clash(key, forCommand: command) == nil)
            let version = Hotkeys.shared.version
            keymap.set(key, forCommand: command)
            #expect(Hotkeys.shared.version > version)
            let saved = try #require(Store.settings.dictionary(forKey: "shortcuts") as? [String: String])
            #expect(saved[command.shortcutID] == key.stored)
            #expect(Keymap.resolveAll(chosen: saved).commands[command] == key)
            Store.settings.set([String: String](), forKey: "shortcuts")
            keymap.adoptStored()
            #expect(keymap.keys(for: command) == nil)
            Store.settings.set(saved, forKey: "shortcuts")
            keymap.adoptStored()
            #expect(keymap.keys(for: command) == key)
            #expect(command.keys == key.text)
            #expect(keymap.slot(for: command).keys == key)
            let entries = ShortcutFilter.catalog(groups: Shortcut.all, snippets: [])
            #expect(ShortcutFilter.visible(entries, search: command.title).contains { $0.id == command.shortcutID })
            #expect(keymap.index.contains { $0.id == "key:" + command.shortcutID })
            #expect(ShortcutFilter.visible(entries, search: "tidy").contains { $0.id == Command.tidyTabs.shortcutID })
            #expect(keymap.index.contains { $0.id == "key:" + Command.tidyTabs.shortcutID && $0.words.contains("tidy") })
            keymap.set(nil, forCommand: command)
            #expect(command.keys.isEmpty)
            #expect(keymap.isDefault(command: command))
            keymap.reset(command: command)
            #expect(keymap.isDefault(command: command))
            #expect(keymap.keys(for: .tidyTabs) == Hotkey("t", [.control, .command]))
        }
    }

    @Test func commandAndActionConflictsWorkInBothDirections() throws {
        try withKeys { keymap in
            let key = try #require(keymap.keys(.newTab))
            guard case .taken(let words, let free) = keymap.clash(key, forCommand: Command.clearCookies) else {
                Issue.record("A command must disclose the action it replaces")
                return
            }
            #expect(words.contains("New tab"))
            free()
            keymap.set(key, forCommand: Command.clearCookies)
            #expect(keymap.keys(.newTab) == nil)
            #expect(keymap.keys(for: .clearCookies) == key)
            guard case .taken(let words, let free) = keymap.clash(key, for: Shortcut.Action.newTab) else {
                Issue.record("An action must disclose the command it replaces")
                return
            }
            #expect(words.contains(Command.clearCookies.title))
            free()
            keymap.set(key, for: Shortcut.Action.newTab)
            #expect(keymap.keys(for: .clearCookies) == nil)
            #expect(keymap.keys(.newTab) == key)
            #expect(keymap.clash(Hotkey("q", .command), forCommand: Command.clearCookies) != nil)
            #expect(keymap.clash(Hotkey("a", []), forCommand: Command.clearCookies) != nil)
        }
    }

    @Test func anotherReadingCannotStealAnExistingAction() throws {
        try withKeys { keymap in
            let commandKey = Hotkey("k", [.control, .option, .command])
            let actionKey = try #require(keymap.keys(.newTab))
            keymap.set(commandKey, forCommand: Command.clearCookies)
            #expect(keymap.command(for: [actionKey, commandKey]) == nil)
            #expect(keymap.command(for: [commandKey, actionKey]) == .clearCookies)
        }
    }

    @Test func defaultsDoNotDisplaceActionOrSystemChoices() throws {
        try withKeys { keymap in
            let tidy = try #require(Command.tidyTabs.defaultHotkey)
            #expect(keymap.clash(tidy, forCommand: Command.tidyTabs) == nil)
            keymap.set(tidy, for: Shortcut.Action.newTab)
            #expect(keymap.keys(for: .tidyTabs) == nil)
            keymap.reset(command: Command.tidyTabs)
            #expect(keymap.keys(for: .tidyTabs) == tidy)
            #expect(keymap.keys(.newTab) == Shortcut.byAction[.newTab]?.key)
            keymap.take(system: ["New Tab": "@^t"])
            #expect(keymap.keys(for: .tidyTabs) == nil)
            guard case .refused = keymap.clash(tidy, forCommand: Command.tidyTabs) else {
                Issue.record("A command cannot overwrite a macOS App Shortcut")
                return
            }
        }
    }

    @Test func keyDispatchUsesTheAvailableToggleStateAndFallsThroughOtherwise() throws {
        try withKeys { keymap in
            let browser = Browser(windowID: UUID())
            let look = browser.prefs.look
            defer {
                browser.prefs.look = look
                browser.dismiss(); browser.letGo()
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
            }
            let key = Hotkey("u", [.control, .option, .command])
            keymap.set(key, forCommand: Command.lightTheme)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "u", charactersIgnoringModifiers: "u",
                isARepeat: false, keyCode: 32))
            #expect(keymap.command(for: event) == .lightTheme)
            browser.prefs.look = .dark
            let view = ContentView(browser: browser)
            browser.editing = true
            browser.typed = "light mode"
            #expect(view.take(event))
            #expect(!browser.editing && browser.typed.isEmpty)
            #expect(browser.prefs.look == .light)
            // One key for both: pressed again it goes back.
            #expect(view.take(event))
            #expect(browser.prefs.look == .dark)
            #expect(Command.darkTheme.shortcutID == Command.lightTheme.shortcutID)
            #expect(!CommandHotkeys.commands.contains(.darkTheme))
            #expect(Command.darkTheme.shortcutTitle == "Toggle Light and Dark Mode")
            #expect(!Command.tidyTabs.available(in: browser))
            #expect(!keymap.run(.tidyTabs, in: browser))
            keymap.set(key, forCommand: Command.clearCookies)
            #expect(!view.take(event))
            #expect(!keymap.run(.clearCookies, in: browser))
        }
    }
}
