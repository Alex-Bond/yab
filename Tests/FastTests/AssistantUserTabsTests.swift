import Foundation
import Testing
@testable import Fast

/// #275: an assistant in the cloud (Grok Bot) sees the user's open tabs and
/// works in them as Yab's own agents do, a half-filled form finished where
/// the user stopped. The tab stays theirs: Done never closes it. Private
/// tabs, other agents' tabs and sites it may not open stay off limits.
@MainActor
@Suite(.serialized)
struct AssistantUserTabsTests {
    @MainActor private final class World {
        let browser: Browser
        let session: Agents.Session
        let grant: AssistantGrant
        let yours: Tab
        var made: [Agents.Session] = []

        init(never: [String] = [], url: String = "https://forms.example.test/apply") {
            browser = Browser(windowID: UUID())
            yours = Tab()
            browser.lay([yours])
            browser.activeID = nil
            yours.restore(url: URL(string: url)!, title: "Apply")
            session = Agents.shared.attach(name: "Grok Bot")
            var grant = AssistantGrant(id: Assistants.newID(), name: "Grok Bot", client: "grok-bot", space: browser.spaces.first?.id, made: Date())
            grant.never = never
            self.grant = grant
            Assistants.shared.keep(grant)
            session.assistant = grant.id
        }

        func attach(_ name: String) -> Agents.Session {
            let made = Agents.shared.attach(name: name)
            self.made.append(made)
            return made
        }

        func check(_ verb: String, tab: Tab? = nil, session: String? = nil) -> AssistantBoundary.Verdict {
            AssistantBoundary.check(["do": verb, "session": session ?? self.session.id, "id": Bench.short(tab ?? yours)],
                                    bench: Bench(), browser: browser)
        }

        func listed() -> [[String: Any]] {
            var rows: [[String: Any]] = []
            Bench().agentCommand("agent-tabs", ["session": session.id], browser: browser) { rows = $0["tabs"] as? [[String: Any]] ?? [] }
            return rows
        }

        func close() {
            for one in made { one.state = .done }
            session.state = .done
            Assistants.shared.remove(grant.id)
            browser.letGo()
            if let window = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(window.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(window.uuidString).space")
            }
        }
    }

    private func passes(_ verdict: AssistantBoundary.Verdict) -> Bool {
        if case .pass = verdict { return true }
        return false
    }

    @Test func theUsersTabIsListedAndReadable() {
        let w = World(); defer { w.close() }
        let row = w.listed().first { $0["id"] as? String == Bench.short(w.yours) }
        #expect(row?["whose"] as? String == "user")
        #expect(passes(w.check("snapshot")))
        #expect(passes(w.check("act")))
    }

    /// The call drives that very tab, as a guest: the face on it, the tab
    /// still the user's, where it was.
    @Test func itWorksInTheGivenTabAsAGuest() {
        let w = World(); defer { w.close() }
        guard case .pass(let bound) = w.check("act") else { Issue.record("refused"); return }
        var said: [String: Any] = [:]
        let call = AgentCall(bench: Bench(), verb: "act", request: bound, browser: w.browser) { said = $0 }
        #expect(call.own() === w.yours, "\(said)")
        #expect(w.yours.guest == w.session.id)
        #expect(w.yours.agent == nil)
        #expect(!w.yours.bench)
        #expect(w.browser.tabs.contains { $0 === w.yours })
    }

    @Test func privateAndOtherAgentsTabsAreNotThere() {
        let w = World(); defer { w.close() }
        let shy = Tab(shy: true)
        shy.restore(url: URL(string: "https://forms.example.test/")!, title: "Private")
        w.browser.lay([w.yours, shy])
        #expect(!passes(w.check("snapshot", tab: shy)))
        let other = w.attach("Someone else's task")
        let theirs = w.browser.benchOpen(URL(string: "about:blank")!)
        theirs.restore(url: URL(string: "https://forms.example.test/x")!, title: "Agent's")
        theirs.agent = other.id
        #expect(!passes(w.check("act", tab: theirs)))
        let ids = w.listed().compactMap { $0["id"] as? String }
        #expect(!ids.contains(Bench.short(shy)))
        #expect(!ids.contains(Bench.short(theirs)))
    }

    @Test func aSiteItMayNotOpenIsNeitherListedNorTouched() {
        let w = World(never: ["chase.com"], url: "https://chase.com/pay"); defer { w.close() }
        #expect(!passes(w.check("snapshot")))
        #expect(!passes(w.check("act")))
        #expect(!w.listed().contains { $0["id"] as? String == Bench.short(w.yours) })
    }

    @Test func itsTaskWorksThereToo() {
        let w = World(); defer { w.close() }
        let task = w.attach("Its task")
        task.assistant = w.grant.id
        #expect(passes(w.check("act", session: task.id)))
    }

    /// The read a tool makes after its own act doesn't become the step:
    /// the foot says "Typing on…", not "Reading…".
    @Test func aFollowUpReadKeepsTheActAsTheStep() {
        let w = World(); defer { w.close() }
        Agents.shared.touch(w.session.id, "act · forms.example.test")
        Agents.shared.touch(w.session.id, "snapshot · forms.example.test", step: false)
        #expect(w.session.now == "act · forms.example.test")
        Agents.shared.touch(w.session.id, "snapshot · forms.example.test")
        #expect(w.session.now == "snapshot · forms.example.test")
    }

    /// Done closes the task's own tabs, never the user's it worked in.
    @Test func doneLeavesTheUsersTabOpen() {
        let w = World(); defer { w.close() }
        let task = w.attach("Its task")
        task.assistant = w.grant.id
        w.yours.guest = task.id
        let own = Tab(bench: true)
        own.agent = task.id
        let left = Agents.shared.leftovers(task.id, among: w.browser.tabs + [own])
        #expect(left.map(\.id) == [own.id])
    }

    /// The same for ⌘J asked on a page by a task of Yab's on this Mac.
    @Test func askedOnAPageDoneLeavesThatPage() {
        let w = World(); defer { w.close() }
        let task = w.attach("Finish this form")
        w.yours.allowed.insert(task.id)
        w.yours.guest = task.id
        var said: [String: Any] = [:]
        let call = AgentCall(bench: Bench(), verb: "act", request: ["do": "act", "session": task.id, "id": Bench.short(w.yours)], browser: w.browser) { said = $0 }
        #expect(call.own() === w.yours, "\(said)")
        let own = Tab(bench: true)
        own.agent = task.id
        let left = Agents.shared.leftovers(task.id, among: w.browser.tabs + [own])
        #expect(left.map(\.id) == [own.id])
    }
}
