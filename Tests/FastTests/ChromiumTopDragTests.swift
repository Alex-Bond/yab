import AppKit
import Testing
@testable import Fast

@MainActor
struct ChromiumTopDragTests {
    @Test func chromiumInstallsTheSameHeaderHitRulesAsWebKit() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        defer { tab.close() }
        let scripts = PageScripts.chromium(for: tab, .init(host: "example.com", css: ""))
        let top = scripts.first { $0.source == TopDragRelay.script.source }
        #expect(top?.world == .yab)
        #expect(top?.atEnd == true)
        #expect(top?.mainOnly == true)
        #expect(ChromiumScripts.featureRelays.contains(TopDragRelay.name))
    }

    @Test func heldPressRequiresHeaderHitAndPlainInput() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = view
        func event(_ y: CGFloat, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: y),
                modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        #expect(TopPress.holds(try event(380), in: view, grab: true, zoom: 1, at: CGPoint(x: 100, y: 20)) == TopPress.replaySupported)
        #expect(!TopPress.holds(try event(380), in: view, grab: false, zoom: 1))
        #expect(!TopPress.holds(try event(300), in: view, grab: true, zoom: 1, at: CGPoint(x: 100, y: 100)))
        #expect(TopPress.holds(try event(300), in: view, grab: true, zoom: 2, at: CGPoint(x: 50, y: 50)) == TopPress.replaySupported)
        let modifiers: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
        for flags in modifiers {
            #expect(!TopPress.holds(try event(380, flags: flags), in: view, grab: true, zoom: 1, at: CGPoint(x: 100, y: 20)))
        }
    }
}
