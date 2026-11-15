import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct MailCodeTimerTests {
    @Test func foundationTickUpdatesRevisionSynchronously() throws {
        let state = MailCodeState()
        let timer = try #require(state.timer)
        defer { timer.invalidate() }
        let before = state.revision
        timer.fire()
        #expect(state.revision == before &+ 1)
        timer.fire()
        #expect(state.revision == before &+ 2)
    }

    @Test func scheduledTimerDoesNotRetainItsState() throws {
        var state: MailCodeState? = MailCodeState()
        weak var weakState = state
        let timer = try #require(state?.timer)
        defer { timer.invalidate() }
        state = nil
        #expect(weakState == nil)
        timer.fire()
    }
}
