import Foundation
import Testing
@testable import Fast

/// Get to Know with the agent's CLI signed out (#266): its tabs are out of
/// sight, so nothing of it may call for you in the corner, where Show
/// couldn't bring it forward (docs/get-to-know.md, The sealed session).
@MainActor
@Suite(.serialized)
struct KnowSignInTests {
    @Test func theCornerNeverCallsForATabOutOfSight() {
        let id = "know-signin-" + UUID().uuidString
        Agents.shared.benchTask(id, state: .signingIn)
        let session = Agents.shared.session(id)!
        session.sealed = true
        session.knowing = true
        defer { session.state = .stopped }

        let mine = Tab(bench: true)
        let sealed = Tab(bench: true)
        sealed.agent = id
        sealed.handoff = "Sign in to Claude"
        #expect(Agents.shared.sealed(sealed))
        #expect(!Agents.shared.sealed(mine))

        // Its sign-in page in the shut folder: no call.
        let tabs = [mine, sealed]
        #expect(Agents.waiting(among: tabs, active: mine.id) { Agents.shared.sealed($0) } == nil)

        // A task you can see asking still calls, as before.
        let seen = Tab(bench: true)
        seen.handoff = "Needs you"
        #expect(Agents.waiting(among: tabs + [seen], active: mine.id) { Agents.shared.sealed($0) } === seen)
        // Not for the tab in front.
        #expect(Agents.waiting(among: [mine, seen], active: seen.id) { _ in false } == nil)
    }
}
