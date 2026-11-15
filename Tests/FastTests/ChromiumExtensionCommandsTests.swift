import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// Register 2343: extensions' keyboard shortcuts in Chromium tabs, with the
/// keys Chrome keeps for them (ChromiumExtensionCommands).
@MainActor
@Suite(.serialized)
struct ChromiumExtensionCommandsTests {
    private nonisolated static let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    private func item(_ commands: [[String: JSONValue]], id: String = id, state: String = "ENABLED") throws -> ChromiumExtensions.Item {
        try ChromiumExtensions.Item(.object(["id": .string(id), "name": .string("1Password"), "state": .string(state),
                                             "commands": .array(commands.map(JSONValue.object))]))
    }

    @Test func storedKeysReadAsAMacHasThem() {
        // Command is ⌘ and Ctrl is ⌃ in Chrome's stored form, unlike a manifest's.
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+Shift+X") == Hotkey("x", [.command, .shift]))
        #expect(ChromiumExtensionCommands.hotkey(stored: "Ctrl+Alt+Comma") == Hotkey(",", [.control, .option]))
        #expect(ChromiumExtensionCommands.hotkey(stored: "Alt+Shift+R") == Hotkey("r", [.option, .shift]))
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+Shift+9") == Hotkey("9", [.command, .shift]))
        // The names a press reads (KeyLayout.named).
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+Up") == Hotkey("↑", .command))
        #expect(ChromiumExtensionCommands.hotkey(stored: "Alt+Space") == Hotkey("space", .option))
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+Shift+Tab") == Hotkey("⇥", [.command, .shift]))
        // Nothing a Mac presses, or no modifier but Shift.
        #expect(ChromiumExtensionCommands.hotkey(stored: "Shift+X") == nil)
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+Insert") == nil)
        #expect(ChromiumExtensionCommands.hotkey(stored: "MediaPlayPause") == nil)
        #expect(ChromiumExtensionCommands.hotkey(stored: "Command+X+Y") == nil)
        #expect(ChromiumExtensionCommands.hotkey(stored: "") == nil)
    }

    @Test func keysWrittenAsTheShortcutsPageWritesThem() {
        #expect(ChromiumExtensionCommands.stored(Hotkey("x", [.command, .shift])) == "Command+Shift+X")
        #expect(ChromiumExtensionCommands.stored(Hotkey("k", [.shift, .option, .control, .command])) == "Command+Ctrl+Alt+Shift+K")
        #expect(ChromiumExtensionCommands.stored(Hotkey(".", .command)) == "Command+Period")
        #expect(ChromiumExtensionCommands.stored(Hotkey("→", .option)) == "Alt+Right")
        // Keys Chrome gives no command.
        #expect(ChromiumExtensionCommands.stored(Hotkey("f5", .command)) == nil)
        #expect(ChromiumExtensionCommands.stored(Hotkey("[", .command)) == nil)
        #expect(ChromiumExtensionCommands.stored(Hotkey("x", .shift)) == nil)
        for combo in ["Command+Shift+X", "Ctrl+Alt+Comma", "Alt+Shift+R", "Command+Down", "Ctrl+Space"] {
            #expect(ChromiumExtensionCommands.stored(ChromiumExtensionCommands.hotkey(stored: combo)!).flatMap {
                ChromiumExtensionCommands.hotkey(stored: $0)
            } == ChromiumExtensionCommands.hotkey(stored: combo))
        }
    }

    @Test func listRowsCarryCommandsAndChromesKeys() throws {
        let row = try item([
            ["name": .string("_execute_action"), "description": .string("Activate the extension"),
             "shortcut": .string("Command+Shift+X"), "active": .bool(true), "action": .bool(true)],
            ["name": .string("lock"), "description": .string("Lock 1Password"), "shortcut": .string(""), "global": .bool(false)],
            ["name": .string("_execute_side_panel"), "shortcut": .string("Alt+Shift+P")],
            ["description": .string("no name")],
        ])
        #expect(row.commands.map(\.name) == ["_execute_action", "lock", "_execute_side_panel"])
        #expect(row.commands[0].action && row.commands[0].hotkey == Hotkey("x", [.command, .shift]))
        #expect(!row.commands[1].action && row.commands[1].hotkey == nil && row.commands[1].description == "Lock 1Password")
        // Chrome 156 has no special side panel command: a named one.
        #expect(!row.commands[2].action && row.commands[2].hotkey == Hotkey("p", [.option, .shift]))
        // A row without commands, as an older helper lists it.
        let bare = try ChromiumExtensions.Item(.object(["id": .string(Self.id), "name": .string("x"), "state": .string("ENABLED")]))
        #expect(bare.commands.isEmpty)
    }

    @Test func aPressFindsTheCommandChromeGaveItsKey() throws {
        try #require(Store.testing)
        let saved = Store.settings.object(forKey: ExtensionCommands.key(Self.id))
        defer { Store.settings.set(saved, forKey: ExtensionCommands.key(Self.id)) }
        Store.settings.removeObject(forKey: ExtensionCommands.key(Self.id))
        let rows = [try item([
            ["name": .string("_execute_action"), "shortcut": .string("Command+Shift+X"), "action": .bool(true)],
            ["name": .string("lock"), "shortcut": .string("Alt+Shift+L")],
            // A key Yab's own New Tab has: Yab's, never the extension's.
            ["name": .string("grab"), "shortcut": .string("Command+T")],
        ])]
        let owner = { (keys: [Hotkey], rows: [ChromiumExtensions.Item]) in
            ChromiumExtensionCommands.owner(of: keys, in: rows, pageHasKeys: true)
        }
        #expect(owner([Hotkey("x", [.command, .shift])], rows).map { $0.id + "/" + $0.command } == Self.id + "/_execute_action")
        #expect(owner([Hotkey("t", .command)], rows) == nil)
        #expect(owner([Hotkey("y", [.command, .shift])], rows) == nil)
        // A named command's key is Chrome's own registry's while the page has
        // the keyboard: Yab leaves it, so it never runs twice.
        #expect(owner([Hotkey("l", [.option, .shift])], rows) == nil)
        // In Yab's field the page doesn't hear it: Yab runs it, through a
        // helper with Chrome's entry (patch 0116), or not at all.
        let away = ChromiumExtensionCommands.owner(of: [Hotkey("l", [.option, .shift])], in: rows, pageHasKeys: false)
        #expect((away != nil) == ChromiumExtensionCommands.runsNamed)
        #expect(ChromiumExtensionCommands.owner(of: [Hotkey("x", [.command, .shift])], in: rows, pageHasKeys: false)?.command == "_execute_action")
        // A global one is Chrome's Carbon hot key's, anywhere.
        let global = [try item([["name": .string("anywhere"), "shortcut": .string("Command+Shift+1"), "global": .bool(true)]])]
        #expect(ChromiumExtensionCommands.owner(of: [Hotkey("1", [.command, .shift])], in: global, pageHasKeys: false) == nil)
        // A disabled extension's keys aren't heard.
        let off = [try item([["name": .string("_execute_action"), "shortcut": .string("Command+Shift+X")]], state: "DISABLED")]
        #expect(owner([Hotkey("x", [.command, .shift])], off) == nil)
        // Nor a command turned off in Settings › Shortcuts.
        ExtensionCommands.set(.init(alias: "", off: true), Self.id, "_execute_action")
        #expect(owner([Hotkey("x", [.command, .shift])], rows) == nil)
    }
}
