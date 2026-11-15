import Foundation
import Testing
import WebKit
import YabCoreClient
@testable import Fast

/// A site's "Leave this page?" (LeavePage.swift, register #1033): asked of
/// WebKit through `_tryClose`, answered by the page, the card's words.
@MainActor
@Suite(.serialized)
struct LeavePageTests {
    /// WebKit's word that the page may go, handed on as Browser hands it.
    private final class Closer: NSObject, WKUIDelegate, WKNavigationDelegate {
        var asked = 0
        var loaded = false
        func webViewDidClose(_ webView: WKWebView) { _ = Leaving.closed(webView) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
        func _webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            asked += 1
            completionHandler(false)
        }
    }

    private func page(_ html: String, _ closer: Closer) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.uiDelegate = closer
        web.navigationDelegate = closer
        web.loadHTMLString(html, baseURL: URL(string: "https://leave.test/")!)
        for _ in 0..<200 where !closer.loaded { try await Task.sleep(for: .milliseconds(25)) }
        try #require(closer.loaded, "The fixture page loads")
        return web
    }

    private func answer(_ web: WKWebView) async throws -> Bool? {
        var heard: Bool?
        Leaving.ask(web) { heard = $0 }
        for _ in 0..<200 where heard == nil { try await Task.sleep(for: .milliseconds(10)) }
        return heard
    }

    @Test func aPageWithNothingToSayMayGo() async throws {
        let closer = Closer()
        let web = try await page("<p>plain</p>", closer)
        #expect(try await answer(web) == true)
        #expect(closer.asked == 0)
        #expect(Leaving.waits.isEmpty)
    }

    /// WebKit lets a page ask only after someone used it: one that nobody
    /// touched goes without a word, after one trip to its process.
    @Test func aHandlerNobodyTouchedMayGo() async throws {
        let closer = Closer()
        let web = try await page("""
            <script>addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = 'x'; });
            addEventListener('unload', () => {});</script><p>draft</p>
            """, closer)
        #expect(try await answer(web) == true)
        #expect(closer.asked == 0)
        #expect(Leaving.waits.isEmpty, "Its answer heard through webViewDidClose, nothing left waiting")
    }

    @Test func tabsWithoutPagesCloseAtOnce() {
        let tab = Tab()
        tab.restore(url: URL(string: "https://leave.test/asleep")!, title: "Asleep")
        var said: Bool?
        Leaving.each([tab]) { said = $0 }
        #expect(said == true, "A tab with no page built has nothing to ask, answered in the same call")
        said = nil
        Leaving.each([]) { said = $0 }
        #expect(said == true)
    }

    @Test func chromiumViewWithoutANativeDocumentClosesInTheSameCall() throws {
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(engine: .chromium, factory: factory)
        let page = try #require(tab.page as? ChromiumPage)
        defer { tab.close() }
        #expect(page.remoteID == nil)
        var said: Bool?
        Leaving.each([tab]) { said = $0 }
        #expect(said == true, "A view without a native browser has no document to ask")
        #expect(page.remoteID == nil, "Closing must not create a native browser")
        #expect(Leaving.waits[ObjectIdentifier(page)] == nil)
    }

    @Test func aWithdrawnQueuedNativeQuestionNeverAppearsLater() throws {
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let browser = Browser(windowID: UUID())
        let first = Tab(engine: .chromium, factory: factory)
        let second = Tab(engine: .chromium, factory: factory)
        browser.outside.append(contentsOf: [first, second])
        defer {
            browser.dropAsks(first); browser.dropAsks(second)
            first.close(); second.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        let a = try #require(first.page as? ChromiumPage)
        let b = try #require(second.page as? ChromiumPage)
        Leaving.waits[ObjectIdentifier(a)] = Leaving.Wait { _ in }
        Leaving.waits[ObjectIdentifier(b)] = Leaving.Wait { _ in }
        var firstAnswers: [Bool] = [], secondAnswers: [Bool] = []
        Leaving.asked(a, by: browser, host: "a.test") { firstAnswers.append($0) }
        Leaving.asked(b, by: browser, host: "b.test") { secondAnswers.append($0) }
        #expect(first.asks.count == 1 && second.asks.isEmpty)
        Leaving.withdrawChromium(b)
        Leaving.withdrawChromium(a)
        #expect(first.asks.isEmpty && second.asks.isEmpty)
        #expect(firstAnswers == [false] && secondAnswers == [false])
        #expect(Leaving.waits[ObjectIdentifier(a)] == nil && Leaving.waits[ObjectIdentifier(b)] == nil)
    }

    @Test func confirmedOriginalCloseRetiresItsRowWhenCommitReplyIsLost() throws {
        let browser = Browser(windowID: UUID())
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        tab.restore(url: URL(string: "https://close.example/original")!, title: "Original document")
        browser.prepare(tab); browser.lay([tab]); browser.activeID = tab.id
        let page = try #require(tab.page as? ChromiumPage)
        let remote = "close-receipt-" + UUID().uuidString
        page.adoptRemote(remote)
        let entry = ChromiumCloseBatch.Entry(tab: tab, page: page, remote: remote)
        entry.request = "original-request"; entry.document = "original-document"; entry.token = "original-token"
        entry.committing = true
        ChromiumCloseBatch.active[ObjectIdentifier(page)] = entry
        defer {
            ChromiumCloseBatch.active[ObjectIdentifier(page)] = nil
            page.retire(call: false, pictureInPicture: false)
            ChromiumProcess.shared.detach(remote)
            tab.close(); browser.letGo()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
        }
        // A transport/helper loss is not evidence that native beforeunload closed.
        #expect(Leaving.chromiumClosed(page))
        #expect(!entry.closedConfirmed)
        ChromiumCloseBatch.retireClosedRows([entry], outcome: nil)
        #expect(!tab.gone)
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string("another-endpoint")]))
        #expect(!entry.closedConfirmed)
        page.receive(YabCoreEvent(name: "tab.closed", params: ["tab": .string(remote)]))
        #expect(entry.closedConfirmed && page.remoteID == nil && !tab.gone)
        // The final preflight receipt and aggregate RPC may both disappear after
        // the authenticated original endpoint death. tab.closed has no token body.
        ChromiumCloseBatch.retireClosedRows([entry], outcome: nil)
        #expect(tab.gone && !browser.tabs.contains { $0 === tab })
    }

    @Test func finalCloseConfirmationRequiresOriginalOwnerRequestDocumentAndToken() throws {
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in ChromiumPage(tab: tab) }
        let tab = Tab(shy: true, engine: .chromium, factory: factory)
        let page = try #require(tab.page as? ChromiumPage)
        let entry = ChromiumCloseBatch.Entry(tab: tab, page: page, remote: "original-endpoint")
        entry.request = "request"; entry.document = "document"; entry.token = "token"; entry.committing = true
        ChromiumCloseBatch.active[ObjectIdentifier(page)] = entry
        defer { ChromiumCloseBatch.active[ObjectIdentifier(page)] = nil; tab.close() }
        let receipt: [String: JSONValue] = ["tab": .string(entry.remote), "owner": .string(entry.owner),
            "version": .number(1), "request": .string("request"), "document": .string("document"),
            "token": .string("token"), "final": .bool(true), "phase": .string("closed"), "closed": .bool(true)]
        for field in ["tab", "owner", "request", "document", "token"] {
            var wrong = receipt; wrong[field] = .string("foreign")
            _ = page.receiveLifecycle(YabCoreEvent(name: "tab.closePreflight", params: wrong))
            #expect(!entry.closedConfirmed)
        }
        for field in ["owner", "version", "request", "document", "token"] {
            var missing = receipt; missing[field] = nil
            _ = page.receiveLifecycle(YabCoreEvent(name: "tab.closePreflight", params: missing))
            #expect(!entry.closedConfirmed, "Incomplete final receipt cannot confirm the original close")
        }
        var wrongVersion = receipt; wrongVersion["version"] = .number(2)
        _ = page.receiveLifecycle(YabCoreEvent(name: "tab.closePreflight", params: wrongVersion))
        #expect(!entry.closedConfirmed)
        _ = page.receiveLifecycle(YabCoreEvent(name: "tab.closePreflight", params: receipt))
        #expect(entry.closedConfirmed)
    }

    @Test func theCardSaysStayOrLeaveOverThePage() {
        let question = PageAsk(kind: .leave, host: "docs.example.com")
        #expect(question.centered)
        #expect(question.box == nil)
        #expect(!question.fromPage, "Not alert(): never hushed by the page's own box")
    }

    @Test func aWindowWithNoBrowserClosesAtOnce() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        var went = false
        Leaving.window(window) { went = true }
        #expect(went)
    }
}
