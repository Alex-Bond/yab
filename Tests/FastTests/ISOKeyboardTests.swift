import AppKit
import Carbon.HIToolbox
import Testing
@testable import Fast

@MainActor
struct ISOKeyboardTests {
    private let codes = [UInt16(kVK_ISO_Section), UInt16(kVK_ANSI_Grave)]

    private func event(_ code: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags,
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: character, charactersIgnoringModifiers: character,
                                     isARepeat: false, keyCode: code))
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func swappedGraveFollowsTheEventCharacter(_ keyboardType: UInt32) throws {
        let board = try #require(KeyBoard("com.apple.keylayout.ABC", keyboardType: keyboardType))
        for code in codes {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let press = try event(code, "`", .command, type: type)
                let readings = Hotkey.readings(press, on: board)
                #expect(readings.first == Hotkey("`", .command))
                let first = try #require(readings.first)
                #expect(Shortcut.kept(first, from: nil))
            }
            let reverse = try event(code, "~", [.command, .shift])
            #expect(Hotkey.readings(reverse, on: board).first == Hotkey("`", [.command, .shift]))
        }
    }

    @Test(arguments: ["com.apple.keylayout.German", "com.apple.keylayout.Danish"], [UInt32(40), UInt32(41)])
    func angleBracketKeyDoesNotBecomeGrave(_ layout: String, _ keyboardType: UInt32) throws {
        let board = try #require(KeyBoard(layout, keyboardType: keyboardType))
        for code in codes {
            let press = try event(code, "<", .command)
            let readings = Hotkey.readings(press, on: board)
            #expect(readings.first == Hotkey("<", .command))
            #expect(!readings.contains(Hotkey("`", .command)))
            let shifted = try event(code, ">", [.command, .shift])
            #expect(Hotkey.readings(shifted, on: board).first == Hotkey("<", [.command, .shift]))
            // The recorder stores the first reading, and menus use its key.
            let recorded = try #require(readings.first)
            #expect(recorded.stored == "⌘<")
            #expect(Hotkey(stored: recorded.stored) == recorded)
            #expect(recorded.menu != nil)
            let owners: [Hotkey: Shortcut.Action] = [recorded: .nextTab, Hotkey("`", .command): .recentTab]
            #expect(Keymap.mappedBrowserAction(for: recorded, owners: owners) == .nextTab)
        }
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func isoKeyIsIncludedInReverseLookup(_ keyboardType: UInt32) throws {
        let board = try #require(KeyBoard("com.apple.keylayout.German", keyboardType: keyboardType))
        let code = try #require(codes.first { board.type($0, 0, on: board.layout) == "<" })
        #expect(KeyLayout.typingCodes.contains(UInt16(kVK_ISO_Section)))
        #expect(board.code(typing: "<") == code)
        #expect(KeyLayout.code(for: "<", on: board) == code)
        #expect(KeyLayout.keyName(for: "<", at: code, on: board) == "<")
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func nonASCIIMarkDoesNotBecomeAnANSIGrave(_ keyboardType: UInt32) throws {
        // Danish's unshifted positions are ASCII; Swedish types § here.
        let board = try #require(KeyBoard("com.apple.keylayout.Swedish", keyboardType: keyboardType))
        let character = "§"
        let translation = try #require(codes.first { board.type($0, 0, on: board.layout) == character })
        #expect(KeyLayout.code(for: character, on: board) == translation)
        #expect(KeyLayout.keyName(for: character, at: translation, on: board) == character)
        for code in codes {
            let press = try event(code, character, .control)
            let readings = Hotkey.readings(press, on: board)
            #expect(!readings.contains(Hotkey("`", .control)))
            let recorded = try #require(readings.first)
            #expect(recorded == Hotkey(character, .control))
            #expect(recorded.stored == "⌃" + character)
            #expect(Hotkey(stored: recorded.stored) == recorded)
        }
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func windowCycleKeyIsNotBlockedAsShiftedSettings(_ keyboardType: UInt32) throws {
        let board = try #require(KeyBoard("com.apple.keylayout.Danish", keyboardType: keyboardType))
        let owners: [Hotkey: Shortcut.Action] = [Hotkey(",", .command): .settings, Hotkey(".", .command): .stopLoading]
        for code in codes {
            let press = try event(code, "<", .command)
            let readings = Hotkey.readings(press, on: board)
            #expect(readings.contains(Hotkey(",", [.command, .shift])))
            #expect(!Keymap.hasShiftedOwner(readings) { Keymap.mappedBrowserAction(for: $0, owners: owners) != nil })
            let reverse = try event(code, ">", [.command, .shift])
            let reverseReadings = Hotkey.readings(reverse, on: board)
            #expect(reverseReadings.contains(Hotkey(".", [.command, .shift])))
            #expect(!Keymap.hasShiftedOwner(reverseReadings) { Keymap.mappedBrowserAction(for: $0, owners: owners) != nil })
        }
        let shiftedComma = [Hotkey(",", [.command, .shift])]
        #expect(Keymap.hasShiftedOwner(shiftedComma) { Keymap.mappedBrowserAction(for: $0, owners: owners) != nil })
        let reload: [Hotkey: Shortcut.Action] = [Hotkey("r", [.command, .shift]): .hardReload]
        #expect(Keymap.hasShiftedOwner([Hotkey("r", .command)]) { Keymap.mappedBrowserAction(for: $0, owners: reload) != nil })
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func russianASCIIFallbackCanHaveAShiftedOwner(_ keyboardType: UInt32) throws {
        // Russian's Command key is M; the last ASCII layout is French,
        // where that position types ? with Shift.
        let board = try #require(KeyBoard("com.apple.keylayout.Russian", ascii: "com.apple.keylayout.French", keyboardType: keyboardType))
        let code = UInt16(kVK_ANSI_M)
        let character = try #require(board.type(code, UInt32(shiftKey), on: board.layout))
        #expect(board.type(code, UInt32(shiftKey), on: board.ascii) == "?")
        let press = try event(code, character, [.command, .shift])
        let readings = Hotkey.readings(press, on: board)
        let primary = try #require(readings.first)
        let fallback = Hotkey("/", [.command, .shift])
        #expect(primary == Hotkey("m", [.command, .shift]))
        #expect(readings.dropFirst().contains(fallback))
        let owners: [Hotkey: Shortcut.Action] = [Hotkey("/", .command): .find]
        var checked: [Hotkey] = []
        #expect(Keymap.hasShiftedOwner(readings) {
            checked.append($0)
            return Keymap.mappedBrowserAction(for: $0, owners: owners) != nil
        })
        #expect(checked.first == Hotkey(primary.key, primary.flags.symmetricDifference(.shift)))
        #expect(checked.contains(Hotkey("/", .command)))
        #expect(!Keymap.hasShiftedOwner(readings) { _ in false })
    }

    @Test func ansiReadingsStayTheSame() throws {
        let board = try #require(KeyBoard("com.apple.keylayout.ABC", keyboardType: 40))
        for code in KeyLayout.physical.keys {
            for flags: NSEvent.ModifierFlags in [[], .command, [.command, .shift], [.command, .option]] {
                let modifiers: UInt32 = flags.contains(.shift) ? UInt32(shiftKey) : 0
                let character = try #require(board.type(code, modifiers, on: board.layout))
                let press = try event(code, character, flags)
                #expect(Hotkey.readings(press, on: board) == Hotkey.readings(code: code, flags: flags, on: board))
            }
        }
    }

    @Test func missingCharactersKeepTheirReadings() throws {
        let abc = try #require(KeyBoard("com.apple.keylayout.ABC", keyboardType: 40))
        for code in codes {
            let empty = try event(code, "", .command)
            #expect(Hotkey.readings(empty, on: abc) == Hotkey.readings(code: code, flags: .command, on: abc))
            #expect(abc.code(for: code, charactersIgnoringModifiers: nil, flags: .command) == code)
        }
    }

    @Test(arguments: [UInt32(40), UInt32(41)])
    func nonLatinLayoutKeepsItsASCIIFallbackAfterResolvingISO(_ keyboardType: UInt32) throws {
        let board = try #require(KeyBoard("com.apple.keylayout.Russian", keyboardType: keyboardType))
        for code in codes {
            let character = try #require(board.type(code, 0, on: board.layout))
            let expected = Hotkey.readings(code: code, flags: .command, on: board)
            for eventCode in codes {
                let press = try event(eventCode, character, .command)
                #expect(Hotkey.readings(press, on: board) == expected)
            }
        }
    }
}
