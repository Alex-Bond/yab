import AppKit
import XCTest
@testable import Fast

@MainActor
final class HotkeyEventTests: XCTestCase {
    private let board = KeyBoard(layout: nil, typesASCII: true, ascii: nil)

    func testApplicationEventsHaveNoHotkey() throws {
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                                   modifierFlags: .command, timestamp: 0,
                                                   windowNumber: 0, context: nil, subtype: 0,
                                                   data1: 0, data2: 0))
        XCTAssertTrue(Hotkey.readings(event, on: board).isEmpty)
    }

    func testMouseEventsHaveNoHotkey() throws {
        for type: NSEvent.EventType in [.leftMouseDown, .mouseMoved] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero,
                                                       modifierFlags: .command, timestamp: 0,
                                                       windowNumber: 0, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 0))
            XCTAssertTrue(Hotkey.readings(event, on: board).isEmpty, "\(type)")
        }
    }

    func testKeyboardEventsKeepTheirReadings() throws {
        for type: NSEvent.EventType in [.keyDown, .keyUp, .flagsChanged] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
                                                     modifierFlags: .command, timestamp: 0,
                                                     windowNumber: 0, context: nil,
                                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                                     isARepeat: false, keyCode: 36))
            XCTAssertEqual(Hotkey.readings(event, on: board), [Hotkey("↩", .command)], "\(type)")
        }
    }
}
