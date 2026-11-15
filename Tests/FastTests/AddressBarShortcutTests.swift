import Testing
import AppKit
@testable import Fast

@MainActor
struct AddressBarShortcutTests {
    private let address = Hotkey("d", [.shift, .command])

    private func action(_ key: Hotkey, in keys: [Shortcut.Action: Hotkey]) -> Shortcut.Action? {
        let owners = Dictionary(uniqueKeysWithValues: keys.compactMap { action, key in
            Shortcut.context(action) == .browser ? (key, action) : nil
        })
        return Keymap.mappedBrowserAction(for: key, owners: owners)
    }

    @Test func freshAddressBarChordHasOneOwnerAndMatchingMenuHints() {
        let keys = Keymap.resolved(chosen: [:])
        #expect(Shortcut.byAction[.addressBar]?.key == address)
        #expect(Shortcut.byAction[.pin]?.key == nil)
        #expect(action(address, in: keys) == .addressBar)
        #expect(keys[.pin] == nil)
        #expect(keys[.keepTab] == Hotkey("d", .command))
        let hints = Dictionary(uniqueKeysWithValues: Hotkeys.items)
        #expect(hints["Show Address Bar"] == address.text)
        #expect(hints["Pin Tab"] == "")
        #expect(hints["Send Feedback…"] == "⌥⇧I")
        #expect(keys[.sendFeedback] == Hotkey("i", [.option, .shift]))
    }

    @Test func chosenPinAndAddressKeysKeepWinningOverNewDefaults() {
        let oldAddress = Hotkey("l", [.shift, .command])
        let chosen = [Shortcut.Action.pin.rawValue: address.stored,
                      Shortcut.Action.addressBar.rawValue: oldAddress.stored]
        let keys = Keymap.resolved(chosen: chosen)
        #expect(action(address, in: keys) == .pin)
        #expect(action(oldAddress, in: keys) == .addressBar)
        #expect(chosen[Shortcut.Action.pin.rawValue] == address.stored)
        let pinOnly = Keymap.resolved(chosen: [Shortcut.Action.pin.rawValue: address.stored])
        #expect(action(address, in: pinOnly) == .pin)
        #expect(pinOnly[.addressBar] == nil)
    }

    @Test func appShortcutForVisibleUnpinTitleStillWins() throws {
        let raw = Hotkeys.normalizedUserKeys(["Unpin Tab": "@$d"], visibleTitles: [.pin: "Unpin Tab"])
        let pin = try #require(raw["Pin Tab"].flatMap { Hotkey(userKey: $0) })
        #expect(pin == address)
        let keys = Keymap.resolved(chosen: [Shortcut.Action.addressBar.rawValue: address.stored], system: [.pin: pin])
        #expect(action(address, in: keys) == .pin)
        #expect(keys[.addressBar] == nil)
        let custom = Hotkey("a", [.control, .option, .command])
        let addressKeys = Keymap.resolved(chosen: [:], system: [.addressBar: custom])
        #expect(action(custom, in: addressKeys) == .addressBar)
        #expect(action(address, in: addressKeys) == nil)
    }

    @Test func explicitlyRemovedAddressShortcutStaysRemoved() {
        let keys = Keymap.resolved(chosen: [Shortcut.Action.addressBar.rawValue: ""])
        #expect(keys[.addressBar] == nil)
        #expect(keys[.pin] == nil)
        #expect(action(address, in: keys) == nil)
    }
}
