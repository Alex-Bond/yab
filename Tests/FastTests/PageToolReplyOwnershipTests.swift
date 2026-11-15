import AppKit
import Testing
@testable import Fast

/// Portable tool ownership contract. The retained-WK-document callback tests
/// remain separate controls; Chromium retires its remote document on replace.
@MainActor @Suite(.serialized)
struct PageToolReplyOwnershipTests {
    private static let notice = "Owned replacement memory notice"
    private static let rejection = "owned pending tool rejection"

    private final class Reply { var value: [String: Any]? }

    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let tab = Tab(shy: true, bench: true)
        let bench = Bench()

        init() {
            browser.lay([])
            browser.activeID = nil
            tab.agent = Agents.script
            browser.lay([tab])
        }

        func close() {
            var closed = Set<ObjectIdentifier>()
            for page in [tab] + browser.tabs + browser.parkedTabs + browser.outside
                where closed.insert(ObjectIdentifier(page)).inserted {
                if let window = page.builtPage?.window, window.identifier == Bench.roomID { window.close() }
                page.close()
                StuckWatch.notices[page.id] = nil
            }
            browser.lay([]); browser.parked = [:]; browser.outside = []
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }

        func begin(_ js: String, on owner: Tab? = nil) -> Reply {
            let reply = Reply()
            bench.agentCommand("agent-eval", ["id": (owner ?? tab).id.uuidString, "session": Agents.script,
                                             "js": js], browser: browser) { reply.value = $0 }
            return reply
        }
    }

    private func load(_ tab: Tab, title: String) async throws -> any PageHandle {
        let page = tab.page
        page.navigate(html: "<title>\(title)</title><main><button>Owned document</button></main>",
                      base: URL(string: "https://tool-reply.invalid/"))
        try #require(try await Loaded.until(20) {
            guard !tab.loading else { return false }
            return (try? await page.run("document.title", in: .agentEval)) as? String == title
        }, "the actual selected engine document must load")
        #expect(tab.builtPage === page && page.engine == tab.engineKind)
        return page
    }

    private func pending(_ world: World, _ page: any PageHandle) async throws -> Reply {
        let reply = world.begin("new Promise((resolve,reject)=>{window.__ownedReplyStarted=true;window.__ownedReplyFinish=()=>reject(new Error('\(Self.rejection)'));})")
        try #require(try await Loaded.until(10) {
            (try? await page.run("window.__ownedReplyStarted===true", in: .agentEval)) as? Bool == true
        }, "the real tool must be pending in the agent world")
        try #require(reply.value == nil)
        return reply
    }

    private func answer(_ reply: Reply) async throws -> [String: Any] {
        try #require(try await Loaded.until(10) { reply.value != nil }, "the real tool must finish")
        return try #require(reply.value)
    }

    @Test(arguments: ["current", "parked", "outside"])
    func aLiveOwnerConsumesOnlyItsOwnNotice(location: String) async throws {
        let world = World(); defer { world.close() }
        let page = try await load(world.tab, title: "Valid owner")
        let reply = try await pending(world, page)
        if location != "current" {
            world.browser.showRow([], active: nil)
            if location == "parked" { world.browser.parked[UUID()] = Parked(tabs: [world.tab], active: nil) }
            else { world.browser.outside.append(world.tab) }
        }
        try #require(world.bench.find(["id": world.tab.id.uuidString], in: world.browser) === world.tab)
        StuckWatch.notices[world.tab.id] = Self.notice
        #expect(try await page.run("window.__ownedReplyFinish(); true", in: .agentEval) as? Bool == true)
        let result = try await answer(reply)
        #expect(result["code"] == nil)
        #expect((result["error"] as? String)?.contains(Self.rejection) == true)
        #expect((result["error"] as? String)?.contains(Self.notice) == true)
        #expect(StuckWatch.notices[world.tab.id] == nil)
        #expect(world.tab.builtPage === page && !world.tab.asleep)
    }

    @Test(arguments: [false, true])
    func aRetiredToolCannotConsumeTheReplacementNotice(stopped: Bool) async throws {
        let world = World(); defer { world.close() }
        let old = try await load(world.tab, title: "Old owner")
        let address = world.tab.address
        let pending = try await pending(world, old)
        if stopped { world.tab.failure = StuckWatch.memoryStopped }
        world.browser.replaceBlank(world.tab, with: URL(string: "about:blank#replacement")!)
        let current = try #require(world.browser.tabs.first { $0.id == world.tab.id })
        try #require(current !== world.tab && current.id == world.tab.id)
        StuckWatch.notices[current.id] = Self.notice
        if old.engine == .webKit {
            // WebKit keeps a retained document callable. Chromium retirement
            // closes its remote document, which must finish the pending tool.
            #expect(try await old.run("window.__ownedReplyFinish(); true", in: .agentEval) as? Bool == true)
        }
        let result = try await answer(pending)
        let error = result["error"] as? String ?? ""
        #expect(!error.isEmpty && !error.contains(Self.notice))
        if stopped {
            #expect(result["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
            #expect(result["url"] as? String == address?.absoluteString)
            #expect(error.contains("Don't reload"))
        } else { #expect(result["code"] == nil) }
        #expect(StuckWatch.notices[current.id] == Self.notice)
        #expect(world.browser.tabs.first { $0.id == current.id } === current)
        _ = try await load(current, title: "Replacement owner")
        // A later failed tool really owned by the replacement consumes it.
        let own = try await answer(world.begin("throw new Error('replacement owned failure')", on: current))
        #expect((own["error"] as? String)?.contains(Self.notice) == true)
        #expect(StuckWatch.notices[current.id] == nil)
    }
}
