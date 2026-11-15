import AppKit
import Testing
@testable import Fast

@MainActor
struct BenchKeyEventTests {
    private final class Window: NSWindow {
        var events: [NSEvent] = []
        override func sendEvent(_ event: NSEvent) { events.append(event) }
    }

    private final class Actions: NSObject {
        var last = ""
        @objc func undo(_ sender: Any?) { last = "undo" }
        @objc func redo(_ sender: Any?) { last = "redo" }
    }

    @Test(arguments: [false, true])
    func shiftedCommandUsesTheCharactersOfARealKeypress(explicitShift: Bool) throws {
        let window = Window(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        Bench.send([.command, .shift], "z", nil, to: window, straight: true, native: true)
        let down = try #require(window.events.first { $0.type == .keyDown })
        // Its characters are what the layout picked types (я on a non-Latin layout),
        // so only how Yab reads the key is asked here, and the menus below.
        #expect(Hotkey(down) == Hotkey("z", [.command, .shift]))
        #expect(down.modifierFlags.contains([.command, .shift]))

        let actions = Actions()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let undo = NSMenuItem(title: "Undo", action: #selector(Actions.undo(_:)), keyEquivalent: "z")
        undo.target = actions
        undo.keyEquivalentModifierMask = .command
        menu.addItem(undo)
        let redo = NSMenuItem(title: "Redo", action: #selector(Actions.redo(_:)), keyEquivalent: explicitShift ? "z" : "Z")
        redo.target = actions
        redo.keyEquivalentModifierMask = explicitShift ? [.command, .shift] : .command
        menu.addItem(redo)
        #expect(menu.performKeyEquivalent(with: down))
        #expect(actions.last == "redo")
    }
}
