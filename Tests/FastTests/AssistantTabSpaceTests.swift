import Foundation
import SyncKit
import Testing
@testable import Fast

/// #224: two spaces may share a cookie store without sharing Grok's tabs.
@MainActor
@Suite(.serialized)
struct AssistantTabSpaceTests {
    @MainActor private final class World {
        let browser: Browser
        let home = Space(id: UUID(), name: "im", icon: "I", ownSignIns: false)
        let other = Space(id: UUID(), name: "other", icon: "O", ownSignIns: false)
        let session: Agents.Session
        let grant: AssistantGrant
        let savedSpaces = Store.settings.object(forKey: "spaces")
        let savedList = try? Data(contentsOf: Store.file("spaces.json"))

        init() {
            browser = Browser(windowID: UUID())
            browser.lay([])
            browser.activeID = nil
            browser.prefs.usesSpaces = true
            browser.spaces.append(contentsOf: [home, other])
            Spaces.sharing.formUnion([home.id, other.id])
            session = Agents.shared.attach(name: "Grok Bot")
            grant = AssistantGrant(id: Assistants.newID(), name: "Grok Bot", client: "grok-bot", space: home.id, made: Date())
            Assistants.shared.keep(grant)
            session.assistant = grant.id
        }

        func tab(session: String? = nil, in space: UUID? = nil) -> Tab {
            // The same creation/ownership path as Bench.open, without a
            // network dependency. It is prepared before ownership is set.
            let tab = browser.benchOpen(URL(string: "about:blank")!, space: space ?? home.id)
            tab.restore(url: URL(string: "https://assistant.example.test/\(tab.id)")!, title: "Grok page")
            tab.agent = session ?? self.session.id
            return tab
        }

        func close() {
            browser.letGo()
            session.state = .done
            Assistants.shared.remove(grant.id)
            Store.settings.set(savedSpaces, forKey: "spaces")
            if let savedList { try? savedList.write(to: Store.file("spaces.json")) }
            for id in [home.id, other.id] {
                Spaces.sharing.remove(id)
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

    @Test func theGrantRoutesToItsSpaceEvenWithSharedCookies() throws {
        let w = World(); defer { w.close() }
        let bench = Bench()
        let request: [String: Any] = ["do": "open", "session": w.session.id, "space": "other", "url": "https://assistant.example.test"]
        guard case .pass(let bound) = AssistantBoundary.check(request, bench: bench, browser: w.browser) else {
            Issue.record("assistant open refused"); return
        }
        #expect(bound["space"] as? String == "im")
        let tab = w.tab()
        #expect(tab.store === Spaces.store(for: w.home.id))
        #expect(Spaces.store(for: w.home.id) === Spaces.store(for: w.other.id))
        #expect(!w.browser.tabs.contains { $0 === tab })
        #expect(w.browser.spaceHolding(tab.id) == w.home.id)
        #expect(bench.find(["id": Bench.short(tab)], in: w.browser) === tab)
        #expect(w.browser.tab(owning: tab.page) === tab)
        #expect(!w.browser.travels(tab))
    }

    @Test func oldGrantsDoNotGainAllSpacesWhenDecoded() throws {
        let w = World(); defer { w.close() }
        let encoded = try JSONEncoder().encode(w.grant)
        let old = try JSONDecoder().decode(AssistantGrant.self, from: encoded)
        #expect(old.allSpaces == nil)
        #expect(old.space == w.home.id)
        var wide = old
        wide.allSpaces = true
        #expect(try JSONDecoder().decode(AssistantGrant.self, from: JSONEncoder().encode(wide)) == wide)
    }

    @Test func theSettingsChoicePersistsAndCanBeNarrowedAgain() throws {
        let w = World(); defer { w.close() }
        var grant = w.grant
        #expect(grant.selectedSpace(in: w.browser.spaces) == w.home.id)
        grant.selectSpace(nil)
        grant = try JSONDecoder().decode(AssistantGrant.self, from: JSONEncoder().encode(grant))
        #expect(grant.allSpaces == true)
        #expect(grant.selectedSpace(in: w.browser.spaces) == nil)
        #expect(grant.spaceName(in: w.browser.spaces) == "All spaces")
        grant.selectSpace(w.other.id)
        Assistants.shared.keep(grant)
        #expect(grant.allSpaces == false)
        #expect(grant.selectedSpace(in: w.browser.spaces) == w.other.id)
        #expect(grant.spaceName(in: w.browser.spaces) == w.other.name)
        guard case .pass(let bound) = AssistantBoundary.check(["do": "open", "session": w.session.id,
            "space": w.home.name, "url": "https://assistant.example.test"], bench: Bench(), browser: w.browser) else {
            Issue.record("narrowed grant refused"); return
        }
        #expect(bound["space"] as? String == w.other.name)
    }

    @Test func aLegacyMissingOrDeletedSpaceDisplaysItsActualFallback() {
        let w = World(); defer { w.close() }
        var grant = w.grant
        for missing in [Optional<UUID>.none, UUID()] {
            grant.space = missing
            #expect(grant.selectedSpace(in: w.browser.spaces) == w.browser.spaces.first?.id)
            #expect(grant.spaceName(in: w.browser.spaces) == w.browser.spaces.first?.name)
            #expect(grant.allSpaces != true)
        }
        grant.selectSpace(nil)
        let added = Space(id: UUID(), name: "Added later", icon: "A", ownSignIns: true)
        #expect(grant.spaceName(in: w.browser.spaces + [added]) == "All spaces")
        #expect(grant.selectedSpace(in: w.browser.spaces + [added]) == nil)
    }

    @Test func allSpacesHonorsAnExplicitSpaceAndAutomaticSignInSelection() {
        let w = World(); defer { w.close() }
        Assistants.shared.update(w.grant.id) { $0.allSpaces = true }
        for chosen in [Optional(w.other.name), nil] {
            var request: [String: Any] = ["do": "open", "session": w.session.id, "url": "https://assistant.example.test"]
            request["space"] = chosen
            guard case .pass(let bound) = AssistantBoundary.check(request, bench: Bench(), browser: w.browser) else {
                Issue.record("all-spaces open refused"); return
            }
            #expect(bound["space"] as? String == chosen)
        }
    }

    @Test func allSpacesTabsAndChildTasksKeepTheirChosenHomeWithSharedCookies() {
        let w = World(); defer { w.close() }
        Assistants.shared.update(w.grant.id) { $0.allSpaces = true }
        let child = Agents.shared.attach(name: "Child task")
        defer { child.state = .done }
        child.parent = w.session.id
        w.browser.switchSpace(to: w.home.id)
        let first = w.tab(), second = w.tab(session: child.id, in: w.other.id)
        #expect(first.store === second.store)
        for id in [w.other.id, Space.firstID, w.home.id] {
            w.browser.switchSpace(to: id)
            #expect(w.browser.tabs.contains { $0 === first } == (id == w.home.id))
            #expect(w.browser.tabs.contains { $0 === second } == (id == w.other.id))
            if id != w.home.id { #expect(w.browser.spaceHolding(first.id) == w.home.id) }
            if id != w.other.id { #expect(w.browser.spaceHolding(second.id) == w.other.id) }
            #expect(w.browser.everyTab.filter { $0 === first }.count == 1)
            #expect(w.browser.everyTab.filter { $0 === second }.count == 1)
            #expect(!w.browser.travels(first))
            #expect(!w.browser.travels(second))
        }
    }

    @Test func allSpacesExposesDiscoveryButKeepsSiteAndPauseRules() throws {
        let w = World(); defer { w.close() }
        let request: [String: Any] = ["do": "spaces", "session": w.session.id]
        if case .pass = AssistantBoundary.check(request, bench: Bench(), browser: w.browser) {
            Issue.record("single-space grant unexpectedly listed spaces")
        }
        Assistants.shared.update(w.grant.id) { $0.allSpaces = true; $0.never = ["example.test"] }
        guard case .pass = AssistantBoundary.check(request, bench: Bench(), browser: w.browser) else {
            Issue.record("all-spaces discovery refused"); return
        }
        let grant = try #require(Assistants.shared.grant(w.grant.id))
        let caps = Bench.assistantCaps(grant, browser: w.browser)
        #expect(caps["allSpaces"] as? Bool == true)
        #expect(caps["spaces"] as? [String] == w.browser.spaces.map(\.name))
        if case .pass = AssistantBoundary.check(["do": "open", "session": w.session.id, "space": w.other.name,
                                                "url": "https://assistant.example.test"], bench: Bench(), browser: w.browser) {
            Issue.record("all spaces bypassed a site rule")
        }
        Assistants.shared.update(w.grant.id) { $0.paused = true }
        if case .pass = AssistantBoundary.check(request, bench: Bench(), browser: w.browser) {
            Issue.record("paused assistant listed spaces")
        }
    }

    @Test func onlyAllSpacesListsTheUsersParkedTabs() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.other.id)
        let user = Tab()
        user.restore(url: URL(string: "https://user.example.test/form")!, title: "User form")
        w.browser.lay([user])
        w.browser.switchSpace(to: w.home.id)
        func listed() -> [[String: Any]] {
            var result: [String: Any] = [:]
            Bench().agentCommand("agent-tabs", ["session": w.session.id], browser: w.browser) { result = $0 }
            return result["tabs"] as? [[String: Any]] ?? []
        }
        #expect(!listed().contains { $0["id"] as? String == Bench.short(user) })
        Assistants.shared.update(w.grant.id) { $0.allSpaces = true }
        #expect(listed().contains { $0["id"] as? String == Bench.short(user) && $0["whose"] as? String == "user"
            && $0["space"] as? String == w.other.name })
        Assistants.shared.update(w.grant.id) { $0.never = ["example.test"] }
        #expect(!listed().contains { $0["id"] as? String == Bench.short(user) })
    }

    @Test func mcpListsSpacesOnlyWhenGranted() {
        var audience = Mcp.Audience(assistant: true)
        #expect(!Mcp.list(for: audience).contains { $0["name"] as? String == "spaces" })
        audience.assistantAllSpaces = true
        #expect(Mcp.list(for: audience).contains { $0["name"] as? String == "spaces" })
        #expect(Mcp.assistantRefusal("run", audience) != nil)
        #expect(Mcp.assistantRefusal("autofill", audience) != nil)
    }

    @Test(arguments: [true, false]) func grantedSpacesFindSavedTabsBeforeTheUserVisitsTheirSpace(all: Bool) throws {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.other.id)
        let user = Tab()
        user.restore(url: URL(string: "https://user.example.test/saved")!, title: "Saved form")
        w.browser.lay([user])
        w.browser.switchSpace(to: w.home.id)
        let row = try #require(w.browser.parked[w.other.id])
        w.browser.writeRow(row.tabs, active: row.active, space: w.other.id, pairs: row.pairs, now: true)
        w.browser.parked[w.other.id] = nil
        Assistants.shared.update(w.grant.id) { $0.selectSpace(all ? nil : w.other.id) }
        var result: [String: Any] = [:]
        Bench().agentCommand("agent-tabs", ["session": w.session.id], browser: w.browser) { result = $0 }
        let rows = result["tabs"] as? [[String: Any]] ?? []
        #expect(rows.contains { $0["url"] as? String == "https://user.example.test/saved"
            && (!all || $0["space"] as? String == w.other.name) })
        #expect(w.browser.spaceID == w.home.id)
        #expect(!w.browser.tabs.contains { $0.id == user.id })
        #expect(w.browser.parked[w.other.id]?.tabs.first?.hollow == true)
    }

    @Test func narrowingRevokesExistingTabsInOtherSpacesImmediately() {
        let w = World(); defer { w.close() }
        Assistants.shared.update(w.grant.id) { $0.selectSpace(nil) }
        let home = w.tab(), other = w.tab(in: w.other.id)
        Assistants.shared.update(w.grant.id) { $0.selectSpace(w.home.id) }
        for verb in ["snapshot", "act", "close", "nav"] {
            let request: [String: Any] = ["do": verb, "session": w.session.id, "id": Bench.short(other)]
            guard case .refuse(let why) = AssistantBoundary.check(request, bench: Bench(), browser: w.browser) else {
                Issue.record("narrowed grant retained \(verb) in another space"); continue
            }
            #expect(why.contains("refused_space"))
        }
        var result: [String: Any] = [:]
        Bench().agentCommand("agent-tabs", ["session": w.session.id], browser: w.browser) { result = $0 }
        let rows = result["tabs"] as? [[String: Any]] ?? []
        #expect(rows.contains { $0["id"] as? String == Bench.short(home) })
        #expect(!rows.contains { $0["id"] as? String == Bench.short(other) })
    }

    @Test func aUsersSignInPopupKeepsItsOpenersScopeWhileThatSpaceIsParked() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.home.id)
        let parent = Tab()
        parent.restore(url: URL(string: "https://user.example.test/form")!, title: "Form")
        w.browser.lay([parent])
        let popup = Tab()
        popup.opener = parent.id
        w.browser.switchSpace(to: w.other.id)
        #expect(w.grant.permits(popup, in: w.browser))
        var other = w.grant
        other.selectSpace(w.other.id)
        #expect(!other.permits(popup, in: w.browser))
    }

    @Test func switchingSpacesKeepsExactlyOneTabAtHome() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.home.id)
        let tab = w.tab()
        for id in [w.other.id, Space.firstID, w.home.id, w.other.id, w.home.id] {
            w.browser.switchSpace(to: id)
            #expect(w.browser.everyTab.filter { $0 === tab }.count == 1)
            #expect(w.browser.tabs.contains { $0 === tab } == (id == w.home.id))
        }
    }

    @Test func anAssistantCanListAndCloseItsParkedTabWithoutSwitching() {
        let w = World(); defer { w.close() }
        let tab = w.tab(), original = w.browser.spaceID
        let bench = Bench()
        var result: [String: Any] = [:]
        bench.agentCommand("agent-tabs", ["session": w.session.id], browser: w.browser) { result = $0 }
        let rows = result["tabs"] as? [[String: Any]] ?? []
        #expect(rows.contains { $0["id"] as? String == Bench.short(tab) && $0["visible"] as? Bool == false })
        w.browser.close(tab)
        #expect(!w.browser.everyTab.contains { $0 === tab })
        #expect(tab.gone)
        #expect(w.browser.spaceID == original)
    }

    @Test func tasksInheritTheAssistantsSpace() {
        let w = World(); defer { w.close() }
        let task = Agents.shared.attach(name: "Child task")
        defer { task.state = .done }
        task.parent = w.session.id
        let tab = w.tab(session: task.id)
        #expect(w.browser.spaceHolding(tab.id) == w.home.id)
        #expect(!w.browser.travels(tab))
    }

    @Test func aSavedHandoffSyncsUnderItsHomeOnly() throws {
        let w = World(); defer { w.close() }
        let tab = w.tab()
        tab.handoff = "Sign in"
        w.browser.writeSession(now: true)
        let row = try #require(w.browser.parked[w.home.id])
        w.browser.writeRow(row.tabs, active: row.active, space: w.home.id, pairs: row.pairs, now: true)
        let here = Session.read(space: w.browser.spaceID, window: w.browser.windowID)
        let home = Session.read(space: w.home.id, window: w.browser.windowID)
        #expect(!here.tabs.contains { $0.id == tab.id.uuidString })
        #expect(home.tabs.contains { $0.id == tab.id.uuidString })
        let records = SyncShapes.rows([w.browser.spaceID: here, w.home.id: home], orders: [:]).tabs
        #expect(records[tab.id.uuidString]?["parent"]?.string == w.home.id.uuidString)
    }

    @Test func localAgentsStillFollowTheUser() {
        let w = World(); defer { w.close() }
        let tab = w.tab(session: Agents.script)
        #expect(w.browser.travels(tab))
        w.browser.switchSpace(to: w.other.id)
        #expect(w.browser.tabs.contains { $0 === tab })
    }

    @Test func reusingAParkedTabRequiresTheSameAssistantAndSpace() throws {
        let w = World(); defer { w.close() }
        let old = Agents.shared.attach(name: "Earlier task")
        old.assistant = w.grant.id
        old.state = .done
        let tab = w.tab(session: old.id)
        let url = try #require(tab.pending ?? tab.address)
        let bench = Bench()
        #expect(bench.leftover(url, space: w.home.id, session: w.session.id, in: w.browser) === tab)
        #expect(bench.leftover(url, space: w.other.id, session: w.session.id, in: w.browser) == nil)
        let stranger = Agents.shared.attach(name: "Stranger")
        defer { stranger.state = .done }
        stranger.assistant = "another-assistant"
        #expect(bench.leftover(url, space: w.home.id, session: stranger.id, in: w.browser) == nil)
    }

    @Test func adoptingTheTabKeepsItInItsHomeRow() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.home.id)
        let tab = w.tab()
        tab.adopt()
        w.browser.switchSpace(to: w.other.id)
        #expect(w.browser.spaceHolding(tab.id) == w.home.id)
        #expect(!w.browser.tabs.contains { $0 === tab })
        let entry = w.browser.sessionEntry(tab, id: tab.id)
        #expect(entry?.id == tab.id.uuidString)
    }

    @Test func aLocalTaskTakingOverAnAssistantTabCanFollowAgain() {
        let w = World(); defer { w.close() }
        w.browser.switchSpace(to: w.home.id)
        let tab = w.tab()
        tab.agent = Agents.script
        #expect(w.browser.travels(tab))
        w.browser.switchSpace(to: w.other.id)
        #expect(w.browser.tabs.contains { $0 === tab })
    }
}
