import AppKit
import ObjectiveC
import Testing
@testable import Fast

struct AwakeTests {
    @MainActor @Test func browserGlassStaysActiveWithoutPatchingOtherWindows() {
        _ = NSApplication.shared
        let selector = NSSelectorFromString("_hasActiveAppearance")
        let plain = class_getMethodImplementation(NSWindow.self, selector)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: true)
        Awake.keep(window)
        Awake.keep(window)
        typealias Appearance = @convention(c) (AnyObject, Selector) -> Bool
        let appearance = unsafeBitCast(window.method(for: selector), to: Appearance.self)
        #expect(!window.isKeyWindow)
        #expect(appearance(window, selector))
        #expect(class_getMethodImplementation(NSWindow.self, selector) == plain)

        let buttonSelector = NSSelectorFromString("_hasActiveAppearanceForStandardWindowButton:")
        typealias ButtonAppearance = @convention(c) (AnyObject, Selector, UInt) -> Bool
        let buttons = unsafeBitCast(window.method(for: buttonSelector), to: ButtonAppearance.self)
        #expect(!buttons(window, buttonSelector, 0))
    }
}
