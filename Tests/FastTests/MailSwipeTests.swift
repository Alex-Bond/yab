import AppKit
import SwiftUI
import Testing
@testable import Fast

@Suite(.serialized)
struct MailSwipeTests {
    @Test func backAndForwardOnlyOnRelease() {
        for sign: CGFloat in [1, -1] {
            var gesture = MailSwipe.Gesture()
            _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
            for n in 1...12 {
                let move = gesture.hear(x: sign * 10, y: 1, phase: .changed, time: Double(n) / 60)
                #expect(move.taken && move.step == nil)
            }
            #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.22).step == (sign > 0 ? -1 : 1))
            #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.23).step == nil)
            let glide = gesture.hear(x: sign * 200, y: 0, phase: [], momentum: .changed, time: 0.24)
            #expect(glide.taken && glide.step == nil)
        }
    }

    @Test func verticalGestureStaysVerticalEvenWhenItDriftsSideways() {
        var gesture = MailSwipe.Gesture()
        _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
        #expect(!gesture.hear(x: 2, y: 10, phase: .changed, time: 0.02).taken)
        #expect(!gesture.hear(x: 200, y: 0, phase: .changed, time: 0.04).taken)
        #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.06).step == nil)
    }

    @Test func columnOrOtherPaneKeepsItsGestureAfterMovingIntoMail() {
        var gesture = MailSwipe.Gesture()
        _ = gesture.hear(x: 0, y: 0, phase: .began, inside: false, time: 0)
        #expect(!gesture.hear(x: 200, y: 0, phase: .changed, time: 0.1).taken)
        #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.2).step == nil)
    }

    @Test func mailKeepsItsGestureOutsideThePaneButNotTheNextGesture() {
        var gesture = MailSwipe.Gesture()
        _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
        #expect(gesture.hear(x: 120, y: 0, phase: .changed, inside: false, time: 0.1).taken)
        #expect(gesture.hear(x: 0, y: 0, phase: .ended, inside: false, time: 0.2).step == -1)
        _ = gesture.hear(x: 0, y: 0, phase: .began, inside: false, time: 0.3)
        #expect(!gesture.hear(x: 120, y: 0, phase: .changed, time: 0.4).taken)
    }

    @Test func shortPullCancelAndReversalDoNotNavigate() {
        for ending: NSEvent.Phase in [.ended, .cancelled] {
            var gesture = MailSwipe.Gesture()
            _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
            _ = gesture.hear(x: 40, y: 0, phase: .changed, time: 0.1)
            #expect(gesture.hear(x: 0, y: 0, phase: ending, time: 0.2).step == nil)
        }
        var gesture = MailSwipe.Gesture()
        _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
        _ = gesture.hear(x: 140, y: 0, phase: .changed, time: 0.1)
        _ = gesture.hear(x: -40, y: 0, phase: .changed, time: 0.12)
        #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.14).step == nil)
        _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0.2)
        _ = gesture.hear(x: 140, y: 0, phase: .changed, time: 0.3)
        #expect(gesture.hear(x: 0, y: 0, phase: .cancelled, time: 0.32).step == nil)
    }

    @Test func quickFlickWorksButAPauseDisarmsAShortFlick() {
        for pause in [0.01, 0.1] {
            var gesture = MailSwipe.Gesture()
            _ = gesture.hear(x: 0, y: 0, phase: .began, time: 0)
            _ = gesture.hear(x: 20, y: 0, phase: .changed, time: 0.02)
            _ = gesture.hear(x: 50, y: 0, phase: .changed, time: 0.04)
            #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.04 + pause).step == (pause < 0.06 ? -1 : nil))
        }
    }

    @Test func mouseWheelAndMomentumAloneCannotNavigate() {
        var gesture = MailSwipe.Gesture()
        #expect(!gesture.hear(x: 200, y: 0, phase: [], precise: false, time: 0).taken)
        #expect(!gesture.hear(x: 200, y: 0, phase: [], momentum: .changed, time: 0.1).taken)
        #expect(gesture.hear(x: 0, y: 0, phase: .ended, time: 0.2).step == nil)
    }

    @MainActor @Test func nativePaneRoutesWheelEventsAndIgnoresOtherWindows() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 420, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let catchView = MailSwipe.Catch(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        window.contentView = catchView
        var steps: [Int] = []
        catchView.navigate = { steps.append($0) }
        defer { catchView.stop(); window.orderOut(nil) }
        #expect(catchView.heard(try wheel(window, x: 0, y: 0, phase: 1)) != nil)
        #expect(catchView.heard(try wheel(window, x: 120, y: 0, phase: 2)) == nil)
        #expect(catchView.heard(try wheel(window, x: 0, y: 0, phase: 4)) == nil)
        #expect(steps == [-1])
        _ = catchView.heard(try wheel(window, x: 0, y: 0, phase: 1))
        #expect(catchView.heard(try wheel(window, x: 1, y: 80, phase: 2)) != nil)
        #expect(catchView.heard(try wheel(window, x: 0, y: 0, phase: 4)) != nil)
        #expect(steps == [-1])
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        #expect(catchView.heard(try wheel(other, x: 150, y: 0, phase: 1)) != nil)
        #expect(steps == [-1])
        // Through AppKit's dispatch as well: the installed monitor must hear
        // the gesture, rather than testing its handler in isolation.
        let phases: [(Int64, Int32)] = [(1, 0), (2, -120), (4, 0)]
        for (phase, dx) in phases {
            NSApp.sendEvent(try wheel(window, x: dx, y: 0, phase: phase))
        }
        #expect(steps == [-1, 1])
    }

    @MainActor @Test func openedThreadReturnsToListAndForwardReopensIt() async throws {
        let desk = MailDesk.shared
        desk.back()
        let host = NSHostingView(rootView: MailPane())
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 820, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func catcher(_ view: NSView) -> MailSwipe.Catch? {
            if let catchView = view as? MailSwipe.Catch { return catchView }
            return view.subviews.lazy.compactMap { catcher($0) }.first
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let view = catcher(host), view.bounds.width > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try #require(catcher(host))
        #expect(view.bounds.width > 0 && view.window === window)
        func swipe(_ x: Int32) throws {
            let phases: [(Int64, Int32)] = [(1, 0), (2, x), (4, 0)]
            for (phase, dx) in phases {
                NSApp.sendEvent(try wheel(window, x: dx, y: 0, phase: phase))
            }
        }
        let row = MailDesk.Row(account: "swipe-test", thread: "one", who: "Sender", whoFull: "Sender <sender@example.test>",
                               subject: "Swipe", line: "Body", at: Date(), unread: false, count: 1,
                               when: "", snoozed: false, scheduled: nil)
        desk.show(row, move: .cut)
        #expect(desk.screen == .thread && desk.open?.id == row.id)
        try swipe(120)
        #expect(desk.screen == .list && desk.open == nil)
        try swipe(-120)
        #expect(desk.screen == .thread && desk.open?.id == row.id)
        try swipe(120)
        #expect(desk.screen == .list)
    }

    @MainActor private func wheel(_ window: NSWindow, x: Int32, y: Int32, phase: Int64) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: y, wheel2: x, wheel3: 0))
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        typealias Place = @convention(c) (CGEvent, CGPoint) -> Void
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        unsafeBitCast(symbol, to: Place.self)(event, CGPoint(x: 100, y: 100))
        return try #require(NSEvent(cgEvent: event))
    }
}
