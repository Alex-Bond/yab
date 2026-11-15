import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor
struct ChromiumSwipeTests {
    @Test func appKitPhasesBecomeCoreGraphicsFields() {
        #expect(ChromiumWheelPhase.gesture([]) == 0)
        #expect(ChromiumWheelPhase.gesture(.mayBegin) == 128)
        #expect(ChromiumWheelPhase.gesture(.began) == 1)
        #expect(ChromiumWheelPhase.gesture(.changed) == 2)
        #expect(ChromiumWheelPhase.gesture(.ended) == 4)
        #expect(ChromiumWheelPhase.gesture(.cancelled) == 8)
        #expect(ChromiumWheelPhase.momentum(.began) == 1)
        #expect(ChromiumWheelPhase.momentum(.changed) == 2)
        #expect(ChromiumWheelPhase.momentum(.ended) == 3)
    }

    @Test func nativeWheelRoundTripPreservesGestureAndMomentum() throws {
        for (gesture, momentum) in [(128, 0), (1, 0), (2, 0), (4, 0), (8, 0), (0, 1), (0, 2), (0, 3)] {
            let input = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
            input.flags = []
            input.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(gesture))
            input.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
            let event = try #require(NSEvent(cgEvent: input))
            let output = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
            output.flags = []
            output.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(ChromiumWheelPhase.gesture(event.phase)))
            output.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(ChromiumWheelPhase.momentum(event.momentumPhase)))
            let forwarded = try #require(NSEvent(cgEvent: output))
            #expect(forwarded.phase == event.phase)
            #expect(forwarded.momentumPhase == event.momentumPhase)
        }
    }
    private func wheel(x: Int32 = 0, y: Int32 = 0, phase: Int64 = 2, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        cg.flags = []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func stalledHistoryDoesNotHoldAnyWheel() async throws {
        var pending: CheckedContinuation<ChromiumHistorySnapshot, Never>?
        var forwarded: [NSEvent] = []
        var reads = 0
        let swipe = ChromiumSwipe(nil, history: {
            reads += 1
            return await withCheckedContinuation { pending = $0 }
        }, wheel: { forwarded.append($0) })
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(x: 20, y: -5))
        for _ in 0..<100 where pending == nil { await Task.yield() }
        #expect(reads == 1)
        let reply = try #require(pending)
        swipe.receive(try wheel(y: -40))
        swipe.receive(try wheel(phase: 4))
        swipe.receive(try wheel(y: -20, phase: 0, momentum: 1))
        swipe.receive(try wheel(phase: 0, momentum: 3))
        #expect(forwarded.count == 6, "History must not delay changed, ended or momentum events")
        // A second gesture also goes through before the old history replies.
        swipe.receive(try wheel(phase: 1))
        #expect(forwarded.count == 7)
        let gesture = swipe.swipeGesture
        reply.resume(returning: try ChromiumHistorySnapshot(.object([
            "entries": .array([]), "currentIndex": .number(-1)])))
        for _ in 0..<10 { await Task.yield() }
        #expect(swipe.swipeGesture == gesture)
        #expect(!swipe.swipeSettled, "The old history must not spend the new gesture")
        swipe.receive(try wheel(y: -50))
        #expect(forwarded.count == 8)
        swipe.invalidate()
    }

    @Test(arguments: [false, true])
    func invalidationClosesTheForwardedGestureOnce(momentum: Bool) throws {
        var forwarded: [NSEvent] = []
        let swipe = ChromiumSwipe(nil, wheel: { forwarded.append($0) })
        swipe.receive(try wheel(y: -30, phase: momentum ? 0 : 1, momentum: momentum ? 1 : 0))
        swipe.invalidate()
        #expect(forwarded.count == 2)
        let terminal = try #require(forwarded.last)
        #expect(terminal.scrollingDeltaX == 0)
        #expect(terminal.scrollingDeltaY == 0)
        #expect(terminal.phase == (momentum ? [] : .cancelled))
        #expect(terminal.momentumPhase == (momentum ? .ended : []))
        swipe.invalidate()
        #expect(forwarded.count == 2)
        swipe.receive(try wheel(y: -20))
        swipe.receive(try wheel(phase: 4))
        swipe.receive(try wheel(y: -15, phase: 0, momentum: 1))
        #expect(forwarded.count == 2, "The interrupted tail must not relatch the old target")
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(y: -40))
        #expect(forwarded.count == 4, "A new vertical gesture must work without reload")
        swipe.invalidate()
    }

    @Test func releaseBeforeHistoryReplyStillReturnsToSource() async throws {
        let tab = Tab(shy: true, engine: .chromium)
        defer { tab.close() }
        let page = ChromiumPage(tab: tab)
        tab.fromTitle = { _ in "Source" }
        var returned = false
        tab.onFrom = { _ in returned = true }
        var pending: CheckedContinuation<ChromiumHistorySnapshot, Never>?
        let swipe = ChromiumSwipe(page, history: {
            await withCheckedContinuation { pending = $0 }
        }, wheel: { _ in }, evaluate: { _ in })
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(x: 20))
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let reply = try #require(pending)
        swipe.answer(free: true, gesture: swipe.swipeGesture)
        swipe.receive(try wheel(x: 400))
        swipe.receive(try wheel(phase: 4))
        swipe.answer(free: true, gesture: swipe.swipeGesture, finished: true)
        #expect(returned, "A history read must not gate the first native/source destination")
        reply.resume(returning: try ChromiumHistorySnapshot(.object([
            "entries": .array([]), "currentIndex": .number(-1)])))
        await Task.yield()
        swipe.invalidate()
    }

    @Test func firstPageSwipeUsesTheSharedBackAtStartCallback() throws {
        let tab = Tab(shy: true, engine: .chromium)
        defer { tab.close() }
        let page = ChromiumPage(tab: tab)
        tab.fromTitle = { _ in "Source" }
        tab.backSourceAvailable = true
        var returned = false
        tab.onBackAtStart = { _ in returned = true; return true }
        tab.onFrom = { _ in Issue.record("The shared Back callback already handled the source") }
        let list = PageNavigationList.immediate(page: page, tab: tab, back: true)
        list.take(try #require(list.stops.first))
        #expect(returned)
    }

    @Test func sourceDestinationDoesNotNeedAHistoryReply() async throws {
        let tab = Tab(shy: true, engine: .chromium)
        defer { tab.close() }
        let page = ChromiumPage(tab: tab)
        tab.fromTitle = { _ in "Source" }
        var returned = false
        tab.onFrom = { _ in returned = true }
        let list = PageNavigationList.immediate(page: page, tab: tab, back: true)
        #expect(list.stops.map(\.kind) == [.from])
        list.take(try #require(list.stops.first))
        #expect(returned)
        #expect(page.remoteID == nil)
        #expect(PageNavigationList.immediate(page: page, tab: tab, back: false).stops.isEmpty)
    }

    @Test func completedGestureNeedsNoExtraTerminalEvent() throws {
        var forwarded: [NSEvent] = []
        let swipe = ChromiumSwipe(nil, wheel: { forwarded.append($0) })
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(phase: 4))
        swipe.invalidate()
        #expect(forwarded.count == 2)
    }

    @Test func verticalGestureDoesNotReadHistory() throws {
        var reads = 0
        var count = 0
        let swipe = ChromiumSwipe(nil, history: {
            reads += 1
            throw CancellationError()
        }, wheel: { _ in count += 1 })
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(x: 1, y: -40))
        swipe.receive(try wheel(phase: 4))
        #expect(count == 3)
        #expect(reads == 0)
    }

    @Test func verticalAndMomentumWheelsHaveNoScriptBarrier() throws {
        var order: [String] = []
        let swipe = ChromiumSwipe(nil, wheel: { _ in order.append("wheel") },
            evaluate: { _ in order.append("script") })
        for event in [try wheel(phase: 128), try wheel(phase: 1),
                      try wheel(x: 1, y: -40), try wheel(x: 2, y: -30),
                      try wheel(phase: 4), try wheel(y: -20, phase: 0, momentum: 1),
                      try wheel(y: -10, phase: 0, momentum: 2),
                      try wheel(phase: 0, momentum: 3)] {
            swipe.receive(event)
        }
        #expect(order == Array(repeating: "wheel", count: 8))
    }

    @Test(arguments: [false, true])
    func sidewaysOwnershipStartsBeforeItsFirstWheel(beganWithDelta: Bool) throws {
        var order: [String] = []
        let swipe = ChromiumSwipe(nil, wheel: { _ in order.append("wheel") },
            evaluate: { source in
                if source.contains(".begin(") { order.append("begin") }
            })
        swipe.receive(try wheel(x: beganWithDelta ? 20 : 0, phase: 1))
        swipe.receive(try wheel(x: 20))
        swipe.receive(try wheel(x: 25))
        #expect(order == (beganWithDelta
            ? ["begin", "wheel", "wheel", "wheel"]
            : ["wheel", "begin", "wheel", "wheel"]))
        swipe.invalidate()
    }

    @Test func aNewVerticalGestureDoesNotRestartSidewaysObservation() throws {
        var scripts = 0
        let swipe = ChromiumSwipe(nil, wheel: { _ in }, evaluate: { _ in scripts += 1 })
        swipe.receive(try wheel(x: 20, phase: 1))
        swipe.receive(try wheel(phase: 4))
        let before = scripts
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(y: -40))
        swipe.receive(try wheel(x: 10, y: -1))
        swipe.receive(try wheel(phase: 4))
        #expect(scripts == before)
        swipe.invalidate()
    }

    @Test func historyDeadlineCannotHoldOrLaterArmTheGesture() async throws {
        var pending: CheckedContinuation<ChromiumHistorySnapshot, Never>?
        var count = 0
        let swipe = ChromiumSwipe(nil, history: {
            await withCheckedContinuation { pending = $0 }
        }, wheel: { _ in count += 1 })
        swipe.receive(try wheel(phase: 1))
        swipe.receive(try wheel(x: 20, y: -5))
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let reply = try #require(pending)
        try await Task.sleep(nanoseconds: 850_000_000)
        #expect(swipe.swipeSettled)
        swipe.receive(try wheel(y: -40))
        swipe.receive(try wheel(phase: 4))
        #expect(count == 4)
        reply.resume(returning: try ChromiumHistorySnapshot(.object([
            "entries": .array([]), "currentIndex": .number(-1)])))
        for _ in 0..<10 { await Task.yield() }
        #expect(swipe.swipeSettled)
        swipe.invalidate()
    }

}
