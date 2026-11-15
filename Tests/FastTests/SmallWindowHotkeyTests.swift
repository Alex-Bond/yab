import AppKit
import Testing
@testable import Fast

/// The small window's key from any app (request #417): on with no choice
/// made, as Little Arc's is, and a key recorded in Shortcuts heard at once,
/// with the switch in Small Window coming on with it.
@MainActor
struct SmallWindowHotkeyTests {
    private func store() -> UserDefaults {
        let name = "SmallWindowHotkeyTests." + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func onUnlessTurnedOff() {
        let store = store()
        #expect(LinkWindow.keyWanted(in: store))
        store.set(false, forKey: LinkWindow.hotkeyKey)
        #expect(!LinkWindow.keyWanted(in: store))
        store.set(true, forKey: LinkWindow.hotkeyKey)
        #expect(LinkWindow.keyWanted(in: store))
    }

    @Test func plansTheKeyAsItIsNow() {
        let keys = Hotkey("n", [.option, .command])
        let code: (String) -> UInt16? = { $0 == "n" ? 45 : $0 == "space" ? 49 : nil }
        let plan = LinkWindow.plan(on: true, keys: keys, code: code)
        #expect(plan?.keys == keys)
        #expect(plan?.code == 45)
        #expect(LinkWindow.plan(on: false, keys: keys, code: code) == nil)
        #expect(LinkWindow.plan(on: true, keys: nil, code: code) == nil)
        #expect(LinkWindow.plan(on: true, keys: Hotkey("n", [.shift]), code: code) == nil)
        #expect(LinkWindow.plan(on: true, keys: Hotkey("é", [.command]), code: code) == nil)
        let other = Hotkey("space", [.control, .option])
        #expect(LinkWindow.plan(on: true, keys: other, code: code)?.code == 49)
    }

    @Test func aRecordedKeyIsTheOneResolved() throws {
        let other = Hotkey("l", [.control, .option, .command])
        #expect(Keymap.resolved(chosen: [:])[.newSmallWindow] == Hotkey("n", [.option, .command]))
        let given = Keymap.resolved(chosen: [Shortcut.Action.newSmallWindow.rawValue: other.stored])
        #expect(given[.newSmallWindow] == other)
        let removed = Keymap.resolved(chosen: [Shortcut.Action.newSmallWindow.rawValue: ""])
        #expect(removed[.newSmallWindow] == nil)
    }

    @Test func recordingAKeyTurnsTheSwitchOn() throws {
        try #require(Links.browser == nil)
        let store = store()
        store.set(false, forKey: LinkWindow.hotkeyKey)
        Keymap.wantSmallKey(in: store)
        #expect(LinkWindow.keyWanted(in: store))
    }

    @Test func registersAndLetsGo() {
        _ = NSApplication.shared
        LinkWindow.hotkey(true)
        // Heard, or refused by another app holding ⌥⌘N: either way asked for.
        #expect(LinkWindow.globalKey.state != .off)
        LinkWindow.hotkey(false)
        #expect(LinkWindow.globalKey.state == .off)
    }

    @Test func rowsSayWhyTheKeyIsNotHeard() {
        let off = "Disabled in Small Window settings."
        #expect(GlobalKeyWords.note(.heard, off: off) == nil)
        #expect(GlobalKeyWords.note(.off, off: off) == off)
        #expect(GlobalKeyWords.note(.off, off: nil) == nil)
        #expect(GlobalKeyWords.note(.taken, off: nil) != nil)
    }
}

/// Show Yab (a Yab Alpha tester): a key of your own that brings Yab to the
/// front from any app. None out of the box; any recorded key with a
/// modifier is heard from every app and shared with nothing else.
@MainActor
struct ShowYabHotkeyTests {
    @Test func noKeyOutOfTheBox() {
        #expect(Shortcut.byAction[.showYab]?.key == nil)
        #expect(Keymap.resolved(chosen: [:])[.showYab] == nil)
        let given = Hotkey("y", [.control, .option])
        #expect(Keymap.resolved(chosen: [Shortcut.Action.showYab.rawValue: given.stored])[.showYab] == given)
    }

    @Test func aKeyForEveryAppNeedsAModifier() {
        #expect(Shortcut.global.contains(.showYab))
        #expect(GlobalKey.plan(on: true, keys: Hotkey("y", [.shift]), code: { _ in 16 }) == nil)
        #expect(GlobalKey.plan(on: true, keys: Hotkey("y", [.control, .option]), code: { _ in 16 })?.code == 16)
    }

    @Test func sharesItsKeyWithNothing() {
        let key = Hotkey("y", [.control, .option])
        #expect(Keymap.conflicts(.showYab, key, .mailReply, key))
        #expect(Keymap.conflicts(.newSmallWindow, key, .showYab, key))
    }

    @Test func registersAndLetsGo() {
        _ = NSApplication.shared
        let key = GlobalKey(id: 99, pressed: {}, again: {})
        key.register(on: true, keys: Hotkey("y", [.control, .option, .command, .shift]))
        #expect(key.state != .off)
        key.register(on: true, keys: nil)
        #expect(key.state == .off)
    }
}
