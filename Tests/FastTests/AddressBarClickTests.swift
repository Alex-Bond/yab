import AppKit
import SwiftUI
import Testing
@testable import Fast

/// The real band's button, not the bench's direct call to Browser.edit().
/// This checks event ordering, not the reporter's click-to-frame latency.
@MainActor
@Suite(.serialized)
struct AddressBarClickTests {
    @Test(arguments: [false, true])
    func aSingleClickOpensTheFieldWithoutWaiting(strip: Bool) async throws {
        _ = NSApplication.shared
        let screen = try #require(TestScreen.screen)
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = (prefs.addressBar, prefs.fullURL)
        prefs.addressBar = true
        prefs.fullURL = false
        let tab = Tab()
        tab.restore(url: URL(string: "https://example.test/path")!, title: "Example")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let host = NSHostingView(rootView: AddressBar(browser: browser, tab: tab, peek: browser.peek,
                                                     strip: strip, height: 36, corner: 0)
            .frame(width: 800, height: 36))
        let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                                                  width: 800, height: 36),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            browser.editing = false
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tab.close()
            prefs.addressBar = old.0
            prefs.fullURL = old.1
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try #require(!browser.fieldShowing)
        let at = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        func click(_ count: Int) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }
        let request = browser.focusRequest
        try click(1)
        // No run-loop wait or second press may be needed to open the field.
        #expect(browser.editing && browser.fieldShowing)
        #expect(browser.typed == "example.test/path")
        #expect(browser.focusRequest == request + 1)
    }

    @Test func theSecondPressClosesTheFieldAndActsOnTheWindowOnce() throws {
        try withField { browser, window in
            var acted: [NSWindow] = []
            let clicks = AddressBarClick { acted.append($0) }
            defer { clicks.cancel() }
            let at = ProcessInfo.processInfo.systemUptime
            clicks.watch(try event(.leftMouseUp, window, at: at, count: 1), in: browser)
            #expect(browser.fieldShowing)
            #expect(acted.isEmpty)
            let request = browser.focusRequest
            #expect(try clicks.receive(event(.leftMouseDown, window, at: at + 0.01, count: 2)) == nil)
            #expect(!browser.editing && !browser.fieldShowing)
            #expect(browser.focusRequest == request)
            #expect(acted.count == 1 && acted.first === window)
            #expect(try clicks.receive(event(.leftMouseDragged, window, at: at + 0.02, count: 2)) == nil)
            #expect(try clicks.receive(event(.leftMouseUp, window, at: at + 0.03, count: 2)) == nil)
            let third = try event(.leftMouseDown, window, at: at + 0.04, count: 3)
            #expect(clicks.receive(third) === third)
            #expect(acted.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func dismissalOrAnotherFocusRequestCancelsThePair(refocus: Bool) throws {
        try withField { browser, window in
            var actions = 0
            let clicks = AddressBarClick { _ in actions += 1 }
            defer { clicks.cancel() }
            let at = ProcessInfo.processInfo.systemUptime
            clicks.watch(try event(.leftMouseUp, window, at: at, count: 1), in: browser)
            if refocus { browser.edit() } else { browser.dismiss() }
            let second = try event(.leftMouseDown, window, at: at + 0.01, count: 2)
            #expect(clicks.receive(second) === second)
            #expect(actions == 0)
            #expect(browser.editing == refocus)
        }
    }

    @Test func typingCancelsThePairAndKeepsTheField() throws {
        try withField { browser, window in
            var actions = 0
            let clicks = AddressBarClick { _ in actions += 1 }
            defer { clicks.cancel() }
            let at = ProcessInfo.processInfo.systemUptime
            clicks.watch(try event(.leftMouseUp, window, at: at, count: 1), in: browser)
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: at + 0.01, windowNumber: window.windowNumber, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            #expect(clicks.receive(key) === key)
            let second = try event(.leftMouseDown, window, at: at + 0.02, count: 2)
            #expect(clicks.receive(second) === second)
            #expect(browser.editing && browser.fieldShowing)
            #expect(actions == 0)
        }
    }

    @Test func aControlClickIsLeftForTheMenu() throws {
        try withField { browser, window in
            var actions = 0
            let clicks = AddressBarClick { _ in actions += 1 }
            defer { clicks.cancel() }
            let at = ProcessInfo.processInfo.systemUptime
            clicks.watch(try event(.leftMouseUp, window, at: at, count: 1), in: browser)
            let second = try event(.leftMouseDown, window, at: at + 0.01, count: 2, flags: .control)
            #expect(clicks.receive(second) === second)
            #expect(browser.editing && browser.fieldShowing)
            #expect(actions == 0)
        }
    }

    private func event(_ type: NSEvent.EventType, _ window: NSWindow,
                       at: TimeInterval, count: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 20), modifierFlags: flags,
            timestamp: at, windowNumber: window.windowNumber, context: nil, eventNumber: count,
            clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func withField(_ check: (Browser, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab()
        tab.restore(url: URL(string: "https://example.test/path")!, title: "Example")
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            browser.editing = false
            window.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tab.close()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        browser.edit()
        try check(browser, window)
    }
}
