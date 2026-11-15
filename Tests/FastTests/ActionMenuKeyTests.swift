import AppKit
import Testing
@testable import Fast

/// Register 1890 (feedback #1406): a right-click menu drawn as ⌘K's list
/// shows each line's key; pressing it does that line, as an open Mac menu
/// does. A folder's "Close 2 Tabs ⌘W" did nothing: the panel had the keys,
/// and ⌘W went past it to File's Close Tab.
@MainActor @Suite(.serialized)
struct ActionMenuKeyTests {
    @MainActor final class Target: NSObject {
        var calls: [String] = []
        @objc func run(_ sender: NSMenuItem) { calls.append(sender.title) }
    }

    private func menu(_ target: Target) -> NSMenu {
        _ = NSApplication.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, key, flags, on) in [("Rename…", "", NSEvent.ModifierFlags(), true),
                                        ("Copy 2 URLs", "C", .command, true),
                                        ("Put 2 Tabs to Sleep", "s", .command, false),
                                        ("Close 2 Tabs", "w", .command, true)] {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = target
            item.isEnabled = on
            menu.addItem(item)
        }
        return menu
    }

    private func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags, window: Int = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    @Test func aLineKeyDoesThatLine() throws {
        let target = Target()
        let list = ActionMenuList(menu: menu(target), falls: true, compact: false)
        #expect(list.press(try key("w", code: 13, .command)))
        #expect(target.calls == ["Close 2 Tabs"])
        // A capital is its letter with ⇧.
        #expect(list.press(try key("c", code: 8, [.command, .shift])))
        #expect(target.calls == ["Close 2 Tabs", "Copy 2 URLs"])
    }

    @Test func otherKeysAreLeftAlone() throws {
        let target = Target()
        let list = ActionMenuList(menu: menu(target), falls: true, compact: false)
        // Typed into the search, not a line's key.
        #expect(!list.press(try key("w", code: 13, [])))
        // ⌘C without ⇧ is the search's Copy.
        #expect(!list.press(try key("c", code: 8, .command)))
        // A line that is off keeps its key from doing anything here.
        #expect(!list.press(try key("s", code: 1, .command)))
        #expect(target.calls.isEmpty)
    }

    @Test func thePanelTakesTheKeyBeforeTheAppMenus() throws {
        // The panel's own window, not ActionMenu's one panel: other suites
        // hold that one while they run beside this one.
        let target = Target()
        let list = ActionMenuList(menu: menu(target), falls: true, compact: false)
        let panel = DropPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.actionKeyEquivalent = { list.press($0) }
        // AppKit asks the key window for a key equivalent before the menu bar.
        #expect(panel.performKeyEquivalent(with: try key("w", code: 13, .command, window: panel.windowNumber)))
        #expect(target.calls == ["Close 2 Tabs"])
        #expect(!panel.performKeyEquivalent(with: try key("c", code: 8, .command, window: panel.windowNumber)))
    }
}
