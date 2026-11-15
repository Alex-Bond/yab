import Foundation
import Testing
import WebKit
@testable import Fast

/// Feedback472's actual page overlay, with the chat/browser still alive.
/// A tool must report this state without restarting the document it stopped.
@MainActor
@Suite(.serialized)
struct AgentMemoryStopTests {
    private static let stopped = "This page kept taking more memory, so Yab stopped it"
    private static let notice = "The page grew to 2.0 GB of memory again after Yab loaded it again, so Yab stopped it. Don't open it again in this task; tell the user this page uses too much memory."

    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let tab: Tab
        let bench = Bench()

        init(privatePage: Bool = false, nativeWebKit: Bool = false) {
            // Native termination/eval-world cases opt in; ordinary metadata cases keep the selected engine.
            tab = Tab(shy: privatePage, bench: true, factory: nativeWebKit ? .webKitOnly : nil)
            browser.lay([])
            browser.activeID = nil
            tab.agent = Agents.script
            tab.restore(url: URL(string: "https://figma.invalid/design/large-file")!, title: "Large design")
            tab.failure = AgentMemoryStopTests.stopped
            StuckWatch.notices[tab.id] = AgentMemoryStopTests.notice
            browser.lay([tab])
        }

        func close() {
            if let window = tab.builtPage?.window, window.identifier == Bench.roomID { window.close() }
            tab.close()
            browser.lay([])
            StuckWatch.notices[tab.id] = nil
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }

        func ask(_ verb: String, _ extra: [String: Any] = [:]) -> [String: Any]? {
            var received: [String: Any]?
            begin(verb, extra) { received = $0 }
            return received
        }

        func begin(_ verb: String, _ extra: [String: Any] = [:], answer: @escaping ([String: Any]) -> Void) {
            let request: [String: Any] = ["id": Bench.short(tab), "session": Agents.script]
            bench.agentCommand(verb, request.merging(extra) { _, next in next }, browser: browser, answer)
        }
    }

    @Test func stoppedSnapshotReturnsImmediatelyWithoutWaking() {
        let world = World(); defer { world.close() }
        #expect(world.tab.builtPage == nil)
        #expect(world.tab.asleep)
        let response = world.ask("snapshot")
        #expect(response?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
        #expect((response?["error"] as? String)?.contains("Don't reload") == true)
        #expect(world.tab.failure == Self.stopped)
        #expect(world.tab.asleep)
        #expect(world.tab.builtPage == nil)
        // The stop is persistent, rather than a once-only notice consumed
        // by the first error while the next call wakes the same document.
        let second = world.ask("snapshot")
        #expect(second?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
        let reopen = world.ask("agent-go", ["url": world.tab.address!.absoluteString])
        #expect(reopen?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
        #expect(world.tab.builtPage == nil)
    }

    @Test func stoppedPageCannotBeReloadedOrEvaluatedByTheAgent() {
        for verb in ["nav", "agent-eval", "agent-fetch", "settle", "act", "press"] {
            let world = World(); defer { world.close() }
            let response = world.ask(verb, ["how": "reload", "js": "document.title", "url": "https://figma.invalid/api/design", "keys": "Return"])
            #expect(response?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY", "\(verb) did not report the browser's stop")
            #expect(world.tab.failure == Self.stopped, "\(verb) cleared the page's stop")
            #expect(world.tab.builtPage == nil, "\(verb) constructed a page")
        }
    }

    @Test func anUnrelatedPageErrorKeepsItsExistingToolPath() {
        let world = World(); defer { world.close() }
        world.tab.failure = "A different page error"
        // Invalid input returns before touching WebKit. It must retain the
        // existing fetch validation, rather than become a memory stop.
        let response = world.ask("agent-fetch", ["url": "https://other.example.test/"])
        #expect(response?["code"] == nil)
        #expect((response?["error"] as? String)?.contains("own site") == true)
        #expect(world.tab.builtPage == nil)
    }

    @Test func aReloadNoticeIsIncludedWhenAToolFails() {
        let world = World(); defer { world.close() }
        world.tab.failure = nil
        let notice = "The page grew to 2.0 GB of memory, so Yab loaded it again at the same address: what you did on it before is gone, read it again."
        StuckWatch.notices[world.tab.id] = notice
        let response = world.ask("agent-fetch", ["url": "https://elsewhere.example.test/"])
        #expect((response?["error"] as? String)?.contains("own site") == true)
        #expect((response?["error"] as? String)?.contains(notice) == true)
        #expect(StuckWatch.notices[world.tab.id] == nil)
    }

    @Test func aSuccessfulNonSnapshotToolLeavesTheReloadNoticeForTheNextRead() {
        let world = World(); defer { world.close() }
        world.tab.failure = nil
        let notice = "Yab loaded this page again to save memory. Read it again."
        StuckWatch.notices[world.tab.id] = notice
        let response = world.ask("agent-downloads")
        #expect(response?["error"] == nil)
        #expect(response?["files"] != nil)
        #expect(response?["alerts"] == nil)
        #expect(StuckWatch.notices[world.tab.id] == notice)
    }

    @Test func aStoppedTabAnywhereInASaveBatchStopsBeforeAnyDocumentStarts() {
        for format in ["pdf", "md", "txt"] {
            let world = World(privatePage: true); defer { world.close() }
            let healthy = Tab(shy: true, bench: true), unrelated = Tab(shy: true, bench: true)
            defer { healthy.close(); unrelated.close() }
            healthy.restore(url: URL(string: "https://healthy.invalid/article")!, title: "Article")
            unrelated.restore(url: URL(string: "https://unrelated.invalid/article")!, title: "Unrelated")
            world.browser.lay([healthy, world.tab, unrelated])
            // MCP supplies id=first, but the native verb also accepts a
            // tabs list alone or with an unrelated id. tabs wins each time.
            for id in [Bench.short(healthy), "", Bench.short(unrelated)] {
                var request: [String: Any] = ["tabs": [Bench.short(healthy), Bench.short(world.tab)],
                                              "session": Agents.script, "format": format]
                if !id.isEmpty { request["id"] = id }
                var response: [String: Any]?
                world.bench.agentCommand("agent-pdf", request, browser: world.browser) { response = $0 }
                #expect(response?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
                #expect(response?["url"] as? String == world.tab.address?.absoluteString)
                #expect(healthy.builtPage == nil)
                #expect(world.tab.builtPage == nil)
                #expect(unrelated.builtPage == nil)
            }
        }
    }

    @Test func aSaveBatchIgnoresTheUnselectedIdTab() {
        let world = World(privatePage: true); defer { world.close() }
        let selected = Tab(shy: true, bench: true); defer { selected.close() }
        selected.restore(url: URL(string: "https://healthy.invalid/article")!, title: "Article")
        world.browser.lay([selected, world.tab])
        let response = world.ask("agent-pdf", ["tabs": [Bench.short(selected)], "format": "unsupported"])
        #expect(response?["code"] == nil)
        #expect((response?["error"] as? String)?.contains("save_page makes") == true)
        #expect(selected.builtPage == nil)
        #expect(world.tab.builtPage == nil)
        #expect(StuckWatch.notices[world.tab.id] == Self.notice)
    }

    @Test func thePersonsTryAgainCanRecoverTheSameAddress() {
        let world = World(privatePage: true); defer { world.close() }
        let address = world.tab.address
        // This is Tab.reload's real path used by the person's Try Again,
        // before any tool has consumed the notice. No memory limit changes.
        world.tab.reload()
        #expect(world.tab.failure == nil)
        #expect(world.tab.address == address)
        #expect(StuckWatch.notices[world.tab.id] == nil)
        let response = world.ask("agent-fetch", ["url": "https://elsewhere.example.test/"])
        #expect(response?["code"] == nil)
        #expect((response?["error"] as? String)?.contains("own site") == true)
        let error = response?["error"] as? String ?? ""
        #expect(error.contains("Don't open") == false)
        #expect(response?["alerts"] == nil)
    }

    @Test func navigationAwayAsTheFirstToolCallDoesNotCarryTheOldStop() {
        let world = World(privatePage: true); defer { world.close() }
        let response = world.ask("agent-go", ["url": "about:blank"])
        #expect(world.tab.address?.absoluteString == "about:blank")
        #expect(world.tab.failure == nil)
        #expect(response?["error"] == nil)
        #expect(response?["code"] == nil)
        #expect(response?["alerts"] == nil)
        #expect(StuckWatch.notices[world.tab.id] == nil)
    }

    @Test func navigationAwayBeforeTheTerminationCallbackDetachesTheStoppedDocument() {
        let world = World(privatePage: true, nativeWebKit: true); defer { world.close() }
        world.tab.failure = nil
        let oldWeb = requireNativeWebKitFixture(world.tab, "AgentMemoryStopTests")
        world.browser.stuck.outgrown.insert(world.tab.id)
        StuckWatch.notices[world.tab.id] = Self.notice
        // StuckWatch has requested a kill; Dialogs has not received it yet.
        let reopen = world.ask("agent-go", ["url": world.tab.address!.absoluteString])
        #expect(reopen?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
        #expect(world.tab.builtPage === oldWeb)
        StuckWatch.notices[world.tab.id] = Self.notice
        let response = world.ask("agent-go", ["url": "about:blank"])
        #expect(response?["error"] == nil)
        #expect(response?["code"] == nil)
        #expect(world.tab.address?.absoluteString == "about:blank")
        #expect(world.tab.failure == nil)
        #expect(world.tab.builtPage !== oldWeb)
        #expect(world.browser.tab(for: oldWeb) == nil)
        #expect(!world.browser.stuck.outgrown.contains(world.tab.id))
        #expect(StuckWatch.notices[world.tab.id] == nil)
        // The actual native delegate path for the old document must not
        // turn the new destination into a memory-stopped page.
        world.browser.webViewWebContentProcessDidTerminate(oldWeb)
        #expect(world.tab.failure == nil)
        let next = world.ask("agent-fetch", ["url": "https://elsewhere.example.test/"])
        #expect(next?["code"] == nil)
        #expect((next?["error"] as? String)?.contains("own site") == true)
    }

    @Test func navigationAcrossASpecialRouteKeepsItsExistingDispatch() {
        let world = World(privatePage: true, nativeWebKit: true); defer { world.close() }
        world.tab.failure = nil
        let oldWeb = requireNativeWebKitFixture(world.tab, "AgentMemoryStopTests")
        let address = world.tab.address
        world.browser.stuck.outgrown.insert(world.tab.id)
        StuckWatch.notices[world.tab.id] = Self.notice
        let destination = URL(string: "yab-artifact://memory-stop-route/index.html")!
        var routed: URL?
        world.tab.onCross = { _, url in routed = url }
        let response = world.ask("agent-go", ["url": destination.absoluteString])
        #expect(routed == destination)
        #expect(world.tab.address == address)
        #expect(world.tab.builtPage === oldWeb)
        #expect(world.browser.stuck.outgrown.contains(world.tab.id))
        #expect(StuckWatch.notices[world.tab.id] == Self.notice)
        #expect(response?["code"] == nil)
    }

    @Test func aSpecialRouteReplacementDoesNotInheritTheOldTabsMemoryStop() {
        for pendingStop in [false, true] {
            let world = World(privatePage: true, nativeWebKit: true); defer { world.close() }
            if pendingStop { world.tab.failure = nil }
            let oldWeb = requireNativeWebKitFixture(world.tab, "AgentMemoryStopTests")
            if pendingStop { world.browser.stuck.outgrown.insert(world.tab.id) }
            StuckWatch.notices[world.tab.id] = Self.notice
            let destination = URL(string: "yab-artifact://memory-stop-replacement/index.html")!
            world.tab.onCross = { tab, url in world.browser.replaceBlank(tab, with: url) }
            let response = world.ask("agent-go", ["url": destination.absoluteString])
            let replacement = world.browser.tabs.first { $0.id == world.tab.id }
            defer { replacement?.close() }
            #expect(replacement != nil)
            #expect(replacement !== world.tab)
            #expect(replacement?.address == destination)
            #expect(replacement?.failure == nil)
            #expect(response?["error"] == nil)
            #expect(response?["code"] == nil)
            #expect(response?["url"] as? String == destination.absoluteString)
            #expect(world.browser.tab(for: oldWeb) == nil)
            #expect(!world.browser.stuck.outgrown.contains(world.tab.id))
            #expect(StuckWatch.notices[world.tab.id] == nil)
            world.browser.webViewWebContentProcessDidTerminate(oldWeb)
            #expect(replacement?.failure == nil)
            var next: [String: Any]?
            world.bench.agentCommand("agent-fetch", ["id": world.tab.id.uuidString, "url": "https://elsewhere.example.test/", "session": Agents.script], browser: world.browser) { next = $0 }
            #expect(next?["code"] == nil)
            #expect((next?["error"] as? String)?.contains("own site") == true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func anInFlightEvalFailureReportsTheStopAndNavigationAwayStillWorks() async throws {
        let world = World(privatePage: true, nativeWebKit: true); defer { world.close() }
        world.tab.failure = nil
        StuckWatch.notices[world.tab.id] = nil
        let web = requireNativeWebKitFixture(world.tab, "AgentMemoryStopTests")
        web.loadHTMLString("<title>Memory lifecycle fixture</title>", baseURL: world.tab.address)
        var loaded = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.title")) as? String == "Memory lifecycle fixture" { loaded = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(loaded, "owned WebKit fixture did not load")
        var response: [String: Any]?
        world.begin("agent-eval", ["js": "new Promise((resolve, reject) => { window.__memoryStopTestStarted = true; setTimeout(() => reject(new Error('interrupted memory fixture')), 1500); })"]) { response = $0 }
        var started = false
        for _ in 0..<100 {
            let flag = await withCheckedContinuation { done in
                web.evaluateJavaScript("window.__memoryStopTestStarted === true", in: nil, in: AgentPage.evalWorld) { result in
                    done.resume(returning: (try? result.get()) as? Bool == true)
                }
            }
            if flag { started = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(started, "the actual eval was not in flight; response: \(String(describing: response))")
        // The exact state Dialogs writes for StuckWatch.outgrown. A live
        // Figma OOM is not fabricated here: this isolates its tool lifecycle.
        world.tab.failure = Self.stopped
        StuckWatch.notices[world.tab.id] = Self.notice
        for _ in 0..<100 where response == nil { try await Task.sleep(for: .milliseconds(50)) }
        try #require(response != nil, "the in-flight eval never answered")
        #expect(response?["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
        #expect((response?["error"] as? String)?.contains("Don't reload") == true)
        #expect(world.tab.failure == Self.stopped)
        world.tab.go(to: URL(string: "about:blank")!)
        #expect(world.tab.failure == nil)
        let next = world.ask("agent-fetch", ["url": "https://elsewhere.example.test/"])
        #expect(next?["code"] == nil)
        let error = next?["error"] as? String ?? ""
        #expect(error.contains("Don't reload") == false)
    }
}
