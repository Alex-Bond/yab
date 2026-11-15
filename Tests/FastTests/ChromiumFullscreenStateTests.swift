import Testing
@testable import Fast

struct ChromiumFullscreenStateTests {
    @Test func lastRequestDuringEntryWinsWithoutConflictingToggle() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action1 = session.next(visible: true)
        #expect(action1 == .enter)
        session.request(false)
        let action2 = session.next(visible: true)
        #expect(action2 == .none)
        session.request(true)
        let action3 = session.next(visible: true)
        #expect(action3 == .none)
        session.entered()
        let action4 = session.next(visible: true)
        #expect(action4 == .none)
        #expect(session.phase == .fullscreen && session.requested)
    }

    @Test func aNewRequestWhileReturningIsRetainedUntilNativeExitCompletes() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action5 = session.next(visible: true)
        #expect(action5 == .enter)
        session.entered()
        session.request(false)
        let action6 = session.next(visible: true)
        #expect(action6 == .exit)
        session.request(true)
        let action7 = session.next(visible: true)
        #expect(action7 == .none)
        // Our will-exit callback must not erase the newer renderer request.
        let asked8 = session.windowAskedToExit()
        #expect(!asked8)
        #expect(session.requested)
        session.exited()
        let action9 = session.next(visible: true)
        #expect(action9 == .enter)
        session.entered()
        let action10 = session.next(visible: true)
        #expect(action10 == .none)
        #expect(session.phase == .fullscreen)
    }

    @Test func anExitDuringEntryIsPerformedOnceAfterCompletion() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action11 = session.next(visible: true)
        #expect(action11 == .enter)
        session.request(false)
        let action12 = session.next(visible: true)
        #expect(action12 == .none)
        session.entered()
        let action13 = session.next(visible: true)
        #expect(action13 == .exit)
        let action14 = session.next(visible: true)
        #expect(action14 == .none)
        session.exited()
        let action15 = session.next(visible: true)
        #expect(action15 == .returnPage)
        let action16 = session.next(visible: true)
        #expect(action16 == .none)
    }

    @Test func nativeWindowExitRequestsChromiumExitOnlyOnce() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action17 = session.next(visible: true)
        #expect(action17 == .enter)
        session.entered()
        let asked18 = session.windowAskedToExit()
        #expect(asked18)
        let asked19 = session.windowAskedToExit()
        #expect(!asked19)
        #expect(!session.requested)
        session.exited()
        let action20 = session.next(visible: true)
        #expect(action20 == .returnPage)
    }

    @Test func anAlreadyFullscreenBrowserIsBorrowedAndNeverToggled() {
        var session = ChromiumFullscreenState(ownsWindow: false)
        let action21 = session.next(visible: true)
        #expect(action21 == .none)
        session.request(false)
        let action22 = session.next(visible: false)
        #expect(action22 == .returnPage)
        #expect(session.phase == .finished)
    }

    @Test func visibilityWaitCanBeCancelledAndCannotResurrectAfterReturn() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action23 = session.next(visible: false)
        #expect(action23 == .none)
        session.request(false)
        let action24 = session.next(visible: false)
        #expect(action24 == .returnPage)
        session.request(true)
        session.entered()
        session.exited()
        let action25 = session.next(visible: true)
        #expect(action25 == .none)
    }

    @Test func failedEntryReturnsWithoutARepeatedAttempt() {
        var session = ChromiumFullscreenState(ownsWindow: true)
        let action26 = session.next(visible: true)
        #expect(action26 == .enter)
        session.failedToEnter()
        let action27 = session.next(visible: true)
        #expect(action27 == .returnPage)
        let action28 = session.next(visible: true)
        #expect(action28 == .none)
    }
}
