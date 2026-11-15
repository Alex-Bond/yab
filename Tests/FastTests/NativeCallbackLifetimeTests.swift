import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct NativeCallbackLifetimeTests {
    private func mouse(_ type: NSEvent.EventType, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 50),
            modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    @Test func linkMonitorDeliversMovesSynchronouslyAndDoesNotOwnStatus() throws {
        _ = NSApplication.shared
        var status: LinkStatus? = LinkStatus()
        weak var weakStatus = status
        let url = URL(string: "https://example.test/a")!, tab = UUID()
        status?.pointed(at: url, in: tab, keys: [])
        #expect(status?.pointed == nil)
        for _ in 0..<100 {
            NSApp.sendEvent(try mouse(.mouseMoved))
            status?.pointed(at: url, in: tab, keys: [])
            #expect(status?.pointed?.url == url)
            status?.forget(tab)
        }
        status = nil
        #expect(weakStatus == nil)
        // AppKit can send another event after the owning window has gone.
        NSApp.sendEvent(try mouse(.mouseMoved))
    }

    @Test func gripDetachAndOwnerDeathLeaveLaterEventsAlone() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<100 {
            var grip: ColumnGrip? = ColumnGrip()
            weak var weakGrip = grip
            grip?.watch(true)
            grip?.state = .changed
            var cancelled = 0
            grip?.changed = { if $0.state == .cancelled { cancelled += 1 } }
            grip?.watch(false)
            grip?.watch(false)
            #expect(cancelled == 1)
            grip?.watch(true)
            grip = nil
            #expect(weakGrip == nil)
            NSApp.sendEvent(try mouse(.leftMouseUp, window: window))
        }
    }

    @Test func glanceMonitorsDoNotKeepTheirOwnerAfterBrowserTeardown() throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        defer {
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        for _ in 0..<30 {
            var glance: TabGlance? = TabGlance(browser)
            weak var weakGlance = glance
            NSApp.sendEvent(try mouse(.mouseMoved))
            glance = nil
            #expect(weakGlance == nil)
            NSApp.sendEvent(try mouse(.mouseMoved))
        }
    }
}
