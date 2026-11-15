import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct MenuKeyTests {
    @Test func everyActionCanConstructItsMenuAndGlyphWithNoKey() {
        let keymap = Keymap.shared
        let saved = Store.settings.object(forKey: "shortcuts")
        defer {
            if let saved { Store.settings.set(saved, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            keymap.adoptStored()
        }
        Store.settings.set(Dictionary(uniqueKeysWithValues: Shortcut.Action.allCases.map {
            ($0.rawValue, "")
        }), forKey: "shortcuts")
        keymap.adoptStored()
        for action in Shortcut.Action.allCases {
            let modifier = MenuKey(action: action, enabled: true)
            #expect(modifier.slot === keymap.slot(action))
            #expect(modifier.slot.keys == nil)
            _ = Text("Action").modifier(modifier)
            _ = ShortcutGlyphs(action, size: 12, tint: nil)
            _ = Text("Disabled").shortcut(action, enabled: false)
        }
    }

    @Test func menuKeepsTheLiveSlotAcrossRemapping() {
        let keymap = Keymap.shared
        let saved = Store.settings.object(forKey: "shortcuts")
        defer {
            if let saved { Store.settings.set(saved, forKey: "shortcuts") }
            else { Store.settings.removeObject(forKey: "shortcuts") }
            keymap.adoptStored()
        }
        let modifier = MenuKey(action: .reader, enabled: true)
        let key = Hotkey("r", [.control, .option, .command])
        keymap.set(key, for: .reader)
        #expect(modifier.slot.keys == key)
        keymap.set(nil, for: .reader)
        #expect(modifier.slot.keys == nil)
    }
}
