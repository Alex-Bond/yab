import Foundation
import Testing
@testable import Fast

/// #448: a local agent's folder, made in a space with its own sign-ins,
/// showed in every space, each signed in as someone else.
@MainActor
@Suite(.serialized)
struct LocalAgentSpaceTests {
    @MainActor private final class World {
        let browser: Browser
        let work = Space(id: UUID(), name: "Work", icon: "W", ownSignIns: true)
        let home = Space(id: UUID(), name: "Home", icon: "H", ownSignIns: true)
        let session: Agents.Session
        let savedSpaces = Store.settings.object(forKey: "spaces")
        let savedList = try? Data(contentsOf: Store.file("spaces.json"))

        init() {
            browser = Browser(windowID: UUID())
            browser.lay([])
            browser.activeID = nil
            browser.prefs.usesSpaces = true
            browser.spaces.append(contentsOf: [work, home])
            session = Agents.shared.attach(name: "Claude")
        }

        /// A tab the agent opens with `space`'s sign-ins, as Bench.open does.
        func tab(in space: UUID?) -> Tab {
            let tab = browser.benchOpen(URL(string: "about:blank")!, space: space)
            tab.restore(url: URL(string: "https://agent.example.test/\(tab.id)")!, title: "Agent page")
            tab.agent = session.id
            return tab
        }

        func close() {
            browser.letGo()
            session.state = .done
            Store.settings.set(savedSpaces, forKey: "spaces")
            if let savedList { try? savedList.write(to: Store.file("spaces.json")) }
            for id in [work.id, home.id] {
                Spaces.pageCounts[id] = nil
                if let window = browser.windowID {
                    try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString)-\(id.uuidString).json"))
                }
            }
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
            }
        }
    }

    @Test func aTasksFolderStaysInTheSpaceWhoseSignInsItUses() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.work.id)
        let tabs = [w.tab(in: w.work.id), w.tab(in: w.work.id)]
        let root = Agents.shared.root(of: w.session.id)
        #expect(Folders.tasks(in: w.browser.tabs).contains { $0.id == root })
        for tab in tabs { #expect(!w.browser.travels(tab)) }
        w.browser.switchSpace(to: w.home.id)
        #expect(!w.browser.tabs.contains { tab in tabs.contains { $0 === tab } })
        #expect(!Folders.tasks(in: w.browser.tabs).contains { $0.id == root })
        for tab in tabs { #expect(w.browser.spaceHolding(tab.id) == w.work.id) }
        // Still the agent's to find and list while you are elsewhere.
        var result: [String: Any] = [:]
        Bench().agentCommand("agent-tabs", ["session": w.session.id], browser: w.browser) { result = $0 }
        let rows = result["tabs"] as? [[String: Any]] ?? []
        #expect(rows.filter { $0["whose"] as? String == "yours" && $0["visible"] as? Bool == false }.count == 2)
        w.browser.switchSpace(to: w.work.id)
        #expect(Folders.tasks(in: w.browser.tabs).contains { $0.id == root })
    }

    @Test func aTabOpenedWithAnotherSpacesSignInsGoesThere() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.home.id)
        let tab = w.tab(in: w.work.id)
        #expect(!w.browser.tabs.contains { $0 === tab })
        #expect(w.browser.spaceHolding(tab.id) == w.work.id)
    }

    @Test func aTabWithTheSharedSignInsStillFollowsYou() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: Space.firstID)
        let tab = w.tab(in: Space.firstID)
        #expect(w.browser.travels(tab))
        w.browser.switchSpace(to: w.home.id)
        #expect(w.browser.tabs.contains { $0 === tab })
    }
}
