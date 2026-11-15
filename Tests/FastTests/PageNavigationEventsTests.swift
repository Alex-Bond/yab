import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageNavigationEventsTests {
    private class Listener: NSObject, PageEvents {
        var heard: [String] = []
        var navigations: [PageNavigation?] = []
        var reply: (@MainActor (PagePolicy) -> Void)?
        var failure: (Int, Bool)?

        func page(_ page: any PageHandle, ended reason: PageEnd?) { }

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            switch event {
            case .started(let id): heard.append("started"); navigations.append(id)
            case .redirected(let id): heard.append("redirected"); navigations.append(id)
            case .committed(let id): heard.append("committed"); navigations.append(id)
            case .finished(let id): heard.append("finished"); navigations.append(id)
            case .failed(let id, let error, let provisional):
                heard.append("failed"); navigations.append(id)
                failure = ((error as NSError).code, provisional)
            }
        }

        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) {
            heard.append("response")
            self.reply = reply
        }
    }

    private final class Document: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            if url.path == "/fail" {
                task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
                return
            }
            let body = Data("<title>Navigation seam</title><p>local document</p>".utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
            task.didReceive(body)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { }
    }

    private func makeView() -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(Document(), forURLScheme: "seam-navigation")
        return PageView(frame: .zero, configuration: configuration)
    }

    @Test func responseWaitsForTheReplyAndKeepsNavigationOrderAndIdentity() async throws {
        let view = makeView(), listener = Listener()
        let page: any PageHandle = view
        page.events = listener
        defer { page.stopLoading(); page.events = nil }
        let navigation = try #require(view.load(URLRequest(url: URL(string: "seam-navigation://local/page")!)))
        for _ in 0..<200 where listener.reply == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reply = try #require(listener.reply)
        #expect(listener.heard == ["started", "response"])
        // A held policy must not be auto-allowed when the callback returns.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!listener.heard.contains("committed"))
        reply(.allow)
        for _ in 0..<200 where !listener.heard.contains("finished") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(listener.heard == ["started", "response", "committed", "finished"])
        #expect(listener.navigations == Array(repeating: Optional(navigation.pageNavigation), count: 3))
        #expect(try await page.run("document.title") as? String == "Navigation seam")
        let value = navigation.pageNavigation
        #expect(try JSONDecoder().decode(PageNavigation.self, from: JSONEncoder().encode(value)) == value)
    }

    private final class ResponseCapture: NSObject, WKNavigationDelegate {
        var response: WKNavigationResponse?
        var finished = false
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            self.response = response
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    @Test(arguments: [PagePolicy.allow, .cancel, .download])
    func pendingPolicyAnswersOnceEvenAfterTheListenerMoves(policy: PagePolicy) async throws {
        let view = makeView(), capture = ResponseCapture(), listener = Listener(), next = Listener()
        // WKNavigationResponse has engine-owned state even in dealloc. Take
        // a real response rather than constructing an uninitialized subclass.
        view.navigationDelegate = capture
        defer { view.stopLoading(); view.events = nil; view.navigationDelegate = nil }
        view.navigate(to: URLRequest(url: URL(string: "seam-navigation://local/reply")!))
        for _ in 0..<200 where !capture.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(capture.finished)
        let response = try #require(capture.response)
        view.events = listener
        var answers: [WKNavigationResponsePolicy] = []
        view.navigationEvents.webView(view, decidePolicyFor: response) { answers.append($0) }
        #expect(answers.isEmpty)
        let reply = try #require(listener.reply)
        view.events = next
        reply(policy)
        reply(.cancel)
        #expect(answers == [policy.webKitResponse])
        #expect(next.heard.isEmpty)
    }

    @Test func aProvisionalFailureKeepsItsIdentityAndError() async throws {
        let view = makeView(), listener = Listener()
        view.events = listener
        defer { view.stopLoading(); view.events = nil }
        let navigation = try #require(view.load(URLRequest(url: URL(string: "seam-navigation://local/fail")!)))
        for _ in 0..<200 where listener.failure == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(listener.heard == ["started", "failed"])
        #expect(listener.navigations == [navigation.pageNavigation, navigation.pageNavigation])
        #expect(listener.failure?.0 == NSURLErrorCannotConnectToHost)
        #expect(listener.failure?.1 == true)
    }

    @Test func aLateFailureDoesNotRestoreThePageBeforeANewerNavigation() {
        let tab = Tab(shy: true)
        defer { tab.close() }
        let first = PageNavigation(), second = PageNavigation()
        tab.navigationStarted(first)
        tab.navigationStarted(second)
        tab.navigationFailedEarly(first)
        #expect(!tab.answered && !tab.stoppedEarly)
        tab.navigationFailedEarly(nil)
        #expect(!tab.answered && !tab.stoppedEarly)
        tab.navigationFailedEarly(second)
        #expect(tab.answered && tab.stoppedEarly)
    }

    @Test func thePageDoesNotRetainItsListenerAndDetachKeepsAnotherDelegate() {
        let view = makeView()
        weak var kept: Listener?
        do {
            let listener = Listener()
            kept = listener
            view.events = listener
        }
        #expect(kept == nil && view.events == nil)
        // Farewell installs its own navigation delegate after the tab leaves.
        // A separate navigation delegate models that ownership transfer.
        let delegate = NavigationDelegate()
        view.navigationDelegate = delegate
        view.events = nil
        #expect(view.navigationDelegate === delegate)
    }

    private final class LegacyListener: Listener, WKNavigationDelegate, WKUIDelegate {
        var ended = 0
        override func page(_ page: any PageHandle, ended reason: PageEnd?) { ended += 1 }
    }

    @Test func installedDelegatesDeliverProcessAndAuthenticationEvents() throws {
        let view = makeView(), legacy = LegacyListener()
        view.installDelegates(legacy)
        defer { view.installDelegates(nil) }
        let delegate = try #require(view.navigationDelegate)
        #expect(view.events === legacy && view.uiDelegate === view.navigationEvents)
        let terminated = NSSelectorFromString("webViewWebContentProcessDidTerminate:")
        #expect(delegate.responds(to: terminated))
        delegate.webViewWebContentProcessDidTerminate?(view)
        #expect(legacy.ended == 1)
        // Lifecycle-only listeners retain default authentication handling.
        #expect(delegate.responds(to: NSSelectorFromString("webView:didReceiveAuthenticationChallenge:completionHandler:")))
        let next = LegacyListener()
        view.installDelegates(next)
        delegate.webViewWebContentProcessDidTerminate?(view)
        #expect(legacy.ended == 1 && next.ended == 1)
    }

    private final class NavigationDelegate: NSObject, WKNavigationDelegate { }
}
