import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageActionEventsTests {
    private final class Listener: NSObject, PageEvents {
        var actions: [PageAction] = []
        var replies: [@MainActor (PagePolicy) -> Void] = []
        var hold = true
        var finished = false

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .finished = event { finished = true }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, decide action: PageAction,
                  reply: @escaping @MainActor (PagePolicy) -> Void) {
            actions.append(action)
            replies.append(reply)
            if !hold { reply(.allow) }
        }
    }

    private final class Document: NSObject, WKURLSchemeHandler {
        var requests: [URLRequest] = []
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            requests.append(task.request)
            let body = Data("<title>Action seam</title><a id='next' href='/next'>Next</a>".utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: body.count,
                                       textEncodingName: "utf-8"))
            task.didReceive(body)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { }
    }

    private func makeView(_ document: Document) -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(document, forURLScheme: "seam-action")
        return PageView(frame: .zero, configuration: configuration)
    }

    @Test func aRealRequestWaitsForItsActionReplyBeforeTheDocumentIsFetched() async throws {
        let document = Document(), view = makeView(document), listener = Listener()
        view.events = listener
        defer { view.stopLoading(); view.events = nil }
        var request = URLRequest(url: URL(string: "seam-action://local/start")!)
        request.setValue("kept", forHTTPHeaderField: "X-Seam")
        view.navigate(to: request)
        for _ in 0..<200 where listener.replies.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let action = try #require(listener.actions.first)
        let reply = try #require(listener.replies.first)
        #expect(action.request.url == request.url)
        #expect(action.request.value(forHTTPHeaderField: "X-Seam") == "kept")
        #expect(action.targetIsMainFrame == true)
        #expect(action.kind == .other && !action.shouldPerformDownload)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.requests.isEmpty && !listener.finished)
        reply(.allow)
        for _ in 0..<200 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        #expect(listener.finished && document.requests.count == 1)
        #expect(try await view.run("document.title") as? String == "Action seam")
    }

    @Test func aRealLinkCarriesItsSourceAndCanBeCanceledAfterTheCallbackReturns() async throws {
        let document = Document(), view = makeView(document), listener = Listener()
        listener.hold = false
        view.events = listener
        defer { view.stopLoading(); view.events = nil }
        view.navigate(to: URLRequest(url: URL(string: "seam-action://local/start")!))
        for _ in 0..<200 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        listener.actions = []; listener.replies = []; listener.hold = true
        _ = try await view.run("document.getElementById('next').click()")
        for _ in 0..<200 where listener.replies.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let action = try #require(listener.actions.first)
        #expect(action.request.url?.absoluteString == "seam-action://local/next")
        #expect(action.kind == .linkActivated && action.targetIsMainFrame == true)
        #expect(action.source?.isMainFrame == true)
        #expect(action.source?.scheme == "seam-action" && action.source?.host == "local")
        #expect(action.modifierFlags.isEmpty && !action.shouldPerformDownload)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.requests.count == 1)
        let reply = try #require(listener.replies.first)
        reply(.cancel)
        reply(.allow)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.requests.count == 1)
        #expect(view.url?.path == "/start")
    }

    private final class Capture: NSObject, WKNavigationDelegate {
        var action: WKNavigationAction?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            self.action = action
            decisionHandler(.cancel)
        }
    }

    @Test(arguments: [PagePolicy.allow, .cancel, .download])
    func bothActionCallbacksAnswerOnceAndKeepPreferencesAcrossListenerTransfer(policy: PagePolicy) async throws {
        let document = Document(), view = makeView(document), capture = Capture()
        // Engine-created metadata also has valid lifetime/deallocation state.
        view.navigationDelegate = capture
        defer { view.stopLoading(); view.events = nil; view.navigationDelegate = nil }
        view.navigate(to: URLRequest(url: URL(string: "seam-action://local/reply")!))
        for _ in 0..<200 where capture.action == nil { try await Task.sleep(for: .milliseconds(20)) }
        let action = try #require(capture.action)
        let listener = Listener(), next = Listener()
        view.events = listener
        let preferences = WKWebpagePreferences()
        var answers: [WKNavigationActionPolicy] = []
        var returned: WKWebpagePreferences?
        view.navigationEvents.webView(view, decidePolicyFor: action, preferences: preferences) {
            answers.append($0); returned = $1
        }
        #expect(answers.isEmpty)
        let reply = try #require(listener.replies.first)
        view.events = next
        reply(policy); reply(.cancel)
        #expect(answers == [policy.webKitAction] && returned === preferences)
        #expect(next.actions.isEmpty)
        view.navigationEvents.webView(view, decidePolicyFor: action) { answers.append($0) }
        let nextReply = try #require(next.replies.first)
        nextReply(policy); nextReply(.allow)
        #expect(answers == [policy.webKitAction, policy.webKitAction])
        view.events = nil
        view.navigationEvents.webView(view, decidePolicyFor: action) { answers.append($0) }
        #expect(answers.last == .allow && answers.count == 3)
    }

    @Test func copiedSourceMetadataKeepsTheExternalAppFrameGuard() throws {
        let page = URL(string: "https://team.slack.com/")!
        let own = PageAction.Source(isMainFrame: false, scheme: "https", host: "app.slack.com", port: 443)
        let foreign = PageAction.Source(isMainFrame: false, scheme: "https", host: "ads.example.net", port: 443)
        #expect(Browser.pageAsks(own, page: page, gesture: false))
        #expect(!Browser.pageAsks(foreign, page: page, gesture: false))
        #expect(Browser.pageAsks(foreign, page: page, gesture: true))
        #expect(!Browser.pageAsks(nil, page: page, gesture: false))
        #expect(Browser.pageAsks(nil, page: page, gesture: true))
        #expect(try JSONDecoder().decode(PageAction.Source.self, from: JSONEncoder().encode(own)) == own)
        let futureKind = PageAction.Kind(rawValue: 27)
        #expect(try JSONDecoder().decode(PageAction.Kind.self, from: JSONEncoder().encode(futureKind)) == futureKind)
    }
}
