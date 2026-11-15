import AppKit
import Testing
@testable import Fast

/// These exercise real panel ownership and responder lifetimes on a Mac
/// with a display. Synthetic events stay inside the fixture; the real
/// pointer and the system's Reduce Motion setting are never changed.
@Suite(.serialized)
@MainActor
struct FloatCarryTests {
    @MainActor
    private struct Fixture {
        let floating: Floater
        let page: NSView
        let panel: NSWindow
        let lip: NSView
        let area: NSRect
        let savedFrame: Any?

        func close() {
            floating.drop()
            panel.orderOut(nil)
            if let savedFrame { Store.settings.set(savedFrame, forKey: "float.frame") }
            else { Store.settings.removeObject(forKey: "float.frame") }
        }
    }

    private func state(_ floating: Floater) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            floating.bench(["action": "state", "settle": 0.0]) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func parkedFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX })
        let area = screen.visibleFrame
        try #require(area.width > 700 && area.height > 400)
        let savedFrame = Store.settings.object(forKey: "float.frame")
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let floating = Floater()
        var prepared = false
        defer {
            if !prepared {
                let panel = page.window
                floating.drop()
                panel?.orderOut(nil)
                if let savedFrame { Store.settings.set(savedFrame, forKey: "float.frame") }
                else { Store.settings.removeObject(forKey: "float.frame") }
            }
        }
        floating.lift(page, shape: CGSize(width: 440, height: 247))
        for _ in 0..<60 {
            if Floater.owns(page.window) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(page.window)
        panel.setFrame(NSRect(x: area.maxX - 132, y: area.midY - 123.5, width: 440, height: 247), display: false)
        floating.letGo()
        // Safari's spring is still by about 0.8 s.
        for _ in 0..<200 {
            let snapshot = await state(floating)
            if snapshot["tuck_fraction"] as? Double == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let parked = await state(floating)
        try #require(parked["tuck_fraction"] as? Double == 1)
        let lip = try #require(panel.contentView?.subviews.last)
        try #require(lip.className.contains("FloatLip"))
        prepared = true
        return Fixture(floating: floating, page: page, panel: panel, lip: lip, area: area, savedFrame: savedFrame)
    }

    private func mouse(_ type: NSEvent.EventType, on panel: NSWindow, at screenPoint: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: panel.convertPoint(fromScreen: screenPoint), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    @Test func carryContinuesAfterThePictureIsFullyRevealed() async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        let (floating, panel, lip) = (fixture.floating, fixture.panel, fixture.lip)
        let origin = panel.frame.origin
        let tab = FloatEdgeTab.tabFrame(in: try #require(panel.contentView).bounds, side: .right)
        let grab = panel.convertPoint(toScreen: NSPoint(x: tab.midX, y: tab.midY))
        lip.mouseDown(with: try mouse(.leftMouseDown, on: panel, at: grab))
        let dock = FloatPark.unparked(panel.frame, .right, in: fixture.area)

        // Cross the full-reveal point with the button still held.
        let first = NSPoint(x: grab.x + dock.x - origin.x - 60, y: grab.y)
        lip.mouseDragged(with: try mouse(.leftMouseDragged, on: panel, at: first))
        let revealed = await state(floating)
        #expect(revealed["tuck_fraction"] as? Double == 0)
        #expect(lip.window === panel)

        // Continue carrying after fraction reached zero. Removing the lip
        // at that point used to leave this event without a window.
        let second = NSPoint(x: first.x - 70, y: first.y + 20)
        lip.mouseDragged(with: try mouse(.leftMouseDragged, on: panel, at: second))
        #expect(abs(panel.frame.minX - (dock.x - 130)) < 0.01)
        #expect(abs(panel.frame.minY - (origin.y + 20)) < 0.01)
        #expect(lip.window === panel)
        #expect(fixture.page.frame.size == NSSize(width: 640, height: 360))

        lip.mouseUp(with: try mouse(.leftMouseUp, on: panel, at: second))
        #expect(lip.superview == nil)
        let released = await state(floating)
        #expect(released["lip"] as? Bool == false)
        #expect(released["tuck_fraction"] as? Double == 0)
    }

    @Test func shortInwardPullOfTabRestoresInsteadOfTuckingAgain() async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        let panel = fixture.panel, lip = fixture.lip
        let tab = FloatEdgeTab.tabFrame(in: try #require(panel.contentView).bounds, side: .right)
        let grab = panel.convertPoint(toScreen: NSPoint(x: tab.midX, y: tab.midY))
        lip.mouseDown(with: try mouse(.leftMouseDown, on: panel, at: grab))
        let pulled = NSPoint(x: grab.x - 60, y: grab.y)
        lip.mouseDragged(with: try mouse(.leftMouseDragged, on: panel, at: pulled))
        #expect(lip.window === panel)
        lip.mouseUp(with: try mouse(.leftMouseUp, on: panel, at: pulled))
        for _ in 0..<250 {
            if (await state(fixture.floating))["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = await state(fixture.floating)
        #expect(restored["parked"] as? String == "")
        #expect(restored["tuck_fraction"] as? Double == 0)
        #expect(restored["lip"] as? Bool == false)
    }

    @Test func heldCarryShowsTheSameEdgeLookWithoutStartingItsOwnMotion() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX })
        let area = screen.visibleFrame
        try #require(area.width > 700 && area.height > 400)
        let savedFrame = Store.settings.object(forKey: "float.frame")
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let floating = Floater()
        defer {
            let panel = page.window
            floating.drop()
            panel?.orderOut(nil)
            if let savedFrame { Store.settings.set(savedFrame, forKey: "float.frame") }
            else { Store.settings.removeObject(forKey: "float.frame") }
        }
        floating.lift(page, shape: CGSize(width: 440, height: 247))
        for _ in 0..<60 {
            if Floater.owns(page.window) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(page.window)
        let y = area.midY - 123.5
        panel.setFrame(NSRect(x: area.maxX - 456, y: y, width: 440, height: 247), display: false)

        func bench(_ request: [String: Any]) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                floating.bench(request.merging(["settle": 0.0]) { a, _ in a }) { continuation.resume(returning: $0) }
            }
        }
        // The hand's window `past` points over the right side.
        func carry(_ past: CGFloat) async -> [String: Any] {
            await bench(["action": "carry", "x": Double(area.maxX - 440 + past), "y": Double(y)])
        }
        func until(_ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
            for _ in 0..<300 {
                let now = await bench(["action": "state"])
                if done(now) { return now }
                try await Task.sleep(for: .milliseconds(10))
            }
            return await bench(["action": "state"])
        }

        // The hand keeps the position. The blur and tab use the same
        // progress as the spring, even before the button is released.
        for past in [CGFloat(200), 130, 90, 100] {
            let now = await carry(past)
            #expect(now["parked"] as? String == "")
            let progress = try #require(FloatPark.tuckProgress(panel.frame, in: [FloatPark.Screen(frame: screen.frame, visible: area)]))
            #expect(abs((now["tuck_fraction"] as? Double ?? -1) - Double(progress.fraction)) < 0.002)
            #expect(now["lip"] as? Bool == true)
            #expect(now["gliding"] as? Bool == false)
            #expect(abs(panel.frame.minX - (area.maxX - 440 + past)) < 0.5)
            if past == 200 { #expect((now["edge_tab_alpha"] as? Double ?? 0) > 0) }
        }
        var now: [String: Any]

        // Let go of under a third: the corner.
        _ = await bench(["action": "letgo"])
        _ = try await until { $0["gliding"] as? Bool == false }
        #expect(abs(panel.frame.minX - (area.maxX - 456)) < 0.5)

        // Taken behind and let go of there: it stays behind.
        _ = await carry(200)
        now = await bench(["action": "letgo"])
        now = try await until { $0["tuck_fraction"] as? Double == 1 }
        #expect(now["parked"] as? String == "right")
        #expect(abs(panel.frame.minX - (area.maxX - FloatEdgeTab.shown)) < 0.5)
        #expect(now["captions_hidden"] as? Bool == true)
    }

    @Test(arguments: [CGFloat(292), 440, 618])
    func mouseAndTwoFingersHaveTheSameLookAtTheSamePosition(width: CGFloat) async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        fixture.floating.untuck()
        for _ in 0..<250 {
            if (await state(fixture.floating))["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = fixture.panel
        let hand = try #require(panel.contentView?.subviews.compactMap { $0 as? FloatHand }.first)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: width, height: width / 2)), display: false)
        let shown = NSPoint(x: fixture.area.maxX - FloatPark.margin - panel.frame.width, y: panel.frame.minY)
        panel.setFrameOrigin(shown)
        let mouse = await withCheckedContinuation { continuation in
            fixture.floating.bench(["action": "carry", "x": Double(shown.x + 280), "y": Double(shown.y), "settle": 0.0]) {
                continuation.resume(returning: $0)
            }
        }
        #expect((mouse["edge_tab_alpha"] as? Double ?? 0) > 0)
        _ = await withCheckedContinuation { continuation in
            fixture.floating.bench(["action": "carry", "x": Double(shown.x), "y": Double(shown.y), "settle": 0.0]) {
                continuation.resume(returning: $0)
            }
        }
        hand.scrollWheel(with: try wheel(x: -280, phase: 1))
        let fingers = await state(fixture.floating)
        hand.scrollWheel(with: try wheel(x: 0, phase: 4))
        #expect(mouse["frame"] as? [Double] == fingers["frame"] as? [Double])
        #expect(mouse["tuck_look"] as? [Double] == fingers["tuck_look"] as? [Double])
        #expect(mouse["edge_tab_alpha"] as? Double == fingers["edge_tab_alpha"] as? Double)
    }

    @Test func aFullyTuckedLookKeepsTheMouseResponderUntilRelease() async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        fixture.floating.untuck()
        for _ in 0..<250 {
            if (await state(fixture.floating))["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = fixture.panel
        let hand = try #require(panel.contentView?.subviews.compactMap { $0 as? FloatHand }.first)
        let grab = panel.convertPoint(toScreen: NSPoint(x: 30, y: 140))
        hand.mouseDown(with: try mouse(.leftMouseDown, on: panel, at: grab))
        let hidden = fixture.area.maxX - FloatEdgeTab.shown
        let held = await withCheckedContinuation { continuation in
            fixture.floating.bench(["action": "carry", "x": Double(hidden), "y": Double(panel.frame.minY), "settle": 0.0]) {
                continuation.resume(returning: $0)
            }
        }
        #expect(held["tuck_fraction"] as? Double == 1)
        #expect(held["edge_tab_alpha"] as? Double == 1)
        #expect(held["gliding"] as? Bool == false)
        #expect(hand.isHidden == false)
        #expect(panel.firstResponder === hand)
        hand.mouseUp(with: try mouse(.leftMouseUp, on: panel, at: grab))
    }

    private func wheel(x: Int32, phase: Int64) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 2, wheel1: 0, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func swipeReleaseFinishesAnInterruptedRestore() async throws {
        // There is no return animation to interrupt with Reduce Motion on.
        // The carry regression above still runs under either preference.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        let (floating, panel, lip) = (fixture.floating, fixture.panel, fixture.lip)
        floating.untuck()
        #expect(floating.parked == nil)
        // The swipe begins before the first return frame. It stops the
        // glide, so its release must explicitly start the remaining reveal.
        lip.scrollWheel(with: try wheel(x: 80, phase: 1))
        #expect(lip.window === panel)
        lip.scrollWheel(with: try wheel(x: 0, phase: 4))
        // Safari's spring is still by about 0.8 s.
        for _ in 0..<200 {
            let snapshot = await state(floating)
            if snapshot["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = await state(floating)
        #expect(restored["lip"] as? Bool == false)
        #expect(restored["tuck_fraction"] as? Double == 0)
        let dock = FloatPark.unparked(panel.frame, .right, in: fixture.area)
        #expect(abs(panel.frame.minX - dock.x) < 0.01)
    }
    @Test func missingSwipeReleaseStillRestoresThePicture() async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        // Deliver a begin, then lose every subsequent event when the moving
        // panel leaves its original event target. No real events are posted.
        fixture.lip.scrollWheel(with: try wheel(x: 80, phase: 1))
        for _ in 0..<350 {
            let now = await state(fixture.floating)
            if now["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = await state(fixture.floating)
        #expect(restored["lip"] as? Bool == false)
        #expect(restored["tuck_fraction"] as? Double == 0)
        #expect(restored["gliding"] as? Bool == false)
    }

    @Test func fullInwardSwipeClearsTheTuckedState() async throws {
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        fixture.lip.scrollWheel(with: try wheel(x: 1000, phase: 1))
        fixture.lip.scrollWheel(with: try wheel(x: 0, phase: 4))
        for _ in 0..<250 {
            if (await state(fixture.floating))["lip"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = await state(fixture.floating)
        #expect(restored["parked"] as? String == "")
        #expect(restored["lip"] as? Bool == false)
        #expect(restored["tuck_fraction"] as? Double == 0)
    }

    @Test func unchangedScreenNotificationDoesNotCutTheRestore() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fixture = try await parkedFixture()
        defer { fixture.close() }
        fixture.floating.untuck()
        let before = await state(fixture.floating)
        try #require(before["gliding"] as? Bool == true)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let after = await state(fixture.floating)
        #expect(after["gliding"] as? Bool == true)
        #expect((after["tuck_fraction"] as? Double ?? 0) > 0)
    }

}
