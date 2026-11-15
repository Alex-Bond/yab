import AppKit
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct FloatHoverTests {
    private final class Hand: FloatHand {
        var pointerInside = true
        var scrubbing = false
        var keepOnHover = false
        override var pointerIsInside: Bool { pointerInside }
        override var engaged: Bool { scrubbing }
        override var staysOnHover: Bool { keepOnHover }
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: type, location: NSPoint(x: 150, y: 100), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    private func scroll(_ phase: CGScrollPhase) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return try #require(NSEvent(cgEvent: event))
    }

    private func windowed(_ hand: Hand) -> NSWindow {
        let window = NSWindow(contentRect: hand.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hand
        return window
    }

    private func goes(_ hand: Hand) async throws {
        let deadline = Date().addingTimeInterval(3)
        while hand.near || hand.waiting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!hand.near)
        #expect(!hand.waiting)
    }

    /// A two-finger click rests its fingers first, and the menu it opens
    /// takes the end of that touch: the window must not wait for it.
    @Test func restingFingersKeepNoGestureOpen() async throws {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = windowed(hand)
        defer { hand.stopWatching(); window.close() }
        hand.keepOnHover = true
        hand.mouseEntered(with: try crossing(.mouseEntered))
        hand.scrollWheel(with: try scroll(.mayBegin))
        hand.pointerInside = false
        try await goes(hand)
    }

    @Test func aMenuEndsTheGestureItInterrupted() async throws {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = windowed(hand)
        defer { hand.stopWatching(); hand.menuClosed(); window.close() }
        hand.keepOnHover = true
        hand.mouseEntered(with: try crossing(.mouseEntered))
        // Picked up mid-gesture: nothing but its end would close it.
        hand.scrollWheel(with: try scroll(.changed))
        hand.pointerInside = false
        try await Task.sleep(for: .milliseconds(320))
        #expect(hand.near)
        hand.menuClosed()
        try await goes(hand)
    }

    @Test func trackingAreaSurvivesLayoutAndResize() throws {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        hand.updateTrackingAreas()
        let area = try #require(hand.trackingAreas.first)
        #expect(area.options.contains(.inVisibleRect))
        #expect(area.options.contains(.activeAlways))
        for width in [CGFloat(320), 400, 300] {
            hand.setFrameSize(NSSize(width: width, height: 200))
            hand.layoutSubtreeIfNeeded()
            hand.updateTrackingAreas()
            #expect(hand.trackingAreas.count == 1)
            #expect(hand.trackingAreas.first === area)
        }
    }

    @Test func childAndTrackingExitsDoNotHideControlsOrMoveTheirFrames() throws {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        defer { hand.stopWatching() }
        let button = NSButton(frame: NSRect(x: 100, y: 70, width: 40, height: 40))
        hand.addSubview(button)
        let frame = hand.frame, buttonFrame = button.frame
        var changes: [Bool] = []
        hand.onNear = { changes.append($0) }
        hand.mouseEntered(with: try crossing(.mouseEntered))
        for _ in 0..<20 {
            hand.updateTrackingAreas()
            hand.mouseExited(with: try crossing(.mouseExited))
            hand.mouseEntered(with: try crossing(.mouseEntered))
        }
        #expect(changes == [true])
        #expect(hand.near)
        #expect(hand.waiting)
        #expect(hand.frame == frame)
        #expect(button.frame == buttonFrame)

        hand.pointerInside = false
        hand.mouseExited(with: try crossing(.mouseExited))
        #expect(changes == [true, false])
        #expect(!hand.near)
        #expect(!hand.waiting)

        hand.pointerInside = true
        hand.mouseEntered(with: try crossing(.mouseEntered))
        #expect(changes == [true, false, true])
        #expect(hand.waiting)
    }

    @Test func videoHoverOutlastsIdleWhileCallsStillRest() async throws {
        _ = NSApplication.shared
        let video = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let call = Hand(frame: video.frame)
        defer { video.stopWatching(); call.stopWatching() }
        video.keepOnHover = true
        video.mouseEntered(with: try crossing(.mouseEntered))
        call.mouseEntered(with: try crossing(.mouseEntered))
        try await Task.sleep(for: .seconds(FloatHand.patience + 0.4))
        #expect(video.near)
        #expect(video.waiting)
        #expect(!call.near)
        #expect(!call.waiting)

        // A lost exit must still be reconciled after the old idle deadline.
        video.pointerInside = false
        let deadline = Date().addingTimeInterval(3)
        while video.near, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!video.near)
        #expect(!video.waiting)
    }

    @Test func lostExitHidesControlsEvenInEventTrackingMode() {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        defer { hand.stopWatching() }
        hand.poke()
        #expect(hand.near)
        // A moved window lost its exit; only the real pointer reconciliation
        // can notice this. The person's pointer is replaced by fixture state.
        hand.pointerInside = false
        // The fallback looks every 0.15 s; the deadline only allows for a
        // main thread shared with the rest of a full test run.
        let deadline = Date().addingTimeInterval(3)
        while hand.near, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        #expect(!hand.near)
        #expect(!hand.waiting)
    }

    @Test func busyControlsKeepTheirFallbackUntilRelease() async throws {
        _ = NSApplication.shared
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        defer { hand.stopWatching() }
        hand.scrubbing = true
        hand.poke()
        hand.pointerInside = false
        try await Task.sleep(for: .milliseconds(320))
        #expect(hand.near)
        #expect(hand.waiting)
        hand.scrubbing = false
        // Gone at the next look (0.15 s), or a little later on a main
        // thread shared with the rest of a full test run.
        let deadline = Date().addingTimeInterval(3)
        while hand.near || hand.waiting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!hand.near)
        #expect(!hand.waiting)
    }
}
