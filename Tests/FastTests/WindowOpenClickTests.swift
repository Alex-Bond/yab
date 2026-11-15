import AppKit
import Testing
@testable import Fast

@MainActor
struct WindowOpenClickTests {
    private func mouse(_ type: NSEvent.EventType, at time: TimeInterval, window: Int = 12, button: Int = 2, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        let event = try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: time, windowNumber: window, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        guard type == .otherMouseDown || type == .otherMouseUp else { return event }
        let made = try #require(event.cgEvent)
        made.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return try #require(NSEvent(cgEvent: made))
    }

    private func key(at time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: time, windowNumber: 12, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private func foreground(_ click: PageView.WindowClick, at time: TimeInterval, window: Int? = 12,
                            held: NSEvent.ModifierFlags = .command) -> Bool? {
        let action = PageAction(request: URLRequest(url: URL(string: "https://example.com")!), kind: .other,
            targetIsMainFrame: nil, source: nil, modifierFlags: [], buttonNumber: 0,
            shouldPerformDownload: false, userInitiated: true)
        return Browser.modifiedForeground(for: action, isPopup: false, held: held,
                                          afterClick: click.follows(at: time, in: window), clickedButton: click.button(at: time, in: window),
                                          clickedFlags: click.modifiers(at: time, in: window))
    }

    @Test func clickThenOpenUsesCapturedCommandAfterRelease() throws {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp] {
            var click = PageView.WindowClick()
            let event = try mouse(type, at: 100)
            if type == .otherMouseDown || type == .otherMouseUp { #expect(event.buttonNumber == 2) }
            click.record(event)
            #expect(foreground(click, at: 100.1) == false)
            #expect(foreground(click, at: 100.1, held: [.command, .shift]) == false)
            #expect(foreground(click, at: 100.1, held: []) == false)
        }
    }

    @Test func middleClickKeepsScriptedDestinationBehind() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.otherMouseUp, at: 100, flags: []))
        #expect(foreground(click, at: 100.1, held: []) == false)
        #expect(foreground(click, at: 100.1, held: .shift) == false)
        click.record(try mouse(.otherMouseUp, at: 100, flags: .shift))
        #expect(foreground(click, at: 100.1, held: []) == true)
        #expect(foreground(click, at: 100.501, held: []) == nil)
        #expect(foreground(click, at: 100.1, window: 13, held: []) == nil)
    }

    @Test func keyThenOpenKeepsTheDefaultForeground() throws {
        var click = PageView.WindowClick()
        click.record(try key(at: 100))
        #expect(foreground(click, at: 100.1) == nil)
        #expect(foreground(click, at: 100.1) ?? true)
    }

    @Test func keyAfterClickDoesNotBorrowTheEarlierClick() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.leftMouseUp, at: 100))
        click.record(try key(at: 100.1))
        #expect(foreground(click, at: 100.2) == nil)
    }

    @Test func lateOpenKeepsTheDefaultForeground() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.leftMouseUp, at: 100))
        #expect(foreground(click, at: 100.5) == false)
        #expect(foreground(click, at: 100.501) == nil)
        #expect(foreground(click, at: 99.9) == nil)
    }

    @Test func mouseUpRefreshesTheClickTime() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.leftMouseDown, at: 100))
        click.record(try mouse(.leftMouseUp, at: 101))
        #expect(foreground(click, at: 101.1) == false)
    }

    @Test func clickBelongsToItsPageAndWindow() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.leftMouseUp, at: 100))
        #expect(foreground(click, at: 100.1, window: 13) == nil)
        #expect(foreground(click, at: 100.1, window: nil) == nil)
        #expect(foreground(click, at: 100.1, window: 0) == nil)
        #expect(foreground(PageView.WindowClick(), at: 100.1) == nil)
    }

    @Test func rightClickDoesNotQualify() throws {
        var click = PageView.WindowClick()
        click.record(try mouse(.leftMouseUp, at: 100))
        click.record(try mouse(.rightMouseDown, at: 100.1))
        #expect(foreground(click, at: 100.2) == nil)
    }

    @Test func sideButtonsDoNotQualify() throws {
        for type: NSEvent.EventType in [.otherMouseDown, .otherMouseUp] {
            for button in [3, 4] {
                var click = PageView.WindowClick()
                click.record(try mouse(.leftMouseUp, at: 100))
                click.record(try mouse(type, at: 100.1, button: button))
                #expect(foreground(click, at: 100.2) == nil)
            }
        }
    }
}
