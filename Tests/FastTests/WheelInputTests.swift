import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct WheelInputTests {
    private func wheel(precise: Bool = false, phase: Int64 = 0, momentum: Int64 = 0,
                       x: Int32 = 0, y: Int32 = -1, flags: CGEventFlags = []) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.flags = flags
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func phaselessWheelsAreNeverGestures() throws {
        let modifiers: [CGEventFlags] = [[], .maskShift, .maskCommand, .maskControl]
        let deltas: [(Int32, Int32)] = [(0, -1), (1, 0), (3, -2), (0, 0)]
        for precise in [false, true] {
            for flags in modifiers {
                for delta in deltas {
                    let event = try wheel(precise: precise, x: delta.0, y: delta.1, flags: flags)
                    try #require(event.hasPreciseScrollingDeltas == precise)
                    try #require(event.phase == [] && event.momentumPhase == [])
                    #expect(!Swipe.isGesture(event))
                }
            }
        }
    }

    @Test func gesturesNeedPreciseDeltasAndPhases() throws {
        let phases: [Int64] = [1, 2, 4, 8, 128]
        let momentums: [Int64] = [1, 2, 3]
        for precise in [false, true] {
            for phase in phases {
                let event = try wheel(precise: precise, phase: phase)
                try #require(event.phase != [])
                #expect(Swipe.isGesture(event) == precise)
            }
            for momentum in momentums {
                let event = try wheel(precise: precise, momentum: momentum)
                try #require(event.momentumPhase != [])
                #expect(Swipe.isGesture(event) == precise)
            }
        }
    }

    @Test func otherEventsAreNotScrollGestures() throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        #expect(!Swipe.isGesture(event))
    }

    @Test func historyRequiresLivePrecisePhasesAndSystemPermission() throws {
        for precise in [false, true] {
            for phase: Int64 in [0, 1, 2, 4, 8, 128] {
                for momentum: Int64 in [0, 1, 2, 3] {
                    let event = try wheel(precise: precise, phase: phase, momentum: momentum, x: 140, y: 0)
                    #expect(!Swipe.isNavigationGesture(event, enabled: false))
                    #expect(Swipe.isNavigationGesture(event, enabled: true)
                        == (precise && phase != 0 && momentum == 0))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func horizontalWheelsNeverNavigate(precise: Bool) throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        defer { web.cancelSwipe() }
        var navigations = 0
        var pulls = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.onPull = { if $0 != nil { pulls += 1 } }
        let gesture = web.swipeGesture
        for direction: Int32 in [-1, 1] {
            for _ in 0..<10 {
                web.scrollWheel(with: try wheel(precise: precise, x: 140 * direction, y: 0))
                web.answer(free: true, gesture: web.swipeGesture, finished: true)
            }
        }
        #expect(web.swipeGesture == gesture)
        #expect(navigations == 0)
        #expect(pulls == 0)
    }

    @Test func momentumOnlyNeverStartsHistoryGesture() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        defer { web.cancelSwipe() }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        let gesture = web.swipeGesture
        for momentum: Int64 in [1, 2, 3] {
            web.scrollWheel(with: try wheel(precise: true, momentum: momentum, x: 140, y: 0))
        }
        web.answer(free: true, gesture: gesture, finished: true)
        #expect(web.swipeGesture == gesture)
        #expect(navigations == 0)
    }

    @Test(arguments: [false, true])
    func systemPermissionControlsTrackpadHistory(enabled: Bool) throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { enabled }
        defer { web.cancelSwipe() }
        var navigations = 0
        var pulls = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.onPull = { if $0 != nil { pulls += 1 } }
        web.scrollWheel(with: try wheel(precise: true, phase: 1, y: 0))
        web.scrollWheel(with: try wheel(precise: true, phase: 2, x: 140, y: 0))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(precise: true, phase: 4, y: 0))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(navigations == (enabled ? 1 : 0))
        #expect(enabled || pulls == 0)
    }

    @Test func disablingSystemPermissionInvalidatesPendingNavigation() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        var enabled = true
        web.swipeTrackingEnabled = { enabled }
        defer { web.cancelSwipe() }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        web.scrollWheel(with: try wheel(precise: true, phase: 1, y: 0))
        web.scrollWheel(with: try wheel(precise: true, phase: 2, x: 140, y: 0))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(precise: true, phase: 4, y: 0))
        let gesture = web.swipeGesture
        enabled = false
        web.answer(free: true, gesture: gesture, finished: true)
        #expect(navigations == 0)
        #expect(web.swipeSettled)
        enabled = true
        web.answer(free: true, gesture: gesture, finished: true)
        #expect(navigations == 0)
    }

    @Test func notchesStillReachAndAreTakenByTheGlide() throws {
        try #require(WheelGlide.on, "Run with smooth scrolling enabled")
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Run with Reduce Motion off")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        window.contentView = web
        defer {
            web.glide.stop()
            web.cancelSwipe()
            WheelLatch.release(in: web)
            window.close()
        }
        let notch = try wheel()
        #expect(!Swipe.isGesture(notch))
        #expect(web.glide.take(notch))
        #expect(web.glide.notches == 1)
        let smooth = try wheel(precise: true, y: -7)
        #expect(!Swipe.isGesture(smooth))
        #expect(!web.glide.take(smooth))
        web.scrollWheel(with: notch)
        #expect(web.glide.offered == 3)
        #expect(web.glide.notches == 2)
    }

    @Test func nonPrecisePhasesDoNotNavigateHistory() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        defer { web.cancelSwipe() }
        var navigations = 0
        web.fromTitle = { "Previous tab" }
        web.onFrom = { navigations += 1 }
        let gesture = web.swipeGesture
        web.scrollWheel(with: try wheel(phase: 1, y: 0))
        web.scrollWheel(with: try wheel(phase: 2, x: 140, y: 0))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(phase: 4, y: 0))
        web.answer(free: true, gesture: web.swipeGesture, finished: true)
        #expect(web.swipeGesture == gesture)
        #expect(navigations == 0)
        #expect(web.glide.offered == 3)
    }

    @Test func wheelsDoNotAddTravelToATrackpadSwipe() throws {
        for precise in [false, true] {
            let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
            web.swipeTrackingEnabled = { true }
            defer { web.cancelSwipe() }
            var navigations = 0
            web.fromTitle = { "Previous tab" }
            web.onFrom = { navigations += 1 }
            web.scrollWheel(with: try wheel(precise: true, phase: 1, y: 0))
            web.scrollWheel(with: try wheel(precise: true, phase: 2, x: 4, y: 0))
            let gesture = web.swipeGesture
            web.scrollWheel(with: try wheel(precise: precise, x: 140, y: 0))
            #expect(web.swipeGesture == gesture)
            web.scrollWheel(with: try wheel(precise: true, phase: 2, x: 4, y: 0))
            web.answer(free: true, gesture: gesture)
            web.scrollWheel(with: try wheel(precise: true, phase: 4, y: 0))
            web.answer(free: true, gesture: gesture, finished: true)
            #expect(navigations == 0)
        }
    }

    @Test func wheelsAfterBlockedTrackpadMomentumStillReachTheGlide() throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.swipeTrackingEnabled = { true }
        defer { web.cancelSwipe() }
        web.scrollWheel(with: try wheel(precise: true, phase: 1, y: 0))
        web.scrollWheel(with: try wheel(precise: true, phase: 2, x: 40, y: 0))
        web.answer(free: true, gesture: web.swipeGesture)
        web.scrollWheel(with: try wheel(precise: true, phase: 4, y: 0))
        web.scrollWheel(with: try wheel(precise: true, momentum: 1, x: 20, y: 0))
        let gesture = web.swipeGesture
        let offered = web.glide.offered
        var touches = 0
        web.onTouch = { touches += 1 }
        for precise in [false, true] {
            web.scrollWheel(with: try wheel(precise: precise))
        }
        #expect(touches == 2)
        #expect(web.swipeGesture == gesture)
        #expect(web.glide.offered == offered + 2)
    }

    @Test func aWheelEndsTheColumnsStaleMomentumState() throws {
        try #require(ColumnQuiet.quietMoves, "Run with the default YAB_SMOOTH_MOVED setting")
        let ended = try wheel(precise: true, phase: 4, y: 0)
        defer { ColumnQuiet.heard(ended) }
        for precise in [false, true] {
            ColumnQuiet.heard(try wheel(precise: true, momentum: 2))
            try #require(ColumnQuiet.gliding)
            ColumnQuiet.heard(try wheel(precise: precise))
            #expect(!ColumnQuiet.gliding)
        }
        ColumnQuiet.heard(try wheel(phase: 2))
        #expect(!ColumnQuiet.gliding)
        ColumnQuiet.heard(try wheel(precise: true, phase: 2))
        #expect(ColumnQuiet.gliding)
        ColumnQuiet.heard(ended)
        #expect(!ColumnQuiet.gliding)
    }
}
