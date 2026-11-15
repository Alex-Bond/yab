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
    func eachPressOnTheSiteTogglesTheFieldAtOnce(strip: Bool) async throws {
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
        // Real composed AddressBar: empty room at every height is native
        // title bar, and its caption has the click-or-drag handle.
        for x: CGFloat in [160, 240, 560, 640] {
            for y: CGFloat in [3, 18, 33] {
                #expect(host.hitTest(CGPoint(x: x, y: y)) is DragStrip.Strip)
            }
        }
        #expect(host.hitTest(CGPoint(x: 400, y: 18)) is LinkFieldHandle.Handle)
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
        try click(1)
        #expect(!browser.editing && !browser.fieldShowing)
        // Presses as fast as a hand's, each counted on from the last as
        // AppKit counts them (2, 3, ...): every one toggles, as Arc's
        // address does its command bar, and none acts on the window.
        let frame = window.frame
        for count in 1...10 {
            try click(count)
            #expect(browser.fieldShowing == (count % 2 == 1), "press \(count)")
        }
        #expect(window.frame == frame)
    }
}
