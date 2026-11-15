import Testing
@testable import Fast

struct SignInOutputTests {
    private final class Attempt {
        let id = "connect.cursor"
    }

    @Test func currentLiveAttemptMayConsumeOutput() {
        let current = Attempt()
        #expect(Agents.acceptsSignInOutput(current, current: current, ending: false))
    }

    @Test func endingAttemptCannotConsumeQueuedOutput() {
        let ending = Attempt()
        #expect(!Agents.acceptsSignInOutput(ending, current: ending, ending: true))
        #expect(!Agents.acceptsSignInOutput(ending, current: nil, ending: true))
    }

    @Test func replacedOrRemovedAttemptCannotConsumeQueuedOutput() {
        let old = Attempt(), current = Attempt()
        #expect(old.id == current.id)
        #expect(!Agents.acceptsSignInOutput(old, current: current, ending: false))
        #expect(!Agents.acceptsSignInOutput(old, current: nil, ending: false))
        #expect(!Agents.acceptsSignInOutput(old, current: current, ending: true))
        #expect(Agents.acceptsSignInOutput(current, current: current, ending: false))
    }
}
