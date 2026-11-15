import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumSleepTests {
    @Test func freezeAndDiscardReceiptsStayDistinctAndNativeSilenceIsKnown() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        page.receiveSleep(["frozen": .bool(true)])
        #expect(page.sleepState.frozen && !page.sleepState.discarded)
        page.receiveSleep(["nativeDiscard": .bool(true), "audibleSource": .string("native"), "audible": .bool(false)])
        #expect(page.sleepState.supported && page.media.report.native && !page.media.report.audible)
        page.receiveSleep(["nativeDiscard": .number(0)])
        #expect(!page.sleepState.supported)
        page.receiveSleep(["nativeDiscard": .number(1)])
        #expect(page.sleepState.supported)
        page.receiveSleep(["nativeDiscard": .string("true")])
        #expect(!page.sleepState.supported)
        page.receiveSleep(["discarded": .bool(true)])
        #expect(page.sleepState.discarded && page.contentProcess == nil)
        #expect(tab.deaf == nil && !tab.deafAsked && tab.deafQuiet == .distantPast)
        #expect(!tab.asks.contains { $0.kind == .stuck })
        page.receiveSleep(["discarded": .bool(false), "frozen": .bool(false)])
        #expect(!page.sleepState.discarded && !page.sleepState.frozen)
    }

    @Test func lateRendererIdentityCannotReattachADiscardedDocument() {
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        let remote = "sleep-" + UUID().uuidString
        page.adoptRemote(remote)
        defer {
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            tab.close()
        }
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote), "rendererPID": .number(42)]))
        #expect(page.contentProcess == 42)
        page.receiveSleep(["discarded": .bool(true)])
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote), "rendererPID": .number(42)]))
        #expect(page.sleepState.discarded && page.contentProcess == nil)
        page.receive(YabCoreEvent(name: "page.state", params: ["tab": .string(remote), "discarded": .bool(false), "rendererPID": .number(43)]))
        #expect(!page.sleepState.discarded && page.contentProcess == 43)
    }

    @Test(.enabled(if: ForcedEngine.chromium, "Needs the signed own-CEF app"))
    func nativeDiscardKeepsControllerHistoryAndScrollAndCloseReleasesIt() async throws {
        let browser = Browser(windowID: UUID())
        let first = URL(string: "data:text/html,<title>First</title><p>First</p>")!
        let second = URL(string: "data:text/html,<title>Second</title><body%20style='height:8000px'>Second</body>")!
        let tab = browser.open(first, foreground: true)
        defer { for tab in browser.tabs { tab.close() } }
        let page = try #require(tab.builtPage as? ChromiumPage)
        try #require(try await Loaded.until(20) { page.contentProcess != nil && !tab.loading })
        tab.go(to: second)
        try #require(try await Loaded.until(20) { page.url == second && page.canGoBack && !tab.loading })
        _ = try await page.run("scrollTo(0,2400); scrollY", gesture: false)
        let scroll = try #require(try await page.run("scrollY", gesture: false) as? Double)
        let remote = try #require(page.remoteID)
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        // Seed after selection, whose own cleanup must not satisfy this check.
        tab.deaf = Date(); tab.deafAsked = true; tab.deafQuiet = .distantFuture
        browser.ask(PageAsk(kind: .stuck, host: "sleep fixture"), on: tab) { _, _ in }
        let slept = await withCheckedContinuation { reply in
            tab.sleep(picture: nil) { reply.resume(returning: $0) }
        }
        try #require(slept && tab.asleep && tab.builtPage == nil)
        #expect(page.sleepState.discarded && page.contentProcess == nil)
        #expect(page.remoteID == remote)
        #expect(tab.wake())
        try #require(tab.builtPage === page && page.remoteID == remote)
        try #require(try await Loaded.until(20) { page.contentProcess != nil && !tab.loading })
        #expect(try await page.run("document.wasDiscarded", gesture: false) as? Bool == true)
        #expect(page.canGoBack)
        #expect(try await Loaded.until(10) { try await page.run("scrollY", gesture: false) as? Double == scroll })
        page.navigateBack()
        try #require(try await Loaded.until(20) { page.url == first && !tab.loading })
        #expect(page.canGoForward)
        tab.close()
        #expect(page.remoteID == nil)
    }

    @Test(.enabled(if: ForcedEngine.chromium, "Needs the signed own-CEF app"))
    func aSleepingTabRecoversAfterItsHelperIsLost() async throws {
        let browser = Browser(windowID: UUID())
        let url = URL(string: "data:text/html,<title>Sleeping%20recovery</title>")!
        let tab = browser.open(url, foreground: true)
        defer { for tab in browser.tabs { tab.close() } }
        let old = try #require(tab.builtPage as? ChromiumPage)
        _ = try await old.run("document.title", gesture: false)
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        let slept = await withCheckedContinuation { reply in
            tab.sleep(picture: nil) { reply.resume(returning: $0) }
        }
        try #require(slept && tab.asleep)
        ChromiumProcess.shared.crashForTesting()
        try #require(try await Loaded.until(15) { old.remoteID == nil })
        #expect(tab.wake())
        let fresh = try #require(tab.builtPage as? ChromiumPage)
        #expect(fresh !== old)
        #expect(try await Loaded.until(15) { try await fresh.run("document.title", gesture: false) as? String == "Sleeping recovery" })
        #expect(fresh.url == url && !tab.asleep)
    }

    @Test(.enabled(if: ForcedEngine.chromium, "Needs the signed own-CEF app"))
    func aConfigurationReplacementClosesItsOldRemoteBrowser() async throws {
        let browser = Browser(windowID: UUID())
        let url = URL(string: "data:text/html,<title>Replacement</title>")!
        let tab = browser.open(url, foreground: true)
        defer { tab.close(); for tab in browser.tabs { tab.close() } }
        let old = try #require(tab.builtPage as? ChromiumPage)
        _ = try await old.run("document.title", gesture: false)
        let remote = try #require(old.remoteID)
        browser.replaceBlank(tab, with: url)
        let current = try #require(browser.tabs.first { $0.id == tab.id })
        #expect(current !== tab && current.engineKind == .chromium)
        #expect(tab.gone && old.remoteID == nil && old.contentProcess == nil)
        let page = try #require(current.builtPage as? ChromiumPage)
        #expect(try await page.run("document.title", gesture: false) as? String == "Replacement")
        #expect(page.remoteID != remote)
    }

    @Test(.enabled(if: ForcedEngine.chromium, "Needs the signed own-CEF app"))
    func nativeFreezePreservesTheDocumentAndUnfreezeResumesItsTimer() async throws {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "data:text/html,<title>Freeze</title><script>window.n=0;setInterval(()=>n++,30)</script>")!, foreground: true)
        defer { for tab in browser.tabs { tab.close() } }
        let page = try #require(tab.builtPage as? ChromiumPage)
        _ = try await page.run("window.token='same';n", gesture: false)
        _ = browser.open(URL(string: "about:blank#front")!, foreground: true)
        try #require(await page.freezeForSleep(true))
        #expect(page.sleepState.frozen && !page.sleepState.discarded)
        try await Task.sleep(for: .milliseconds(300))
        try #require(await page.freezeForSleep(false))
        let first = try #require(try await page.run("n", gesture: false) as? Int)
        #expect(try await Loaded.until(5) { (try await page.run("n", gesture: false) as? Int ?? 0) > first })
        #expect(try await page.run("token", gesture: false) as? String == "same")
    }
}
