import AppKit
import ObjectiveC

/// How many keys reached the end of a window's responder chain with nothing
/// to take them: each one is macOS's "can't do that" sound, NSBeep, played
/// from `noResponder(for: keyDown)`. NSBeep itself can't be watched from
/// outside, its one caller here can. Counted on a test run only, once the
/// bench asks (`page-keys`); a person's run never has it.
@MainActor
enum Beeps {
    private(set) static var count = 0
    private static var watching = false

    static func watch() {
        guard Store.testing, !watching else { return }
        watching = true
        let selector = #selector(NSResponder.noResponder(for:))
        // The window's own, or NSResponder's when it has none: either way
        // where a key nobody took ends up.
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let keyDown = #selector(NSResponder.keyDown(with:))
        let counting: @convention(block) (AnyObject, Selector) -> Void = { responder, asked in
            if asked == keyDown { MainActor.assumeIsolated { Beeps.count += 1 } }
            original(responder, selector, asked)
        }
        method_setImplementation(method, imp_implementationWithBlock(counting))
    }

    /// A key as the keyboard sends it: its code, what it types, and the
    /// flags AppKit gives it. Arrows carry function and numeric pad, Home,
    /// End and the page keys function: those are what send them to a web
    /// view's `performKeyEquivalent` before its `keyDown`.
    static func key(_ name: String) -> (code: UInt16, chars: String, flags: NSEvent.ModifierFlags)? {
        func function(_ value: Int) -> String { String(UnicodeScalar(UInt32(value))!) }
        switch name.lowercased() {
        case "left": return (123, function(NSLeftArrowFunctionKey), [.function, .numericPad])
        case "right": return (124, function(NSRightArrowFunctionKey), [.function, .numericPad])
        case "down": return (125, function(NSDownArrowFunctionKey), [.function, .numericPad])
        case "up": return (126, function(NSUpArrowFunctionKey), [.function, .numericPad])
        case "home": return (115, function(NSHomeFunctionKey), [.function])
        case "end": return (119, function(NSEndFunctionKey), [.function])
        case "pageup": return (116, function(NSPageUpFunctionKey), [.function])
        case "pagedown": return (121, function(NSPageDownFunctionKey), [.function])
        case "space": return (49, " ", [])
        // Next Tab, one of Yab's own: it still has to work.
        case "next-tab": return (30, "}", [.shift, .command])
        // A peek's Open as Tab and Open in Split View, as they are by default.
        case "peek-tab": return (31, "o", [.command])
        case "new-tab": return (17, "t", [.command])
        case "peek-split": return (31, "O", [.shift, .command])
        // Developer Tools, Chrome's ⌥⌘I.
        case "devtools": return (34, "i", [.option, .command])
        default:
            // F1 to F15, as a keyboard's fn row sends them: F12 is Developer Tools.
            guard let n = Int(name.dropFirst()), name.lowercased().hasPrefix("f"),
                  let code = KeyLayout.named.first(where: { $0.value == "f\(n)" })?.key else { return nil }
            return (code, function(NSF1FunctionKey + n - 1), [.function])
        }
    }
}
