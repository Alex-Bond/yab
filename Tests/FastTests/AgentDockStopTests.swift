import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentDockStopTests {
    @Test func terminalWordsKeepStoppedDistinctFromDoneAndFailed() {
        let session = Agents.Session(id: "dock-words", cli: "claude", name: "Claude", prompt: "", state: .stopped)
        session.result = "A partial answer"
        #expect(AgentDock.finishedWords(session) == "You stopped Claude")
        session.state = .attached
        #expect(AgentDock.finishedWords(session, stopped: true) == "You stopped Claude")
        session.state = .failed
        #expect(AgentDock.finishedWords(session) == "Claude couldn’t finish")
        session.state = .done
        #expect(AgentDock.finishedWords(session) == "Done · A partial answer")
    }

    @Test func stopShortcutHasItsOwnChordAndContext() {
        let key = Hotkey(".", [.shift, .command])
        #expect(Shortcut.byAction[.agentStop]?.key == key)
        #expect(Shortcut.context(.agentStop) == .agent)
        #expect(Keymap.valid(key, for: .agentStop))
        #expect(Hotkeys.action(forTitle: "Stop Agent") == .agentStop)
        #expect(Keymap.conflicts(.agentStop, Hotkey("t", .command), .fieldActions, Hotkey("t", .command)))
    }

    @Test(arguments: [false, true])
    func attachedStopReleasesOnlyThisTabAndRefusesFurtherCalls(driving: Bool) {
        _ = NSApplication.shared
        let agents = Agents.shared
        let session = agents.attach(name: "Claude")
        let tab = Tab(bench: true), other = Tab(bench: true)
        tab.agent = session.id
        other.agent = session.id
        let browser = Browser(windowID: UUID())
        let oldBrowser = agents.browser, oldFeedBrowser = AgentFeed.shared.browser
        browser.lay([tab, other])
        browser.activeID = tab.id
        agents.browser = browser
        AgentFeed.shared.browser = browser
        defer {
            agents.browser = oldBrowser
            AgentFeed.shared.browser = oldFeedBrowser
            tab.close(); other.close(); browser.letGo()
        }
        tab.allowed.insert(session.id)
        AgentFeed.shared.did(tab, .read)
        if driving {
            AgentFeed.shared.drive(tab)
            #expect(AgentFeed.shared.driving.contains(tab.id))
        }
        #expect(agents.stop(on: tab))
        #expect(session.state == .attached)
        #expect(session.process == nil)
        #expect(tab.worker == nil)
        #expect(!tab.allowed.contains(session.id))
        #expect(!AgentFeed.shared.driving.contains(tab.id))
        #expect(AgentFeed.shared.pointer[tab.id] == nil)
        #expect(AgentFeed.shared.stopped[tab.id] == session.id)
        #expect(other.worker == session.id)
        #expect(agents.stoppedOnTab(tab, session: session.id) == "The person stopped you on this tab.")
        #expect(agents.stoppedOnTab(other, session: session.id) == nil)
        #expect(agents.stoppedOnTab(tab, session: "another-agent") == nil)
        #expect(!agents.stop(on: tab))
        agents.detach(session.id)
    }

    @Test func ownedStopKeepsThePageAndTheStoppedChatItem() {
        _ = NSApplication.shared
        let agents = Agents.shared
        let session = agents.attach(name: "Claude")
        session.cli = "claude"
        session.state = .running
        let tab = Tab(bench: true)
        tab.agent = session.id
        tab.restore(url: URL(string: "about:blank#kept")!, title: "Kept page")
        #expect(agents.stop(on: tab))
        #expect(session.state == .stopped)
        #expect(session.items.contains { $0.name == ChatItem.stopped })
        #expect(tab.address?.absoluteString == "about:blank#kept")
        #expect(!agents.stop(on: tab))
    }

    @Test func scriptStopReleasesThePageAndRejectsSessionlessCalls() {
        let tab = Tab(bench: true)
        let session = Agents.shared.scripted()
        tab.agent = session.id
        #expect(Agents.shared.stop(on: tab))
        #expect(session.state == .attached)
        #expect(tab.worker == nil)
        #expect(Agents.shared.stoppedOnTab(tab, session: nil) == "The person stopped you on this tab.")
    }

    @Test func releasedTabRejectsReadsBeforeWakingOrReclaimingIt() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        let session = Agents.shared.attach(name: "Claude")
        tab.agent = session.id
        browser.lay([tab])
        browser.activeID = tab.id
        #expect(Agents.shared.stop(on: tab))
        var reply: [String: Any] = [:]
        Bench().agentCommand("snapshot", ["id": tab.id.uuidString, "session": session.id], browser: browser) { reply = $0 }
        #expect(reply["error"] as? String == "The person stopped you on this tab.")
        #expect(tab.worker == nil)
        for verb in ["handoff", "agent-go", "agent-eval"] {
            reply = [:]
            Bench().agentCommand(verb, ["id": tab.id.uuidString, "session": session.id], browser: browser) { reply = $0 }
            #expect(reply["error"] as? String == "The person stopped you on this tab.")
        }
        #expect(browser.tabs.contains { $0 === tab })
        Agents.shared.detach(session.id)
        tab.close()
        browser.letGo()
    }
}
