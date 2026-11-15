import Foundation
import Testing
@testable import Fast

/// What a finished task leaves on its tabs and folders: the tick until you
/// come to the tab, then an ordinary tab's end (Tab.wearsFace, AgentFeed,
/// Folders.Folder.over).
@MainActor
struct AgentUnreadTests {
    @Test func agentsTabWearsTheFaceWhileItWorks() {
        let tab = Tab(bench: true)
        #expect(!tab.wearsFace)
        tab.agent = "task"
        #expect(tab.wearsFace)
    }

    @Test func seenTabHasAnOrdinaryEnd() {
        let tab = Tab(bench: true)
        tab.agent = "task"
        tab.settled = "task"
        #expect(!tab.wearsFace)
        // Still asking you, it is the hand, seen or not.
        tab.handoff = "Sign in"
        #expect(tab.wearsFace)
    }

    @Test func unreadTabWearsTheTickWhateverWorksThere() {
        let tab = Tab(bench: true)
        tab.agent = "task"
        tab.settled = "task"
        tab.unread = AgentFeed.Unread(session: "task")
        #expect(tab.wearsFace)
        // A guest gone from your tab, or the answer's page with no agent.
        let yours = Tab(bench: true)
        yours.unread = AgentFeed.Unread(session: "task", failed: true)
        #expect(yours.wearsFace)
    }

    @Test func anotherAgentInASeenTabBringsTheFaceBack() {
        let tab = Tab(bench: true)
        tab.agent = "task"
        tab.settled = "task"
        tab.guest = "next"
        tab.agent = nil
        #expect(tab.wearsFace)
    }

    @Test func onlyDoneAndFailedLeaveAnything() {
        #expect(AgentFeed.ended(.done) == false)
        #expect(AgentFeed.ended(.failed) == true)
        #expect(AgentFeed.ended(.stopped) == nil)
        #expect(AgentFeed.ended(.running) == nil)
    }

    @Test func folderTicksWhileAnyTabIsUnread() {
        var folder = Folders.Folder(id: "task", members: [], asking: [])
        #expect(folder.over == nil)
        folder.unread = 2
        #expect(folder.over == .done)
        folder.stuck = true
        #expect(folder.over == .stuck)
        folder.unread = 0
        #expect(folder.over == nil)
    }

    /// An agent attached through `yab mcp` stays attached for hours: its
    /// dock is only on a tab it did something in lately, never on one you
    /// handed back, until it clicks or types there again.
    @Test func attachedAgentIsAtWorkOnlyWhereItJustActed() {
        let feed = AgentFeed.shared
        let tab = Tab(bench: true)
        #expect(!feed.atWorkHere(tab))
        feed.did(tab, .click)
        #expect(feed.atWorkHere(tab))
        feed.answered(tab)
        #expect(!feed.atWorkHere(tab))
        feed.did(tab, .read)
        #expect(!feed.atWorkHere(tab))
        feed.did(tab, .click)
        #expect(feed.atWorkHere(tab))
    }

    /// Claude Code through `yab mcp` never says its turn is over: quiet
    /// for `AgentFeed.rests`, its folder and tabs stop wearing the face, and
    /// its next step brings the face back to the tab it acts in.
    @Test func attachedAgentGoneQuietStopsWearingTheFace() {
        let session = Agents.Session(id: "mcp", cli: "external", name: "Claude", prompt: "", state: .attached)
        session.touched = Date()
        #expect(session.working)
        session.touched = Date().addingTimeInterval(-AgentFeed.rests - 1)
        #expect(session.resting)
        #expect(!session.working)
        #expect(session.state.live)
        // A task Yab runs says when it is over; quiet means thinking.
        let task = Agents.Session(id: "task", cli: "claude", name: "Claude", prompt: "", state: .running)
        #expect(!task.resting)
        #expect(task.working)

        let tab = Tab(bench: true)
        tab.agent = "mcp"
        tab.settled = "mcp"
        #expect(!tab.wearsFace)
        AgentFeed.shared.did(tab, .click)
        #expect(tab.wearsFace)
    }

    @Test func folderRedrawsWhenItsTicksChange() {
        let a = Folders.Folder(id: "task", members: [], asking: [])
        var b = a
        b.unread = 1
        #expect(a != b)
        var c = b
        c.stuck = true
        #expect(b != c)
    }
}
