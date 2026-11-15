import AppKit
import ObjectiveC

// A browser window is movable, as every Mac window is: Window › Fill, Center
// and Move & Resize, the green button's menu, and the tiling a drag to the
// screen's edge does all ask the window whether it may be moved, and were
// grayed out or left out while it said no.
//
// What moves it is ours to say, though. AppKit moves a movable window whose
// title bar is see-through by the band a title bar would have, across its
// top, three ways: the window server drags it by a shape AppKit hands it,
// that band less the views in it that take a press, without asking the app;
// a press in the band that no view takes ends in the window's own
// mouseDown:, which drags it; and the press that brings a window from
// behind other apps' drags it from wherever in the band it lands, a tab
// too, before any view hears of it. The tabs across the top sit in that
// band, and a drag on a tab moved the window and never reached the tab. So
// the band is gone: the shape is empty, the window's mouseDown: drags
// nothing, and while a press anywhere but a handle is handed out the window
// says it may not be moved, which is what the third way asks. The strips
// (DragStrip) are the only handles, and hand their drags to the window
// server the way a title bar's go (NSWindow.performDrag(with:)), so the
// tiling at the screen's edges, the Option key's tiles and a tiled window
// pulled back to its own size come with them.
//
// The window is SwiftUI's, so it is its class that is taught, for itself
// only, as Awake teaches it to stay lit; a plain NSWindow is left alone, the
// lesson would reach every window in the app.
enum WindowDrag {
    private static var kept: Set<ObjectIdentifier> = []
    /// The window a press off the handles is being handed round in.
    private static weak var pressing: NSWindow?

    static func keep(_ window: NSWindow) {
        window.isMovable = true
        // The strips do the dragging, so the page underneath can't be
        // grabbed by accident while selecting text.
        window.isMovableByWindowBackground = false
        let cls: AnyClass = window.classForCoder
        guard cls != NSWindow.self, kept.insert(ObjectIdentifier(cls)).inserted else { return }
        // No shape for the window server to drag it by.
        if let method = rectangle(NSWindow.self) {
            let none: @convention(block) (NSWindow) -> NSRect = { _ in .zero }
            class_addMethod(cls, shape, imp_implementationWithBlock(none), method_getTypeEncoding(method))
        }
        // A press no view took goes on up, as from any other responder,
        // without the window's drag on the way.
        let pass: @convention(block) (NSWindow, NSEvent) -> Void = { window, event in
            window.nextResponder?.mouseDown(with: event)
        }
        class_addMethod(cls, #selector(NSResponder.mouseDown(with:)), imp_implementationWithBlock(pass), "v@:@")
        holdStill(cls)
    }

    /// Not movable, as AppKit asks it, while a press anywhere but a handle
    /// is handed out. Only the answer changes, not the setting: setting it
    /// tells the window server each time, and the menus and the tiling ask
    /// in between presses, when it is movable again.
    private static func holdStill(_ cls: AnyClass) {
        let movable = #selector(getter: NSWindow.isMovable)
        if let method = class_getInstanceMethod(cls, movable) {
            typealias Ask = @convention(c) (NSWindow, Selector) -> Bool
            let ask = unsafeBitCast(method_getImplementation(method), to: Ask.self)
            let answer: @convention(block) (NSWindow) -> Bool = { window in
                pressing !== window && ask(window, movable)
            }
            class_replaceMethod(cls, movable, imp_implementationWithBlock(answer), method_getTypeEncoding(method))
        }
        let send = #selector(NSWindow.sendEvent(_:))
        if let method = class_getInstanceMethod(cls, send) {
            typealias Send = @convention(c) (NSWindow, Selector, NSEvent) -> Void
            let pass = unsafeBitCast(method_getImplementation(method), to: Send.self)
            let handle: @convention(block) (NSWindow, NSEvent) -> Void = { window, event in
                guard event.type == .leftMouseDown, !onHandle(window, event) else { return pass(window, send, event) }
                let before = pressing
                pressing = window
                pass(window, send, event)
                pressing = before
            }
            class_replaceMethod(cls, send, imp_implementationWithBlock(handle), method_getTypeEncoding(method))
        }
    }

    /// The press lands on a handle, or on one of the lights, which keep the
    /// window as AppKit has it while they track the pointer: the green
    /// one's menu, held down, asks whether it may be moved.
    static func onHandle(_ window: NSWindow, _ event: NSEvent) -> Bool {
        guard let frame = window.contentView?.superview,
              let hit = frame.hitTest(event.locationInWindow) else { return false }
        return hit is WindowHandle || hit.superview is LightsRow
    }

    /// The window's class has been taught (for the bench and the tests).
    static func taught(_ window: NSWindow) -> Bool {
        kept.contains(ObjectIdentifier(window.classForCoder))
    }

    /// The shape the window server would drag the window by, empty once
    /// it has been taught. Nil where AppKit has no such shape to ask.
    static func shape(of window: NSWindow) -> NSRect? {
        guard let method = rectangle(type(of: window)) else { return nil }
        typealias Ask = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(method_getImplementation(method), to: Ask.self)(window, shape)
    }

    private static let shape = NSSelectorFromString("_draggableFrame")

    /// AppKit's private name for that shape, on a macOS where it still
    /// answers with a rectangle: one that changes it leaves the window as
    /// AppKit has it.
    private static func rectangle(_ cls: AnyClass) -> Method? {
        guard let method = class_getInstanceMethod(cls, shape),
              let types = method_getTypeEncoding(method),
              String(cString: types).hasPrefix("{CGRect=") else { return nil }
        return method
    }
}

/// A view the window is moved by (DragStrip's strips): a press on it is
/// the window's to move, whatever it lands in.
protocol WindowHandle: NSView {}

/// What a press on a strip comes to.
enum StripPress {
    /// A little slack, so a shaky click is still a click.
    static let slack: CGFloat = 3

    /// The press has gone far enough to be the window being moved.
    static func drags(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        abs(dx) >= slack || abs(dy) >= slack
    }

    /// What a double-click does, as on a title bar.
    enum Twice: Equatable { case zoom, fill, minimize, nothing }

    /// What a double-click on a title bar does now: AppKit's own answer, the
    /// one its title bars go by, and System Settings' word for it where
    /// AppKit has none to give.
    static var now: Twice {
        titleBar ?? twice(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }

    /// System Settings › Desktop & Dock, what double-clicking a title bar
    /// should do. Unset means the default, which zooms.
    static func twice(_ setting: String?) -> Twice {
        switch setting {
        case "Minimize": .minimize
        case "None": .nothing
        case "Fill": .fill
        default: .zoom
        }
    }

    /// AppKit's answer, from the flags its title bars read, on a macOS that
    /// has all three.
    static var titleBar: Twice? {
        func ask(_ name: String) -> Bool? {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(NSWindow.self, selector),
                  let types = method_getTypeEncoding(method), String(cString: types).hasPrefix("B") else { return nil }
            typealias Ask = @convention(c) (AnyClass, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: Ask.self)(NSWindow.self, selector)
        }
        guard let fill = ask("_shouldFillOnDoubleClick"), let zoom = ask("_shouldZoomOnDoubleClick"),
              let minimize = ask("_shouldMiniaturizeOnDoubleClick") else { return nil }
        return fill ? .fill : zoom ? .zoom : minimize ? .minimize : .nothing
    }

    /// Window › Fill's action, AppKit's own, which the window answers only
    /// on a macOS that has Fill.
    static let fill = NSSelectorFromString("_zoomFill:")

    /// A double-click on a title bar's empty room, done to `window`: what
    /// System Settings › Desktop & Dock says, as AppKit's title bars read it.
    @MainActor static func twice(_ window: NSWindow) {
        switch now {
        case .minimize: window.miniaturize(nil)
        case .nothing: break
        // Window › Fill, where macOS has it.
        case .fill where window.responds(to: fill):
            NSApp.sendAction(fill, to: window, from: nil)
        case .fill, .zoom: window.zoom(nil)
        }
    }
}
