import AppKit
import Testing
@testable import Fast

/// #1373: outside MCP clients use the same session grouping as Yab's tasks.
@MainActor
@Suite(.serialized)
struct AgentTabGroupingTests {
    @MainActor private final class World {
        let browser: Browser
        let bench = Bench()
        let previousRow = Store.settings.object(forKey: AgentRow.key)
        var sessions: [Agents.Session] = []

        init(row: Bool = false) {
            _ = NSApplication.shared
            Store.settings.set(row, forKey: AgentRow.key)
            browser = Browser(windowID: UUID())
            browser.lay([])
            browser.activeID = nil
        }

        func attach(_ name: String, client: String = UUID().uuidString) throws -> Agents.Session {
            var reply: [String: Any] = [:]
            bench.agentCommand("agent-attach", ["name": name, "client": client], browser: browser) { reply = $0 }
            let id = try #require(reply["session"] as? String)
            let session = try #require(Agents.shared.session(id))
            sessions.append(session)
            #expect(session.client == client)
            return session
        }

        func tab(_ session: Agents.Session?, bench: Bool = true) -> Tab {
            let tab = Tab(bench: bench)
            tab.agent = session?.id
            browser.lay(browser.tabs + [tab])
            return tab
        }

        func close() {
            browser.letGo()
            for session in sessions { Agents.shared.detach(session.id) }
            Store.settings.set(previousRow, forKey: AgentRow.key)
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
    }

    @Test(arguments: ["bb", "claude-code", "codex"], [false, true])
    func outsideClientTabsShareOneGroup(name: String, row: Bool) throws {
        let w = World(row: row); defer { w.close() }
        let session = try w.attach(name)
        #expect(session.agent == .external && !session.task)
        let first = w.tab(session)
        #expect(Folders.tasks(in: w.browser.tabs).isEmpty)
        #expect(AgentRow.holds(first) == row)

        let second = w.tab(session)
        let folders = Folders.tasks(in: w.browser.tabs)
        #expect(folders.map(\.id) == [session.id])
        #expect(folders.first?.members == [first.id, second.id])
        // The column uses the Agents row instead of duplicating its folders.
        #expect(Folders.tasks(in: w.browser.tabs, rowed: true).map(\.id) == (row ? [] : [session.id]))
        let workers = AgentRow.workers(in: w.browser)
        #expect(workers.map(\.session.id) == (row ? [session.id] : []))
        if row { #expect(workers.first?.tabs.map(\.id) == [first.id, second.id]) }
    }

    @Test(arguments: [false, true])
    func separateSessionsWithTheSameClientNameStaySeparate(row: Bool) throws {
        let w = World(row: row); defer { w.close() }
        let first = try w.attach("bb"), second = try w.attach("bb")
        #expect(first.id != second.id && first.client != second.client)
        let a = w.tab(first), b = w.tab(second), c = w.tab(first), d = w.tab(second)
        let folders = Folders.tasks(in: w.browser.tabs)
        #expect(folders.map(\.id) == [first.id, second.id])
        #expect(folders.first?.members == [a.id, c.id])
        #expect(folders.last?.members == [b.id, d.id])
        if row {
            let workers = AgentRow.workers(in: w.browser)
            #expect(Set(workers.map(\.session.id)) == Set([first.id, second.id]))
            #expect(workers.first { $0.session.id == first.id }?.tabs.map(\.id) == [a.id, c.id])
            #expect(workers.first { $0.session.id == second.id }?.tabs.map(\.id) == [b.id, d.id])
        }
    }

    @Test func builtInTaskAndItsSubagentShareTheRootFolder() throws {
        let w = World(row: true); defer { w.close() }
        let task = try w.attach("Claude"), child = try w.attach("Claude")
        defer {
            task.cli = "external"; task.state = .attached; task.task = false
            child.cli = "external"; child.state = .attached; child.parent = nil
        }
        task.cli = "claude"
        task.state = .running
        task.task = true
        child.cli = "claude"
        child.state = .running
        child.parent = task.id
        let first = w.tab(task), second = w.tab(child)
        let folders = Folders.tasks(in: w.browser.tabs, rowed: true)
        #expect(folders.map(\.id) == [task.id])
        #expect(folders.first?.members == [first.id, second.id])
        #expect(!AgentRow.holds(first) && !AgentRow.holds(second))
    }

    @Test(arguments: [false, true])
    func sessionlessScriptsStayUngrouped(row: Bool) {
        let w = World(row: row); defer { w.close() }
        let first = w.tab(nil), second = w.tab(nil)
        first.agent = Agents.script
        second.agent = Agents.script
        #expect(Folders.tasks(in: w.browser.tabs).isEmpty)
        #expect(!AgentRow.holds(first) && !AgentRow.holds(second))
        #expect(AgentRow.workers(in: w.browser).isEmpty)
    }

    @Test(arguments: [false, true])
    func userTabsAndAdoptedTabsStayOutOfTheAgentGroup(row: Bool) throws {
        let w = World(row: row); defer { w.close() }
        let session = try w.attach("bb")
        let first = w.tab(session), second = w.tab(session)
        let user = w.tab(nil, bench: false)
        user.guest = session.id
        let pinned = w.tab(session), kept = w.tab(session)
        pinned.pin = "P"
        kept.kept = true
        let folders = Folders.tasks(in: w.browser.tabs)
        #expect(folders.first?.members == [first.id, second.id])
        #expect(!AgentRow.holds(user) && !AgentRow.holds(pinned) && !AgentRow.holds(kept))
        if row {
            #expect(AgentRow.workers(in: w.browser).first?.tabs.map(\.id) == [first.id, second.id])
        }
    }
}
