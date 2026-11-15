import Testing
@testable import Fast

struct ChatMovementTests {
    @Test func closingBeforeTheOpeningFrameCancelsItsAuthority() throws {
        var state = ChatMovement()
        let first = state.request(open: true, current: false, moving: false)
        guard case .move(let generation) = first else { Issue.record("opening was not scheduled"); return }
        #expect(state.request(open: false, current: false, moving: true) == .cancelled)
        #expect(state.target == nil)
        #expect(!state.isCurrent(generation))
        let completed = state.complete(generation)
        #expect(!completed)
    }

    @Test func reopeningBeforeTheClosingFrameCancelsItsAuthority() {
        var state = ChatMovement()
        guard case .move(let generation) = state.request(open: false, current: true, moving: false) else {
            Issue.record("closing was not scheduled"); return
        }
        #expect(state.request(open: true, current: true, moving: true) == .cancelled)
        #expect(!state.isCurrent(generation))
    }

    @Test func oldCompletionCannotEndTheNewMovement() {
        var state = ChatMovement()
        guard case .move(let first) = state.request(open: true, current: false, moving: false) else {
            Issue.record("opening was not scheduled"); return
        }
        // The first frame applied; close now owns the motion away.
        guard case .move(let second) = state.request(open: false, current: true, moving: true) else {
            Issue.record("closing did not supersede opening"); return
        }
        let oldCompleted = state.complete(first)
        #expect(!oldCompleted)
        #expect(state.target == false)
        #expect(state.isCurrent(second))
        let currentCompleted = state.complete(second)
        #expect(currentCompleted)
        #expect(state.target == nil)
    }

    @Test func repeatedCloseIsIdempotentAndCanReleaseAnOrphanedHold() {
        var state = ChatMovement()
        #expect(state.request(open: false, current: false, moving: false) == .unchanged)
        #expect(state.request(open: false, current: false, moving: true) == .cancelled)
        #expect(state.request(open: false, current: false, moving: false) == .unchanged)
        guard case .move(let generation) = state.request(open: false, current: true, moving: false) else {
            Issue.record("closing was not scheduled"); return
        }
        #expect(state.request(open: false, current: true, moving: true) == .unchanged)
        #expect(state.isCurrent(generation))
    }
}
