import AppKit
import Testing
@testable import Fast

/// The actual stack timer and its actual child ActionMenu, with owned
/// offscreen windows and inert commands. No global input or Finder action.
@MainActor @Suite(.serialized)
struct HoardActionMenuTests {
    private final class Count { var value = 0 }
    private final class Command: NSObject {
        var run: () -> Void = {}
        @objc func take(_ sender: Any?) { run() }
    }

    private func world(_ check: (HoardStack, NSWindow, Command, NSMenu, Count) async throws -> Void) async throws {
        _ = NSApplication.shared
        try #require(NSEvent.pressedMouseButtons == 0, "fixture requires no global mouse button held")
        ActionMenu.close()
        let id = UUID(), browser = Browser(windowID: UUID())
        let hoard = browser.hoard
        hoard.pretend(name: "menu-owner.txt", from: "fixture.invalid", got: 1, total: 2)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let closed = Count()
        let stack = HoardStack(hoard: hoard, loot: browser.loot, browser: browser,
                               fits: { 4 }, heightChanged: { _ in })
        stack.present(over: window, from: NSRect(x: -30_000, y: -30_000, width: 28, height: 28),
                      left: -30_000, width: 220, held: true) { closed.value += 1 }
        let target = Command(), menu = NSMenu()
        menu.autoenablesItems = false
        let item = menu.addItem(withTitle: "Show in Finder", action: #selector(Command.take(_:)), keyEquivalent: "")
        item.target = target
        defer {
            ActionMenu.close()
            stack.dismiss()
            stack.close()
            hoard.forgetPretended()
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            if let windowID = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(windowID.uuidString).space")
            }
        }
        try await Task.sleep(for: .milliseconds(40))
        try #require(stack.isVisible && stack.phase.out, "fixture stack must have completed its opening turn")
        try #require(!NSScreen.screens.contains { $0.frame.intersects(stack.frame) }, "fixture must remain offscreen")
        print("HOARD_MENU_FIXTURE \(id) stack=\(stack.windowNumber) offscreen=true")
        try await check(stack, window, target, menu, closed)
    }

    @Test func ownMenuKeepsStackAcrossLeavingAndCommandDispatch() async throws {
        try await world { stack, _, target, menu, closed in
            ActionMenu.show(menu, in: stack, at: NSPoint(x: -30_000, y: -30_000), up: false)
            try #require(ActionMenu.isOpen(in: stack))
            stack.release()
            try await Task.sleep(for: .milliseconds(140))
            #expect(closed.value == 0, "the stack must not dismiss while its own menu is being used")
            #expect(stack.isVisible && stack.phase.out)
            var performed = false, ownerPresent = false
            target.run = {
                performed = true
                ownerPresent = closed.value == 0 && stack.phase.out
            }
            ActionMenu.bench(type: nil, take: "Show in Finder", key: nil)
            #expect(performed && ownerPresent, "the command keeps its original owner through menu dispatch")
            try await Task.sleep(for: .seconds(HoardStack.linger) + .milliseconds(240))
            #expect(closed.value == 1, "after the menu closes, ordinary pointer departure still dismisses")
        }
    }

    @Test func unrelatedMenuDoesNotHoldThisStack() async throws {
        try await world { stack, window, _, menu, closed in
            ActionMenu.show(menu, in: window, at: NSPoint(x: -30_000, y: -30_000), up: false)
            try #require(ActionMenu.isOpen(in: window) && !ActionMenu.isOpen(in: stack))
            stack.release()
            try await Task.sleep(for: .milliseconds(140))
            #expect(closed.value == 1)
            #expect(!stack.phase.out)
        }
    }

    @Test func aLocalMenuPressDoesNotDismissItsOwner() async throws {
        try await world { stack, _, _, menu, closed in
            ActionMenu.show(menu, in: stack, at: NSPoint(x: -30_000, y: -30_000), up: false)
            try await Task.sleep(for: .milliseconds(40))
            let state = ActionMenu.state()
            let lines = try #require(state["lines"] as? [[String: Any]])
            let line = try #require(lines.first { $0["title"] as? String == "Show in Finder" })
            let rect = try #require(line["rowFrame"] as? [CGFloat])
            try #require(rect.count == 4 && rect[2] > 0 && rect[3] > 0, "menu row must have real native layout")
            let number = try #require(state["window"] as? Int)
            let panel = try #require(NSApp.windows.first { $0.windowNumber == number })
            let point = CGPoint(x: rect[0] + rect[2] / 2, y: panel.frame.height - rect[1] - rect[3] / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
                #expect(closed.value == 0, "a press in the owned menu must not dismiss the underlying stack")
            }
        }
    }
}
