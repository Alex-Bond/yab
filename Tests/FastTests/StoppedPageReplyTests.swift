import Foundation
import Testing
import WebKit
@testable import Fast

/// A tab's replacement keeps its UUID, but owns its own memory notice.
/// Late native tool replies still describe their original document.
@MainActor
@Suite(.serialized)
struct StoppedPageReplyTests {
    private static let notice = "Yab loaded the replacement page again to save memory. Read it again."
    private static let rejection = "old document reply fixture"

    @MainActor private final class Reply {
        var value: [String: Any]?
    }

    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let tab = Tab(shy: true, bench: true, factory: .webKitOnly)
        let bench = Bench()

        init() {
            browser.lay([])
            browser.activeID = nil
            tab.agent = Agents.script
            tab.setAddressOptimistically(URL(string: "https://old-reply.invalid/design")!)
            browser.lay([tab])
        }

        func close() {
            var closed = Set<ObjectIdentifier>()
            for page in [tab] + browser.tabs + browser.parkedTabs + browser.outside where closed.insert(ObjectIdentifier(page)).inserted {
                if let window = page.built?.window, window.identifier == Bench.roomID { window.close() }
                page.close()
                StuckWatch.notices[page.id] = nil
            }
            browser.lay([])
            browser.parked = [:]
            browser.outside = []
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }

        func begin(_ verb: String, on page: Tab? = nil, _ extra: [String: Any] = [:]) -> Reply {
            let reply = Reply()
            let request: [String: Any] = ["id": (page ?? tab).id.uuidString, "session": Agents.script]
            bench.agentCommand(verb, request.merging(extra) { _, next in next }, browser: browser) { reply.value = $0 }
            return reply
        }

        func replace() throws -> Tab {
            let destination = URL(string: "about:blank")!
            browser.replaceBlank(tab, with: destination)
            let current = try #require(browser.tabs.first { $0.id == tab.id })
            try #require(current !== tab, "the actual replacement must create a new tab object")
            #expect(current.id == tab.id)
            #expect(current.address == destination)
            return current
        }
    }

    private static func load(_ tab: Tab, title: String) async throws -> WKWebView {
        try #require(Store.testing, "the native fixture must use an isolated test store")
        try #require(Store.unitTests, "the native fixture must run in the canonical unit-test host")
        try #require(Bench.socket.path.utf8.count < 104, "the isolated test world must fit the native Unix socket path")
        // The fixture drives a native WebKit document. A replacement made
        // by the standard factory under a forced remote engine has none.
        let web = try #require(tab.page.webKit, "the reply fixture needs a native WebKit page")
        web.loadHTMLString("<title>\(title)</title><main><button>\(title) owned document</button></main>", baseURL: URL(string: "https://reply-fixture.invalid/"))
        var loaded = false
        for _ in 0..<100 {
            if !web.isLoading,
               (try? await web.evaluateJavaScript("document.readyState === 'complete' && document.querySelector('main button') ? document.title : null")) as? String == title,
               !web.isLoading { loaded = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(loaded, "owned WebKit fixture did not load")
        try #require(!web.isLoading, "the loaded WK fixture must finish its native navigation")
        try #require(tab.failure == nil, "owned WebKit fixture has an unrelated failure")
        try #require(!tab.asleep, "the loaded fixture must not enter the sleeping-tab wake route")
        try #require(!tab.hollow, "the loaded fixture must hold its actual document")
        try #require(tab.built === web, "the loaded fixture must retain the same WK view")
        return web
    }

    private static func flag(_ script: String, in web: WKWebView) async -> Bool {
        await withCheckedContinuation { done in
            web.evaluateJavaScript(script, in: nil, in: AgentPage.evalWorld) { result in
                done.resume(returning: (try? result.get()) as? Bool == true)
            }
        }
    }

    private static func pendingEval(_ world: World, in web: WKWebView) async throws -> Reply {
        let reply = world.begin("agent-eval", ["js": "new Promise((resolve, reject) => { window.__replyStarted = true; window.__finish = () => reject(new Error('\(rejection)')); })"])
        var started = false
        for _ in 0..<100 {
            if await flag("window.__replyStarted === true", in: web) { started = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(started, "the actual native eval was not pending: \(String(describing: reply.value))")
        try #require(reply.value == nil, "the fixture answered before its explicit completion")
        return reply
    }

    private static func answer(_ reply: Reply) async throws -> [String: Any] {
        for _ in 0..<200 where reply.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(reply.value, "the actual native tool never answered")
    }

    private static func readReplacement(_ world: World, _ current: Tab) async throws {
        let snapshot = try await answer(world.begin("snapshot", on: current))
        #expect(snapshot["error"] == nil)
        #expect((snapshot["tree"] as? String)?.contains("Replacement document") == true)
        #expect((snapshot["alerts"] as? String)?.contains(notice) == true,
                "replacement snapshot must receive its own notice")
        #expect(StuckWatch.notices[current.id] == nil)
        let next = try await answer(world.begin("snapshot", on: current))
        #expect(next["error"] == nil)
        #expect((next["alerts"] as? String)?.contains(notice) != true)
        #expect(world.browser.tabs.first { $0.id == current.id } === current)
        #expect(current.failure == nil)
    }

    @Test(arguments: [false, true])
    func lateFailedEvalDoesNotConsumeReplacementNotice(stopped: Bool) async throws {
        let world = World(); defer { world.close() }
        let oldWeb = try await Self.load(world.tab, title: "Old document")
        let oldAddress = world.tab.address
        let pending = try await Self.pendingEval(world, in: oldWeb)
        if stopped { world.tab.failure = StuckWatch.memoryStopped }
        let current = try world.replace()
        _ = try await Self.load(current, title: "Replacement document")
        try #require(world.browser.tab(for: oldWeb) == nil)
        StuckWatch.notices[current.id] = Self.notice
        try #require(await Self.flag("window.__finish(); true", in: oldWeb), "the retained old WK document did not complete")
        let reply = try await Self.answer(pending)
        let error = reply["error"] as? String ?? ""
        if stopped {
            #expect(reply["code"] as? String == "PAGE_STOPPED_FOR_MEMORY")
            #expect(reply["url"] as? String == oldAddress?.absoluteString)
            #expect(error.contains("Don't reload"))
            #expect(world.tab.failure == StuckWatch.memoryStopped)
        } else {
            #expect(reply["code"] == nil)
            #expect(error.contains(Self.rejection))
        }
        #expect(StuckWatch.notices[current.id] == Self.notice && !error.contains(Self.notice),
                "late old tool reply must leave the replacement notice queued")
        try await Self.readReplacement(world, current)
        print("STOPPED_REPLY failedEval stopped=\(stopped) replacementRead=true")
    }

    @Test func lateSnapshotDoesNotConsumeReplacementNotice() async throws {
        let world = World(); defer { world.close() }
        let oldWeb = try await Self.load(world.tab, title: "Old document")
        let location = try await oldWeb.evaluateJavaScript("location.href")
        let oldURL = try #require(location as? String)
        try #require(!oldURL.isEmpty, "the old WK document must have its own URL")
        let oldDocumentReady = try await oldWeb.evaluateJavaScript("document.readyState === 'complete' && document.title === 'Old document' && !!document.querySelector('main button')")
        try #require(oldDocumentReady as? Bool == true, "the actual old DOM must finish loading before snapshot dispatch")
        try #require(!oldWeb.isLoading, "the snapshot must not race an unfinished native navigation")
        try #require(!world.tab.asleep, "the snapshot must read the awake old tab without a wake retry")
        try #require(!world.tab.hollow, "the snapshot must read the loaded old document")
        try #require(world.tab.built === oldWeb, "the snapshot must use the retained old WK view")
        try #require(world.browser.tab(for: oldWeb) === world.tab, "the old WK view must belong to the requested tab before dispatch")
        // No main-actor yield between dispatch and replacement: the native
        // snapshot callback still belongs to the original, retained page.
        let pending = world.begin("snapshot")
        try #require(pending.value == nil, "the actual snapshot must be in flight")
        let current = try world.replace()
        try #require(pending.value == nil, "the old snapshot must still be pending when the new notice is queued")
        StuckWatch.notices[current.id] = Self.notice
        let old = try await Self.answer(pending)
        #expect(old["error"] == nil)
        #expect(old["title"] as? String == "Old document")
        #expect(old["url"] as? String == oldURL)
        #expect(world.browser.tab(for: oldWeb) == nil)
        #expect(StuckWatch.notices[current.id] == Self.notice && !(old["alerts"] as? String ?? "").contains(Self.notice),
                "late old snapshot must leave the replacement notice queued")
        _ = try await Self.load(current, title: "Replacement document")
        try await Self.readReplacement(world, current)
        print("STOPPED_REPLY snapshot replacementRead=true")
    }

    @Test(arguments: ["current", "parked", "outside"])
    func aValidOwnerStillConsumesItsOwnNotice(location: String) async throws {
        let world = World(); defer { world.close() }
        let web = try await Self.load(world.tab, title: "Valid owner")
        let pending = try await Self.pendingEval(world, in: web)
        if location != "current" {
            world.browser.showRow([], active: nil)
            if location == "parked" { world.browser.parked[UUID()] = Parked(tabs: [world.tab], active: nil) }
            else { world.browser.outside.append(world.tab) }
        }
        try #require(world.bench.find(["id": world.tab.id.uuidString], in: world.browser) === world.tab)
        StuckWatch.notices[world.tab.id] = Self.notice
        try #require(await Self.flag("window.__finish(); true", in: web))
        let reply = try await Self.answer(pending)
        let error = reply["error"] as? String ?? ""
        #expect(reply["code"] == nil)
        #expect(error.contains(Self.rejection))
        #expect(error.contains(Self.notice))
        #expect(StuckWatch.notices[world.tab.id] == nil)
        print("STOPPED_REPLY validOwner location=\(location) noticeConsumed=true")
    }
}
