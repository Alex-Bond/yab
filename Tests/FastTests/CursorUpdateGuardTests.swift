import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct CursorUpdateGuardTests {
    /// A safety fuse makes an unguarded baseline fail without crashing XCTest.
    private final class ReturnView: NSView {
        weak var target: NSView?
        var calls = 0
        var maximum = 0
        private var depth = 0
        override func cursorUpdate(with event: NSEvent) {
            calls += 1
            depth += 1
            maximum = max(maximum, depth)
            defer { depth -= 1 }
            NSCursor.pointingHand.set()
            if depth < 32 { target?.cursorUpdate(with: event) }
        }
    }

    private final class ForwardView: NSView {
        weak var target: ForwardView?
        var forwards = 0
        var maximum = 0
        private var depth = 0
        override func cursorUpdate(with event: NSEvent) {
            let forward = {
                self.forwards += 1
                self.depth += 1
                self.maximum = max(self.maximum, self.depth)
                defer { self.depth -= 1 }
                NSCursor.crosshair.set()
                if self.depth < 32 { self.target?.cursorUpdate(with: event) }
            }
            #if CURSOR_GUARD_BASELINE
            forward()
            #else
            CursorUpdateGuard.run(self, forward)
            #endif
        }
    }

    private func fixture(_ check: (NSWindow, ReturnView, NSEvent) throws -> Void) throws {
        _ = NSApplication.shared
        #if !CURSOR_GUARD_BASELINE
        CursorUpdateGuard.install()
        CursorUpdateGuard.install() // Installation must be idempotent.
        #endif
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 320, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = ReturnView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = root
        let cursor = NSCursor.current
        defer { root.target = nil; window.close(); cursor.set() }
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: NSPoint(x: 50, y: 50),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 0, userData: nil))
        try check(window, root, event)
    }

    @Test func inheritedViewCycleStopsAtOneForwardAndResetsForTheNextEvent() throws {
        try fixture { _, root, event in
            let view = NSView(frame: root.bounds)
            root.addSubview(view)
            view.nextResponder = root
            root.target = view
            NSCursor.arrow.set()
            view.cursorUpdate(with: event)
            #expect(root.calls == 1)
            #expect(root.maximum == 1)
            #expect(NSCursor.current == NSCursor.pointingHand)
            root.calls = 0
            view.cursorUpdate(with: event)
            #expect(root.calls == 1)
            print("CURSOR_PROOF inherited calls=\(root.calls) maximum=\(root.maximum)")
        }
    }

    @Test func deliberateTwoViewCycleStopsEachOverrideAtDepthOne() throws {
        try fixture { _, root, event in
            let first = ForwardView(frame: root.bounds)
            let second = ForwardView(frame: root.bounds)
            root.addSubview(first); root.addSubview(second)
            first.target = second; second.target = first
            first.nextResponder = second; second.nextResponder = first
            defer { first.nextResponder = root; second.nextResponder = root }
            first.cursorUpdate(with: event)
            #expect(first.forwards == 1 && second.forwards == 1)
            #expect(first.maximum == 1 && second.maximum == 1)
            #expect(NSCursor.current == NSCursor.crosshair)
            print("CURSOR_PROOF explicit forwards=\(first.forwards),\(second.forwards) maximum=\(first.maximum),\(second.maximum)")
        }
    }

    @Test func ordinaryResponderChainStillReachesTheCursorOwner() throws {
        try fixture { _, root, event in
            let outer = NSView(frame: root.bounds), inner = NSView(frame: root.bounds)
            root.addSubview(outer); outer.addSubview(inner)
            NSCursor.arrow.set()
            inner.cursorUpdate(with: event)
            #expect(root.calls == 1)
            #expect(NSCursor.current == NSCursor.pointingHand)
        }
    }

    @Test func sidebarHandleInHostingStackBoundsFallbackAndKeepsResizeCursor() throws {
        try fixture { window, root, event in
            let host = NSHostingView(rootView: AnyView(Color.clear))
            host.frame = root.bounds; root.addSubview(host)
            let handle = EdgeHandle.Handle(frame: root.bounds)
            host.addSubview(handle)
            handle.nextResponder = root
            root.target = handle
            handle.cursorUpdate(with: event)
            #expect(root.calls == 1 && root.maximum == 1)
            root.target = nil
            let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow,
                modifierFlags: [], timestamp: 1.5, windowNumber: window.windowNumber, context: nil,
                eventNumber: 6, clickCount: 0, pressure: 0))
            handle.mouseMoved(with: moved)
            for vertical in [false, true] {
                handle.vertical = vertical
                let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 40, y: 40),
                    modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 1))
                let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 50, y: 50),
                    modifierFlags: [], timestamp: 3, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 3, clickCount: 1, pressure: 1))
                handle.mouseDown(with: down); handle.mouseDragged(with: drag)
                NSCursor.arrow.set()
                handle.cursorUpdate(with: event)
                #expect(NSCursor.current == (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight))
                handle.mouseUp(with: drag)
            }
            handle.stopWatching()
        }
    }

    @Test func captureOverlayWithHostingControlsBoundsItsFallback() throws {
        try fixture { window, root, event in
            let id = UUID()
            let browser = Browser(windowID: id)
            let capture = Capture(browser)
            let host = NSHostingView(rootView: AnyView(Color.clear))
            host.frame = root.bounds; root.addSubview(host)
            let room = CaptureRoom(frame: root.bounds)
            host.addSubview(room)
            let view = CaptureView(capture: capture, frame: root.bounds)
            room.addSubview(view)
            view.pick(page: root.bounds, model: capture.model)
            view.layoutSubtreeIfNeeded()
            view.nextResponder = root; root.target = view
            defer {
                view.rest()
                browser.everyTab.forEach { $0.close() }
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
            view.cursorUpdate(with: event)
            #expect(root.calls == 1 && root.maximum == 1)
            #expect(NSCursor.current == NSCursor.pointingHand)
            let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow,
                modifierFlags: [], timestamp: 4, windowNumber: window.windowNumber, context: nil,
                eventNumber: 4, clickCount: 0, pressure: 0))
            view.mouseMoved(with: moved)
            #expect(root.calls == 1)
        }
    }

    /// A lower sibling whose hit test answers with a view outside its own
    /// subtree, as SwiftUI's PlatformViewHost did in crashes #66-#100. The
    /// fuse stops answering after 32 tests so an unguarded baseline fails.
    private final class StaleHit: NSView {
        weak var hit: NSView?
        var tests = 0
        override func hitTest(_ point: NSPoint) -> NSView? {
            tests += 1
            return tests <= 32 ? hit : nil
        }
    }

    /// The crash's own route (row 1065): no nextResponder edited. AppKit's
    /// -[NSView _nextResponderForEvent:] hands cursorUpdate to the sibling
    /// under a view, the sibling's hit test lands back inside a hosting
    /// view above it, and NSHostingView.cursorUpdate(with:) calls super,
    /// round and round until the stack guard faults.
    @Test func siblingHitTestCycleThroughHostingViewStopsAfterOnePass() throws {
        try fixture { _, root, event in
            let container = NSView(frame: root.bounds)
            root.addSubview(container)
            let stale = StaleHit(frame: container.bounds)
            container.addSubview(stale)
            let top = NSView(frame: container.bounds)
            container.addSubview(top)
            let host = NSHostingView(rootView: AnyView(Color.clear))
            host.frame = top.bounds
            top.addSubview(host)
            let leaf = NSView(frame: host.bounds)
            host.addSubview(leaf)
            stale.hit = leaf
            leaf.cursorUpdate(with: event)
            print("CURSOR_PROOF sibling hitTests=\(stale.tests)")
            #expect(stale.tests == 1)
        }
    }

    #if !CURSOR_GUARD_BASELINE
    @Test func deviceGripInNestedHostingKeepsItsCursorAndHover() throws {
        try fixture { window, root, event in
            let host = NSHostingView(rootView: AnyView(Color.clear))
            host.frame = root.bounds; root.addSubview(host)
            let grip = GripArea.Area(frame: root.bounds)
            host.addSubview(grip)
            var hovered = false
            grip.hover = { hovered = $0 }
            grip.cursor = .resizeLeftRight
            grip.updateTrackingAreas()
            #expect(grip.trackingAreas.allSatisfy { ($0.owner as? NSView) === grip })
            for _ in 0..<3 {
                NSCursor.arrow.set()
                grip.cursorUpdate(with: event)
                #expect(NSCursor.current == NSCursor.resizeLeftRight)
            }
            let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: event.locationInWindow,
                modifierFlags: [], timestamp: 5, windowNumber: window.windowNumber, context: nil,
                eventNumber: 5, trackingNumber: 0, userData: nil))
            grip.mouseEntered(with: entered)
            #expect(hovered)
            grip.mouseExited(with: entered)
            #expect(!hovered)
            let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow,
                modifierFlags: [], timestamp: 6, windowNumber: window.windowNumber, context: nil,
                eventNumber: 7, clickCount: 0, pressure: 0))
            grip.mouseMoved(with: moved)
            #expect(NSCursor.current == NSCursor.resizeLeftRight)
        }
    }

    @Test func blockedReentryDoesNotPoisonTheNextCall() throws {
        try fixture { _, root, _ in
            var calls = 0
            var nestedRan = true
            let firstRan = CursorUpdateGuard.run(root) {
                calls += 1
                nestedRan = CursorUpdateGuard.run(root) { calls += 100 }
            }
            let nextRan = CursorUpdateGuard.run(root) { calls += 1 }
            #expect(firstRan)
            #expect(!nestedRan)
            #expect(nextRan)
            #expect(calls == 2)
        }
    }
    #endif
}
