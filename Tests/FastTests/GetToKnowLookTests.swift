import Foundation
import Testing
@testable import Fast

// Daily Suggestions' morning look and Get to Know (docs/get-to-know.md):
// the look waits while Get to Know is at work, and its first one comes as
// Get to Know ends.
@MainActor
struct GetToKnowLookTests {
    static func session(_ id: String, knowing: Bool = false, quiet: Bool = false, state: Agents.State = .running) -> Agents.Session {
        let session = Agents.Session(id: id, cli: "claude", name: "Claude Code", prompt: "", state: state)
        session.knowing = knowing
        session.quiet = quiet
        return session
    }

    @Test func theLookWaitsWhileGetToKnowIsAtWork() {
        #expect(Agents.lookWaits(for: [Self.session("k", knowing: true)]))
        #expect(Agents.lookWaits(for: [Self.session("task"), Self.session("k", knowing: true, state: .waiting)]))
        #expect(Agents.lookWaits(for: [Self.session("k", knowing: true, state: .starting)]))
    }

    @Test func theLookDoesNotWaitForAnythingElse() {
        #expect(!Agents.lookWaits(for: []))
        #expect(!Agents.lookWaits(for: [Self.session("task")]))
        // The profile from memory: knowing too, but one of Yab's quiet passes.
        #expect(!Agents.lookWaits(for: [Self.session("profile", knowing: true, quiet: true)]))
        // Get to Know over, however it ended.
        for state in [Agents.State.done, .failed, .stopped] {
            #expect(!Agents.lookWaits(for: [Self.session("k", knowing: true, state: state)]))
        }
        // Only a run of its own counts, never a task's helper.
        let helper = Self.session("sub", knowing: true)
        helper.parent = "task"
        #expect(!Agents.lookWaits(for: [helper]))
    }

    @Test func theFirstLookComesAsGetToKnowEnds() {
        for state in [Agents.State.done, .failed, .stopped] {
            #expect(Hints.looksAfter(Self.session("k", knowing: true, state: state), watching: true, looked: nil))
        }
    }

    @Test func onlyTheFirstLookAndOnlyWhenItIsOn() {
        let over = Self.session("k", knowing: true, state: .done)
        #expect(!Hints.looksAfter(over, watching: false, looked: nil))
        // A look has run before: the next comes at its usual moments.
        #expect(!Hints.looksAfter(over, watching: true, looked: Date()))
    }

    @Test func onlyGetToKnowsEndStartsIt() {
        #expect(!Hints.looksAfter(nil, watching: true, looked: nil))
        #expect(!Hints.looksAfter(Self.session("task", state: .done), watching: true, looked: nil))
        #expect(!Hints.looksAfter(Self.session("profile", knowing: true, quiet: true, state: .done), watching: true, looked: nil))
        // Still at work: not yet.
        #expect(!Hints.looksAfter(Self.session("k", knowing: true), watching: true, looked: nil))
    }

    /// Its row in Memory and the new tab says each step in words, never a
    /// tool's name: most of Get to Know is off the page.
    @Test func itsStepsOffThePageAreSaidInWords() {
        #expect(AgentDock.say("history", name: "Claude Code") == "Looking through your history")
        #expect(AgentDock.say("fetch · linkedin.com", name: "Claude Code") == "Reading linkedin.com")
        #expect(AgentDock.say("WebFetch · github.com", name: "Claude Code") == "Reading github.com")
        #expect(AgentDock.say("WebSearch", name: "Claude Code") == "Searching the web")
        #expect(AgentDock.say("remember", name: "Claude Code") == "Remembering")
        #expect(AgentDock.say("keep_address", name: "Claude Code") == "Keeping an address")
        #expect(AgentDock.say("open · linkedin.com", name: "Claude Code") == "Opening linkedin.com")
    }
}
