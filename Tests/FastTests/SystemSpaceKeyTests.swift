import AppKit
import Testing
@testable import Fast

struct SystemSpaceKeyTests {
    @MainActor @Test func inputSourceAndCharacterPickerKeysCannotBeAssignedToReload() {
        for flags in [NSEvent.ModifierFlags.control, [.control, .command]] {
            let key = Hotkey("space", flags)
            #expect(Shortcut.system.contains(key))
            for action in [Shortcut.Action.reload, .hardReload, .emoji] {
                #expect(!Keymap.valid(key, for: action))
            }
            #expect(Keymap.resolved(chosen: [Shortcut.Action.reload.rawValue: key.stored])[.reload] == Hotkey("r", .command))
        }
    }

    @MainActor @Test func systemSpaceNeverHasABrowserActionWithoutAnAssignment() throws {
        let board = try #require(KeyBoard("com.apple.keylayout.ABC"))
        let current = Keymap.resolved(chosen: [:])
        let owners = Dictionary(uniqueKeysWithValues: current.filter { Shortcut.context($0.key) == .browser }.map { ($0.value, $0.key) })
        for flags in [NSEvent.ModifierFlags.control, [.control, .command]] {
            let readings = Hotkey.readings(code: 49, flags: flags, on: board)
            #expect(readings == [Hotkey("space", flags)])
            for key in readings { #expect(Keymap.mappedBrowserAction(for: key, owners: owners) == nil) }
        }
    }

    @MainActor @Test func chromiumLeavesCommandSpaceToTheSystemBeforeThePage() {
        for typing in [false, true] {
            #expect(!ChromiumPage.offersCommandToPage(" ", typing: typing))
        }
    }
}
