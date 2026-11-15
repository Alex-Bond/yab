import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct WebKitLoadFailureTests {
    private final class Listener: PageEvents {
        var failures: [PageNavigation?] = []
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .failed(let navigation, _, _) = event { failures.append(navigation) }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
    }

    @Test func onlyAnUnavailableToAvailablePathIsRecovery() {
        var path = LoadNetworkPath()
        let transitions = [true, true, false, true, true].map { path.update(available: $0) }
        #expect(transitions == [false, false, false, true, false])
    }

    @Test func offlineFailureWaitsWhileHiddenAndStopDisarmsIt() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        let listener = Listener(), adapter = page.navigationEvents
        page.navigationDelegate = adapter
        adapter.listener = listener
        defer { page.stopLoading(); Tab.end(page) }
        let navigation = try #require(page.loadHTMLString("offline", baseURL: nil))
        adapter.webView(page, didStartProvisionalNavigation: navigation)
        let url = URL(string: "https://recover.test/")!
        adapter.acceptNavigation(URLRequest(url: url))
        adapter.webView(page, didFailProvisionalNavigation: navigation,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                               userInfo: [NSURLErrorFailingURLErrorKey: url]))
        #expect(adapter.waitingForNetwork)
        #expect(listener.failures == [navigation.pageNavigation])
        adapter.networkRestored()
        #expect(adapter.waitingForNetwork) // Detached pages cannot replay.
        page.stopLoading()
        #expect(!adapter.waitingForNetwork)
        adapter.networkRestored()
        #expect(!adapter.waitingForNetwork)
    }

    @Test func commitAndANewerNavigationDisarmOfflineRecovery() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        let listener = Listener(), adapter = page.navigationEvents
        adapter.listener = listener
        defer { page.stopLoading(); Tab.end(page) }
        let navigation = try #require(page.loadHTMLString("offline", baseURL: nil))
        adapter.webView(page, didStartProvisionalNavigation: navigation)
        let url = URL(string: "https://recover.test/")!
        func fail() {
            adapter.acceptNavigation(URLRequest(url: url))
            adapter.webView(page, didFailProvisionalNavigation: navigation,
                withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                                   userInfo: [NSURLErrorFailingURLErrorKey: url]))
        }
        fail()
        #expect(adapter.waitingForNetwork)
        adapter.webView(page, didCommit: navigation)
        #expect(!adapter.waitingForNetwork)
        fail()
        adapter.acceptNavigation(URLRequest(url: URL(string: "https://elsewhere.test/")!))
        #expect(!adapter.waitingForNetwork)
    }

    @Test func anOldFailureCannotCoverTheNewDocument() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        let listener = Listener(), adapter = page.navigationEvents
        adapter.listener = listener
        defer { page.stopLoading(); Tab.end(page) }
        let old = try #require(page.loadHTMLString("old", baseURL: nil))
        let current = try #require(page.loadHTMLString("current", baseURL: nil))
        adapter.webView(page, didStartProvisionalNavigation: old)
        adapter.webView(page, didStartProvisionalNavigation: current)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        adapter.webView(page, didFailProvisionalNavigation: old, withError: error)
        adapter.webView(page, didFail: old, withError: error)
        #expect(listener.failures.isEmpty)
        adapter.webView(page, didFailProvisionalNavigation: current, withError: error)
        #expect(listener.failures == [current.pageNavigation])
    }

    @Test func currentCancellationStillReleasesTheBrowsersNavigationState() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: .zero, configuration: configuration)
        let listener = Listener(), adapter = page.navigationEvents
        adapter.listener = listener
        defer { page.stopLoading(); Tab.end(page) }
        let navigation = try #require(page.loadHTMLString("stop", baseURL: nil))
        adapter.webView(page, didStartProvisionalNavigation: navigation)
        adapter.webView(page, didFailProvisionalNavigation: navigation,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(listener.failures == [navigation.pageNavigation])
    }
}
