import AppKit
import Foundation
import Testing
@testable import Fast

/// Real Bench socket/AgentCall/NativeControl callers in an isolated Store world.
/// Loopback addresses only; no human profile, browser accounts or external writes.
@MainActor
@Suite(.serialized)
struct AgentUserTabOwnershipTests {
    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let bench = Bench()
        let session = Agents.shared.attach(name: "Ownership fixture")
        let user = Tab()
        let other = Tab()
        let previousBench = Store.settings.object(forKey: "bench")
        let previousMode: AgentAsking
        let url = URL(string: "http://127.0.0.1:9/user")!
        let target = URL(string: "http://127.0.0.1:9/agent")!

        init(front: Bool = false, mode: AgentAsking = .auto) {
            _ = NSApplication.shared
            Store.settings.set(true, forKey: "bench")
            previousMode = browser.prefs.agentsAsking
            browser.prefs.agentsAsking = mode
            user.restore(url: url, title: "User fixture")
            other.restore(url: URL(string: "about:blank#other")!, title: "Other fixture")
            browser.lay([user, other])
            browser.activeID = front ? user.id : other.id
            session.nativeOriginTab = user.id
            bench.start(for: browser)
        }
        func ask(_ values: [String: Any]) async -> [String: Any] {
            var request = values
            request["session"] = session.id
            let path = Bench.socket.path
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Wire.ask(path, request))
                }
            }
        }
        func permitUser() {
            user.permit = AgentPermit(kind: .use, session: session.id, detail: "Use this particular fixture tab")
            Agents.shared.answer(user, yes: true)
        }
        func native(_ control: NativeControl, _ request: [String: Any]) -> [String: Any] {
            var bound = request
            bound["session"] = session.id
            var answer: [String: Any] = [:]
            control.handle("agent-native-apply", request: bound, browser: browser) { answer = $0 }
            return answer
        }
        func dispose() {
            bench.stop()
            Store.settings.set(previousBench, forKey: "bench")
            browser.prefs.agentsAsking = previousMode
            Agents.shared.detach(session.id)
            for tab in browser.everyTab { tab.close() }
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
    }

    @MainActor private final class PersistedWorld {
        let world: World
        let destination: UUID
        let originalSpace: UUID
        let previousSpaces: Any?
        let savedID = UUID()
        let savedURL = URL(string: "http://127.0.0.1:9/saved-user")!
        let includeID: Bool

        init(currentApproved: Bool, includeID: Bool = true, mode: AgentAsking = .bypass) {
            self.includeID = includeID
            world = World(mode: mode)
            let browser = world.browser
            previousSpaces = Store.settings.object(forKey: "spaces")
            browser.prefs.usesSpaces = true
            originalSpace = browser.spaceID
            if currentApproved {
                world.permitUser()
                world.other.permit = AgentPermit(kind: .use, session: world.session.id, detail: "Use this particular fixture tab")
                Agents.shared.answer(world.other, yes: true)
            } else {
                let own = Tab(bench: true)
                own.agent = world.session.id
                own.restore(url: URL(string: "about:blank#owned-current")!, title: "Agent fixture")
                browser.lay([own])
                browser.activeID = own.id
            }
            destination = browser.addSpace(named: "Saved ownership " + UUID().uuidString, ownSignIns: false, show: false)
            writeSaved(savedURL)
        }
        func writeSaved(_ url: URL) {
            let entry = Session.Entry(url: url.absoluteString, title: "Saved USER fixture", pin: nil,
                                      name: nil, seen: nil, id: includeID ? savedID.uuidString : nil)
            Session.write(now: true, space: destination, window: world.browser.windowID, Session.Shape(tabs: [entry], front: 0))
            Session.settle() // The test exercises an actual on-disk row.
        }
        func request(_ control: NativeControl) -> [String: Any] {
            world.native(control, ["action": "space.switch", "target": ["kind": "space", "id": destination.uuidString],
                                   "arguments": [:], "requestId": "saved-destination"])
        }
        func dispose() {
            if world.browser.spaceID != originalSpace { world.browser.switchSpace(to: originalSpace) }
            world.browser.deleteSpace(destination)
            Store.settings.set(previousSpaces, forKey: "spaces")
            world.dispose()
        }
    }

    @Test(arguments: [AgentAsking.ask, .auto, .bypass], [false, true])
    func persistedSpaceSwitchDoesNotAsk(mode: AgentAsking, includeID: Bool) {
        let f = PersistedWorld(currentApproved: false, includeID: includeID, mode: mode)
        defer { f.dispose() }
        let w = f.world
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = NativeControl(file: folder.appendingPathComponent("operations.json"))
        #expect(w.browser.parked[f.destination] == nil)
        let got = f.request(control)
        #expect(got["status"] as? String == "verified", "\(got)")
        #expect(w.browser.spaceID == f.destination)
        #expect(w.browser.tabs.contains { !$0.bench && $0.address == f.savedURL })
        #expect(w.browser.everyTab.allSatisfy { $0.permit == nil })
    }

    @Test func spaceSwitchWithCurrentUserTabsDoesNotAsk() {
        let f = PersistedWorld(currentApproved: false); defer { f.dispose() }
        let w = f.world
        w.browser.lay([w.user, w.other])
        w.browser.activeID = w.other.id
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = NativeControl(file: folder.appendingPathComponent("operations.json"))
        let got = f.request(control)
        #expect(got["status"] as? String == "verified", "\(got)")
        #expect(w.browser.spaceID == f.destination)
    }

    @Test(arguments: [AgentAsking.ask, .auto, .bypass], [false, true])
    func openLeavesAnExistingUserPageAlone(mode: AgentAsking, front: Bool) async {
        let w = World(front: front, mode: mode); defer { w.dispose() }
        let count = w.browser.tabs.count
        let got = await w.ask(["do": "open", "url": w.url.absoluteString, "space": w.browser.space.name])
        #expect(got["error"] == nil, "\(got)")
        #expect(got["id"] as? String != Bench.short(w.user))
        #expect(got["theirs"] == nil)
        #expect(w.browser.tabs.count == count + 1)
        #expect(w.user.agent == nil && w.user.guest == nil && !w.user.bench)
        #expect(w.user.address == w.url && w.user.built == nil && w.user.permit == nil)
        #expect(!w.user.allowed.contains(w.session.id))
        #expect(w.browser.activeID == (front ? w.user.id : w.other.id))
        #expect(w.browser.tabs.contains { $0.bench && $0.agent == w.session.id && Bench.short($0) == got["id"] as? String })
    }

    @Test(arguments: [AgentAsking.ask, .auto, .bypass])
    func openLeavesAnIdleUserSiteAlone(mode: AgentAsking) async {
        let w = World(mode: mode); defer { w.dispose() }
        let got = await w.ask(["do": "open", "url": w.target.absoluteString, "space": w.browser.space.name])
        #expect(got["error"] == nil && got["asking"] == nil, "\(got)")
        #expect(got["id"] as? String != Bench.short(w.user))
        #expect(got["theirs"] == nil)
        #expect(w.user.address == w.url && w.user.built == nil)
        #expect(w.user.agent == nil && w.user.guest == nil && !w.user.bench)
        #expect(!w.user.allowed.contains(w.session.id) && w.user.permit == nil)
    }

    @Test(arguments: [AgentAsking.ask, .auto, .bypass], [false, true])
    func openPreservesPinnedAndKeptProgress(mode: AgentAsking, samePage: Bool) async {
        let w = World(mode: mode); defer { w.dispose() }
        w.user.pin = "P"
        w.other.kept = true
        w.other.restore(url: w.url, title: "Kept progress")
        let got = await w.ask(["do": "open", "url": (samePage ? w.url : w.target).absoluteString,
                               "space": w.browser.space.name])
        #expect(got["error"] == nil && got["asking"] == nil, "\(got)")
        #expect(got["id"] as? String != Bench.short(w.user))
        #expect(got["id"] as? String != Bench.short(w.other))
        #expect(w.user.address == w.url && w.other.address == w.url)
        #expect(w.user.pin == "P" && w.other.kept)
        #expect(w.user.builtPage == nil && w.other.builtPage == nil)
        #expect(w.user.guest == nil && w.other.guest == nil)
        #expect(w.user.permit == nil && w.other.permit == nil)
    }

    /// Even an explicit invitation doesn't make open reload that tab.
    /// Work there continues by id, as contextualGrantAllowsFrontTabNavigation checks.
    @Test func openDoesNotReloadAnExplicitlyGivenTab() async {
        let w = World(front: true); defer { w.dispose() }
        w.user.allowed.insert(w.session.id)
        let got = await w.ask(["do": "open", "url": w.url.absoluteString, "space": w.browser.space.name])
        #expect(got["error"] == nil, "\(got)")
        #expect(got["id"] as? String != Bench.short(w.user))
        #expect(w.user.address == w.url && w.user.builtPage == nil && w.user.guest == nil)
        #expect(w.user.allowed.contains(w.session.id))
    }

    @Test(arguments: [AgentAsking.auto, .bypass])
    func contextualGrantAllowsFrontTabNavigation(mode: AgentAsking) async {
        let w = World(front: true, mode: mode); defer { w.dispose() }
        w.user.allowed.insert(w.session.id)
        let got = await w.ask(["do": "agent-go", "id": Bench.short(w.user), "url": w.target.absoluteString])
        #expect(got["error"] == nil, "\(got)")
        #expect(w.user.address == w.target && w.user.guest == w.session.id)
        #expect(w.user.permit == nil)
    }

    @Test func frontTabWithoutContextStillCannotBeNavigated() {
        let w = World(front: true, mode: .bypass); defer { w.dispose() }
        var answer: [String: Any] = [:]
        let call = AgentCall(bench: w.bench, verb: "agent-go",
                             request: ["session": w.session.id, "id": Bench.short(w.user)],
                             browser: w.browser) { answer = $0 }
        #expect(call.own(going: true) == nil)
        #expect(answer["error"] != nil)
        #expect(w.user.address == w.url && w.user.builtPage == nil)
    }

    @Test(arguments: [AgentAsking.auto, .bypass])
    func backgroundUserTabAccessFollowsTheAgentSetting(mode: AgentAsking) {
        let w = World(mode: mode); defer { w.dispose() }
        var answer: [String: Any] = [:]
        let call = AgentCall(bench: w.bench, verb: "nav",
                             request: ["session": w.session.id, "id": Bench.short(w.user)],
                             browser: w.browser) { answer = $0 }
        #expect(call.own(going: true) === w.user, "\(answer)")
        #expect(w.user.guest == w.session.id && w.user.permit == nil)
    }

    @Test func askModeStillNeedsAUseGrantForEachTab() {
        let w = World(mode: .ask); defer { w.dispose() }
        w.permitUser()
        var answer: [String: Any] = [:]
        let yes = AgentCall(bench: w.bench, verb: "act",
                            request: ["session": w.session.id, "id": Bench.short(w.user)],
                            browser: w.browser) { answer = $0 }
        #expect(yes.own() === w.user, "\(answer)")
        let no = AgentCall(bench: w.bench, verb: "act",
                           request: ["session": w.session.id, "id": Bench.short(w.other)],
                           browser: w.browser) { answer = $0 }
        #expect(no.own() == nil)
        #expect(answer["asking"] as? Bool == true)
        #expect(!w.other.allowed.contains(w.session.id))
    }

    @Test func aStoppedSessionCannotKeepAUseGrant() {
        let w = World(mode: .bypass); defer { w.dispose() }
        w.permitUser()
        w.session.state = .stopped
        var answer: [String: Any] = [:]
        let call = AgentCall(bench: w.bench, verb: "agent-go",
                             request: ["session": w.session.id, "id": Bench.short(w.user)],
                             browser: w.browser) { answer = $0 }
        #expect(call.own(going: true) == nil)
        #expect(answer["error"] != nil)
        #expect(w.user.address == w.url && w.user.builtPage == nil)
    }

    @Test(arguments: [false, true])
    func nativeCloseDoesNotAskAndRemainsUndoable(front: Bool) {
        let w = World(front: front, mode: .bypass); defer { w.dispose() }
        let addresses = w.browser.tabs.map(\.address)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = NativeControl(file: folder.appendingPathComponent("operations.json"))
        let got = w.native(control, ["action": "tabs.close", "target": ["kind": "space", "id": w.browser.spaceID.uuidString],
                                     "arguments": ["tabs": [w.user.id.uuidString]], "requestId": "close-user"])
        #expect(got["status"] as? String == "verified", "\(got)")
        #expect(!w.browser.tabs.contains { $0 === w.user })
        #expect(w.browser.tabs.contains { $0 === w.other })
        var undone: [String: Any] = [:]
        control.handle("agent-native-undo", request: ["session": w.session.id, "changeId": got["operationId"] ?? ""],
                       browser: w.browser) { undone = $0 }
        #expect(undone["status"] as? String == "verified", "\(undone)")
        #expect(undone["undone"] as? Bool == true)
        let reopened = undone["reopened"] as? [String] ?? []
        #expect(reopened.count == 1)
        #expect(w.browser.tabs.contains { reopened.contains($0.id.uuidString) && $0.address == w.url })
        #expect(w.browser.tabs.map(\.address) == addresses)
    }

    @Test(arguments: ["tabs.rename", "tabs.reorder", "tabs.move", "space.switch"], [AgentAsking.auto, .bypass])
    func nativeUserTabMutationsFollowTheAgentSetting(action: String, mode: AgentAsking) {
        let w = World(mode: mode); defer { w.dispose() }
        let enabled = Store.settings.object(forKey: "spaces")
        w.browser.prefs.usesSpaces = true
        defer { Store.settings.set(enabled, forKey: "spaces") }
        let originalSpace = w.browser.spaceID
        let originalOrder = w.browser.tabs.map(\.id)
        let destination = w.browser.addSpace(named: "Ownership fixture " + UUID().uuidString, ownSignIns: false, show: false)
        defer {
            if w.browser.spaceID != originalSpace { w.browser.switchSpace(to: originalSpace) }
            w.browser.deleteSpace(destination)
        }
        let parked = Tab()
        parked.restore(url: URL(string: "about:blank#parked-fixture")!, title: "Parked fixture")
        w.browser.parked[destination] = Parked(tabs: [parked], active: parked.id)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = NativeControl(file: folder.appendingPathComponent("operations.json"))
        let target: [String: String]
        let arguments: [String: Any]
        switch action {
        case "tabs.rename": target = ["kind": "tab", "id": w.user.id.uuidString]; arguments = ["name": "Changed fixture"]
        case "tabs.reorder": target = ["kind": "space", "id": originalSpace.uuidString]; arguments = ["tabs": [w.other.id.uuidString, w.user.id.uuidString]]
        case "tabs.move": target = ["kind": "space", "id": destination.uuidString]; arguments = ["tabs": [w.user.id.uuidString]]
        default: target = ["kind": "space", "id": destination.uuidString]; arguments = [:]
        }
        let got = w.native(control, ["action": action, "target": target, "arguments": arguments, "requestId": "setting-" + action])
        #expect(got["status"] as? String == "verified", "\(action): \(got)")
        switch action {
        case "tabs.rename": #expect(w.user.name == "Changed fixture")
        case "tabs.reorder": #expect(w.browser.tabs.map(\.id) == Array(originalOrder.reversed()))
        case "tabs.move": #expect(!w.browser.tabs.contains { $0 === w.user })
        default: #expect(w.browser.spaceID == destination)
        }
    }

    @Test func genericCloseStillLeavesAUserTabOpen() async {
        let w = World(); defer { w.dispose() }
        let got = await w.ask(["do": "close", "id": Bench.short(w.user)])
        #expect(got["error"] != nil)
        #expect(w.browser.tabs.contains { $0 === w.user })
        #expect(w.user.address == w.url && w.user.builtPage == nil)
    }
}
