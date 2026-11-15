import AppKit
import Testing
@testable import Fast

// A browser window is movable for macOS (its menus, the green button's,
// the tiling at the screen's edges), while only the strips move it: AppKit
// gets no band of its own to drag it by (WindowDrag, DragStrip).
@MainActor
struct WindowDragTests {
    final class Fresh: NSWindow {}
    final class Plain: NSWindow {}
    final class Other: NSWindow {}
    /// A window that notes, for each event handed to it, whether it said
    /// it may be moved, and hands the event no further.
    final class Pressed: NSWindow {
        var heard: [Bool] = []
        override func sendEvent(_ event: NSEvent) { heard.append(isMovable) }
    }
    final class Grip: NSView, WindowHandle {}
    final class Dragged: NSWindow {
        var drags: [NSEvent] = []
        override func performDrag(with event: NSEvent) { drags.append(event) }
    }

    static let frame = NSRect(x: -30000, y: 0, width: 600, height: 400)
    static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    static func dressed(_ window: NSWindow) -> NSWindow {
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        return window
    }

    static func plain() -> NSWindow { dressed(NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: true)) }
    static func fresh() -> NSWindow { dressed(Fresh(contentRect: frame, styleMask: style, backing: .buffered, defer: true)) }
    static func ours() -> NSWindow { dressed(Plain(contentRect: frame, styleMask: style, backing: .buffered, defer: true)) }
    static func other() -> NSWindow { dressed(Other(contentRect: frame, styleMask: style, backing: .buffered, defer: true)) }

    @Test func aStripPressIsAClickUntilItGoesThreePoints() {
        #expect(!StripPress.drags(0, 0))
        #expect(!StripPress.drags(2.9, -2.9))
        #expect(StripPress.drags(3, 0))
        #expect(StripPress.drags(0, -3))
        #expect(StripPress.drags(-40, 12))
    }

    @Test func aCaptionPressKeepsSmallMovementAsAClick() {
        var press = LinkFieldPress()
        press.begin(at: NSPoint(x: 100, y: 100))
        let dragged = press.drag(to: NSPoint(x: 102.9, y: 97.1))
        #expect(!dragged)
        let clicked = press.end(at: NSPoint(x: 102, y: 99), inside: true)
        #expect(clicked)
        let clickedAgain = press.end(at: NSPoint(x: 102, y: 99), inside: true)
        #expect(!clickedAgain)
    }

    @Test func aCaptionDragStartsOnceAndNeverBecomesAClick() {
        for offset in [NSPoint(x: 3, y: 0), NSPoint(x: 0, y: -3), NSPoint(x: -40, y: 12)] {
            var press = LinkFieldPress()
            let draggedBeforePress = press.drag(to: offset)
            #expect(!draggedBeforePress)
            press.begin(at: .zero)
            let dragged = press.drag(to: offset)
            #expect(dragged)
            let draggedAgain = press.drag(to: NSPoint(x: 50, y: 50))
            #expect(!draggedAgain)
            let clickedAfterDrag = press.end(at: .zero, inside: true)
            #expect(!clickedAfterDrag)
            press.begin(at: .zero)
            let clicked = press.end(at: .zero, inside: true)
            #expect(clicked)
        }
    }

    @Test func aCaptionReleaseOutsideOrPastTheSlackDoesNotOpenTheField() {
        var press = LinkFieldPress()
        press.begin(at: .zero)
        let clickedOutside = press.end(at: .zero, inside: false)
        #expect(!clickedOutside)
        press.begin(at: .zero)
        let clickedPastSlack = press.end(at: NSPoint(x: 3, y: 0), inside: true)
        #expect(!clickedPastSlack)
    }

    @Test func theCaptionHandsTheOriginalPressToTheWindowWithoutAnEditingClick() throws {
        let window = Dragged(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)
        _ = Self.dressed(window)
        defer { window.close() }
        WindowDrag.keep(window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let handle = LinkFieldHandle.Handle(frame: NSRect(x: 80, y: 180, width: 440, height: 28))
        content.addSubview(handle)
        window.contentView = content
        var clicks = 0
        handle.click = { clicks += 1 }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 194), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        let down = try event(.leftMouseDown, x: 200)
        #expect(WindowDrag.onHandle(window, down))
        #expect(try !WindowDrag.onHandle(window, event(.leftMouseDown, x: 40)))
        #expect(try !WindowDrag.onHandle(window, event(.leftMouseDown, x: 550)))
        #expect(handle.acceptsFirstMouse(for: down))
        handle.mouseDown(with: down)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 202))
        #expect(window.drags.isEmpty)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 203))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 240))
        handle.mouseUp(with: try event(.leftMouseUp, x: 200))
        #expect(window.drags.count == 1)
        #expect(window.drags.first === down)
        #expect(clicks == 0)

        handle.mouseDown(with: down)
        handle.mouseUp(with: try event(.leftMouseUp, x: 200))
        #expect(clicks == 1)
        handle.mouseDown(with: down)
        handle.enabled = false
        #expect(!WindowDrag.onHandle(window, down))
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 240))
        handle.mouseUp(with: try event(.leftMouseUp, x: 200))
        #expect(window.drags.count == 1)
        #expect(clicks == 1)
    }

    @Test func aDoubleClickDoesWhatTheTitleBarSettingSays() {
        #expect(StripPress.twice(nil) == .zoom)
        #expect(StripPress.twice("Maximize") == .zoom)
        #expect(StripPress.twice("Fill") == .fill)
        #expect(StripPress.twice("Minimize") == .minimize)
        #expect(StripPress.twice("None") == .nothing)
        #expect(StripPress.twice("Something new") == .zoom)
    }

    /// AppKit's own answer, where it gives one, is one of the four, and
    /// it is what a double-click on the strip goes by.
    @Test func aDoubleClickAsksWhatTheTitleBarWouldDo() {
        if let asked = StripPress.titleBar {
            #expect(StripPress.now == asked)
        } else {
            #expect(StripPress.now == StripPress.twice(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")))
        }
    }

    @Test func aTaughtWindowIsMovableWithNoBandOfItsOwn() throws {
        let window = Self.fresh()
        defer { window.close() }
        window.isMovableByWindowBackground = true
        // AppKit's own band, before: a movable window has one.
        #expect(try !#require(WindowDrag.shape(of: window)).isEmpty)
        WindowDrag.keep(window)
        #expect(window.isMovable)
        #expect(!window.isMovableByWindowBackground)
        #expect(WindowDrag.taught(window))
        #expect(try #require(WindowDrag.shape(of: window)).isEmpty)
    }

    @Test func onlyTheTaughtClassIsTaught() throws {
        let taught = Self.ours(), other = Self.other(), plain = Self.plain()
        defer { [taught, other, plain].forEach { $0.close() } }
        WindowDrag.keep(taught)
        WindowDrag.keep(plain)
        // A plain NSWindow is everyone's: it keeps AppKit's band.
        #expect(plain.isMovable)
        #expect(!WindowDrag.taught(plain))
        #expect(try #require(WindowDrag.shape(of: plain)).height > 0)
        #expect(!WindowDrag.taught(other))
        #expect(try #require(WindowDrag.shape(of: other)).height > 0)
    }

    /// The press that brings a window from behind drags it from wherever
    /// it lands that AppKit may move it from, a tab across the top too: the
    /// window says it may not be moved while a press anywhere but a handle
    /// is handed out, and is movable again after it, for the menus.
    @Test func aPressOffTheHandlesFindsTheWindowStill() throws {
        let pressed = Pressed(contentRect: Self.frame, styleMask: Self.style, backing: .buffered, defer: true)
        let window = Self.dressed(pressed)
        defer { window.close() }
        WindowDrag.keep(window)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        content.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400)))
        content.addSubview(Grip(frame: NSRect(x: 300, y: 0, width: 300, height: 400)))
        window.contentView = content
        func send(_ type: NSEvent.EventType, at x: CGFloat) throws {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
        }
        // On the page, on a handle, and a drag, which is no press.
        try send(.leftMouseDown, at: 100)
        try send(.leftMouseDown, at: 450)
        try send(.leftMouseDragged, at: 100)
        #expect(pressed.heard == [false, true, true])
        #expect(window.isMovable)
    }
}
