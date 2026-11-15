import AppKit
import Carbon.HIToolbox
import Testing
@testable import Fast

/// The layouts every key is pressed on below.
let keyboardLayouts = [
    "com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.Russian",
    "com.apple.keylayout.RussianWin", "com.apple.keylayout.Ukrainian-PC", "com.apple.keylayout.Hebrew",
    "com.apple.keylayout.Greek", "com.apple.keylayout.German", "com.apple.keylayout.French",
    "com.apple.keylayout.Dvorak", "com.apple.keylayout.DVORAK-QWERTYCMD",
]

/// Every key Yab answers to, pressed the way someone on another layout
/// presses it: the key code and modifiers that layout types the key with,
/// read through Hotkey.readings on that layout's own tables, whatever
/// layout this Mac has picked.
/// On the main thread, where HIToolbox wants its input sources asked about.
@MainActor
struct KeyboardLayoutTests {
    private func board(_ id: String) throws -> KeyBoard {
        try #require(KeyBoard(id), "\(id) is not on this Mac")
    }

    private func read(_ code: UInt16, _ flags: NSEvent.ModifierFlags, on board: KeyBoard) -> Hotkey? {
        Hotkey.readings(code: code, flags: flags, on: board).first
    }

    // MARK: - one key at a time

    @Test func commandKeysOnRussianAreLatin() throws {
        let russian = try board("com.apple.keylayout.Russian")
        #expect(read(17, .command, on: russian) == Hotkey("t", .command)) // ⌘Е
        #expect(read(37, .command, on: russian) == Hotkey("l", .command))
        #expect(read(13, .command, on: russian) == Hotkey("w", .command))
        #expect(read(17, [.command, .shift], on: russian) == Hotkey("t", [.command, .shift]))
        #expect(read(33, .command, on: russian) == Hotkey("[", .command)) // ⌘Х
        #expect(read(18, .command, on: russian) == Hotkey("1", .command))
        // Mail's own letters without switching: О is j, Л is k.
        #expect(read(38, [], on: russian) == Hotkey("j", []))
        #expect(read(40, [], on: russian) == Hotkey("k", []))
        // ⇧ and the key under / is ?, mail's list of keys.
        #expect(read(44, .shift, on: russian) == Hotkey("/", .shift))
        // This layout types / where ` is; Yab reads the ASCII layout's key there.
        #expect(read(50, [], on: russian) == Hotkey("`", []))
    }

    @Test func otherLayoutsWithoutASCII() throws {
        for id in ["com.apple.keylayout.Hebrew", "com.apple.keylayout.Greek", "com.apple.keylayout.Ukrainian-PC",
                   "com.apple.keylayout.RussianWin"] {
            let board = try board(id)
            #expect(read(17, .command, on: board) == Hotkey("t", .command), "\(id)")
            // Hebrew types / and Greek ; on the Q key.
            #expect(read(12, [], on: board) == Hotkey("q", []), "\(id)")
            #expect(read(38, [], on: board) == Hotkey("j", []), "\(id)")
        }
    }

    @Test func azertyReadsWhatItTypes() throws {
        let french = try board("com.apple.keylayout.French")
        // ⌘Z is undo where Z is, not ⌘W, and ⌘W closes where W is.
        #expect(read(13, .command, on: french) == Hotkey("z", .command))
        #expect(read(6, .command, on: french) == Hotkey("w", .command))
        #expect(read(12, .command, on: french) == Hotkey("a", .command))
        #expect(read(0, .command, on: french) == Hotkey("q", .command))
        // ⌘1 to ⌘9 by the top row, which types & é " without ⇧.
        #expect(read(18, .command, on: french) == Hotkey("1", .command))
        #expect(read(25, .command, on: french) == Hotkey("9", .command))
        // ? is ⇧, there.
        #expect(Hotkey.readings(code: 46, flags: .shift, on: french).contains(Hotkey("/", .shift)))
        // { is ⌥( there: ⇧⌘[ is ⌥⌘(.
        #expect(Hotkey.readings(code: 23, flags: [.command, .option], on: french).contains(Hotkey("[", [.command, .shift])))
    }

    @Test func aMarkIsHeardOnlyWhenTheKeyItselfIsNobodys() throws {
        let french = try board("com.apple.keylayout.French")
        // ⌘1 on AZERTY types ⌘&, which is ⇧⌘7 on a US keyboard, mail's
        // numbered list: the key is ⌘1's, so the mark isn't heard.
        let one = Hotkey.readings(code: 18, flags: .command, on: french)
        #expect(one.contains(Hotkey("7", [.command, .shift])))
        #expect(Keymap.shared.matches(one, .tab1))
        #expect(!Keymap.shared.matches(one, .mailNumbers))
        // ? is ⇧, there: ⇧, is nobody's, so the mark is mail's keys.
        #expect(Keymap.shared.matches(Hotkey.readings(code: 46, flags: .shift, on: french), .mailKeys))
    }

    @Test func qwertzReadsWhatItTypes() throws {
        let german = try board("com.apple.keylayout.German")
        #expect(read(16, .command, on: german) == Hotkey("z", .command))
        #expect(read(6, .command, on: german) == Hotkey("y", .command))
        // [ is ⌥5: ⌘[ is ⌥⌘5.
        #expect(Hotkey.readings(code: 23, flags: [.command, .option], on: german).contains(Hotkey("[", .command)))
        // # has a key of its own: mail's # without ⇧.
        #expect(Hotkey.readings(code: 42, flags: [], on: german).contains(Hotkey("3", .shift)))
        // Ü types nothing ASCII: it is the key it sits on, [.
        #expect(read(33, .command, on: german) == Hotkey("[", .command))
        // + has a key of its own too.
        #expect(read(30, .command, on: german) == Hotkey("+", .command))
    }

    @Test func dvorakAndItsQwertyCommand() throws {
        let dvorak = try board("com.apple.keylayout.Dvorak")
        #expect(read(40, .command, on: dvorak) == Hotkey("t", .command))
        #expect(read(17, .command, on: dvorak) == Hotkey("y", .command))
        #expect(read(8, [], on: dvorak) == Hotkey("j", []))
        let mixed = try board("com.apple.keylayout.DVORAK-QWERTYCMD")
        // ⌘ is QWERTY's, the rest Dvorak's.
        #expect(read(17, .command, on: mixed) == Hotkey("t", .command))
        #expect(read(40, .command, on: mixed) == Hotkey("k", .command))
        #expect(read(8, [], on: mixed) == Hotkey("j", []))
        #expect(read(40, [], on: mixed) == Hotkey("t", []))
    }

    @Test func appShortcutsCharactersBecomeTheKeyAPressIsReadAs() throws {
        let russian = try board("com.apple.keylayout.Russian")
        let french = try board("com.apple.keylayout.French")
        #expect(KeyLayout.keyName(for: "е", at: 17, on: russian) == "t")
        #expect(KeyLayout.keyName(for: "&", at: 18, on: french) == "1")
        #expect(KeyLayout.keyName(for: "z", at: 13, on: french) == "z")
        #expect(KeyLayout.keyName(for: "q", at: 0, on: french) == "q")
    }

    // MARK: - every key Yab has, on every layout

    /// Where a key is typed on a layout: a layout without ASCII has the
    /// ASCII layout's keys under ⌘ and for Yab's letters, so they are
    /// pressed where they are there; one with ASCII types the key, or its
    /// mark, with ⇧ or ⌥ if it must.
    private func press(_ key: Hotkey, on board: KeyBoard) -> (UInt16, NSEvent.ModifierFlags)? {
        if let code = KeyLayout.named.filter({ $0.value == key.key }).map(\.key).min() { return (code, key.flags) }
        let codes = KeyLayout.typingCodes.union(KeyLayout.named.filter { Int($0.value) != nil }.map(\.key)).sorted()
        let command = key.flags.contains(.command) ? UInt32(cmdKey) : 0
        let data = board.typesASCII ? board.layout : board.ascii
        var targets = [(key.key, key.flags)]
        // ⇧⌘] is ⌘}: typed as } where } has a key or a ⌥ of its own.
        if key.flags.contains(.shift), let mark = Hotkey.shifted[key.key] { targets.insert((mark, key.flags.subtracting(.shift)), at: 0) }
        if let base = Hotkey.unshifted[key.key] { targets.append((base, key.flags.union(.shift))) }
        let extras: [NSEvent.ModifierFlags] = [[], [.shift], [.option], [.shift, .option]]
        for (character, flags) in targets {
            for extra in extras {
                // Under ⌘ a layout drops ⇧: a mark is looked for without it.
                var modifiers = extra.isEmpty ? command : 0
                if extra.contains(.shift) || (flags.contains(.shift) && !extra.isEmpty) { modifiers |= UInt32(shiftKey) }
                if extra.contains(.option) { modifiers |= UInt32(optionKey) }
                let letter = character.count == 1 && character.first!.isLetter
                if letter, !extra.isEmpty { continue }
                // A ⇧ the key keeps can't also be the ⇧ a mark is typed with.
                if flags.contains(.shift), extra.contains(.shift) { continue }
                if let code = codes.first(where: {
                    // A key that types something else under ⌘ (Dvorak -
                    // QWERTY ⌘) can't be a mark's key for a ⌘ shortcut.
                    if command != 0, !extra.isEmpty, board.type($0, command, on: data) != board.type($0, 0, on: data) { return false }
                    let typed = board.type($0, modifiers, on: data)
                    return letter ? typed?.lowercased() == character : typed == character
                }) {
                    return (code, flags.union(extra))
                }
            }
        }
        return nil
    }

    @Test(arguments: keyboardLayouts)
    func everyDefaultKeyIsHeardOn(_ id: String) throws {
        let board = try board(id)
        var keys: [(Shortcut.Context, Hotkey, String)] = []
        for item in Shortcut.items {
            if let action = item.action, let key = item.key { keys.append((Shortcut.context(action), key, action.rawValue)) }
            for hold in item.holds { keys.append((.browser, hold, item.does)) }
        }
        for place in MailGo.places { keys.append((.mail, place.key, "go to \(place.name)")) }
        var owners: [Shortcut.Context: [Hotkey: String]] = [:]
        for (context, key, name) in keys { owners[context, default: [:]][key] = owners[context]?[key] ?? name }

        var missing: [String] = []
        var wrong: [String] = []
        for (context, key, name) in keys {
            guard let (code, flags) = press(key, on: board) else {
                missing.append("\(name) \(key.text)")
                continue
            }
            let readings = Hotkey.readings(code: code, flags: flags, on: board)
            // The first reading that something in its place answers to is
            // this key's, the "=" of ⌘+ as Keymap reads it.
            let heard = readings.first { reading in
                owners[context]?[reading] != nil
                    || (reading.key == "=" && owners[context]?[Hotkey("+", reading.flags)] != nil)
                    || (reading.key == "=" && owners[context]?[Hotkey("+", reading.flags.subtracting(.shift))] != nil)
            }
            let resolved = heard.flatMap { reading -> String? in
                owners[context]?[reading]
                    ?? owners[context]?[Hotkey("+", reading.flags)]
                    ?? owners[context]?[Hotkey("+", reading.flags.subtracting(.shift))]
            }
            if resolved != owners[context]?[key] {
                wrong.append("\(name) \(key.text) pressed as \(code) \(Hotkey.caps(nil, flags).joined()) read as \(readings.map(\.text))")
            }
        }
        #expect(wrong.isEmpty, "\(id): \(wrong.joined(separator: "; "))")
        // Every key can be typed on every one of these layouts.
        #expect(missing.isEmpty, "\(id) can't type: \(missing.joined(separator: "; "))")
    }

    // MARK: - events

    @MainActor
    @Test func mailCommandsOnARussianKeyEvent() throws {
        let russian = try board("com.apple.keylayout.Russian")
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: 0, context: nil,
                                                  characters: "л", charactersIgnoringModifiers: "л",
                                                  isARepeat: false, keyCode: 40))
        #expect(Hotkey.readings(event, on: russian).first == Hotkey("k", .command))
    }

    @Test func aRecordedKeyIsStoredLatin() throws {
        // What the recorder keeps is the first reading, written as text.
        let russian = try board("com.apple.keylayout.Russian")
        let recorded = try #require(read(4, [.command, .option], on: russian))
        #expect(recorded.stored == "⌥⌘h")
        #expect(Hotkey(stored: recorded.stored) == Hotkey("h", [.command, .option]))
        #expect(recorded.caps == ["⌥", "⌘", "H"])
    }
}
