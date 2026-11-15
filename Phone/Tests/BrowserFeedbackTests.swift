import Network
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Native dialogs and failure callbacks run only against disposable loopback pages.
@MainActor
final class BrowserFeedbackTests: XCTestCase {
    private var site: FeedbackSite!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var pools: [WebPool] = []
    private var tabs: [YabPhone.Tab] = []
    private var oldDisabled = false

    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        site = try FeedbackSite()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            site.start { done.resume(with: $0) }
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }
    override func tearDown() async throws {
        defer { Motion.disabled = oldDisabled }
        for pool in pools {
            pool.suspendPageDialogs()
            for tab in tabs { pool.forget(tab.id) }
        }
        pools = []; tabs = []
        window?.rootViewController = nil; window?.isHidden = true; window = nil
        previousKey?.makeKey()
        site?.stop(); site = nil
    }
    private func pool() -> WebPool {
        let made = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pools.append(made); return made
    }
    private func tab(_ name: String, _ path: String = "/page", privateMode: Bool = false) -> YabPhone.Tab {
        let made = PageFixtures.liveTab(for: site.url(path), id: name, isPrivate: privateMode)
        tabs.append(made); return made
    }
    private func show(_ view: WKWebView) {
        let host = window.rootViewController!.view!
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds; view.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        host.addSubview(view); window.layoutIfNeeded()
    }
    private func ready(_ pages: WebPool, _ tab: YabPhone.Tab, timeout: TimeInterval = 10) async throws -> WKWebView {
        let view = pages.activate(tab); show(view)
        try await until(timeout: timeout) { pages.painted.contains(tab.id) && !view.isLoading }
        return view
    }
    private func until(timeout: TimeInterval = 10, _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The owned native state did not arrive", file: file, line: line)
        throw NSError(domain: "BrowserFeedbackTests", code: 1)
    }

    func testFailureKindsNeverOfferATrustBypassOrExposeQueryCredentials() {
        let url = URL(string: "https://owned:secret@owned.test:9443/page?q=private")!
        let samples: [(Int,PageLoadFailure.Kind)] = [(NSURLErrorNotConnectedToInternet,.offline),
            (NSURLErrorNetworkConnectionLost,.connection),(NSURLErrorTimedOut,.timeout),
            (NSURLErrorServerCertificateUntrusted,.secureConnection),(NSURLErrorSecureConnectionFailed,.secureConnection),
            (NSURLErrorCannotFindHost,.address)]
        for (code, kind) in samples {
            let failure = PageLoadFailure(url: url, error: NSError(domain: NSURLErrorDomain, code: code))
            XCTAssertEqual(failure.kind, kind)
            XCTAssertEqual(failure.site, "owned.test:9443")
            XCTAssertFalse(failure.explanation.contains("secret"))
            XCTAssertFalse(failure.explanation.contains("Continue"))
        }
        XCTAssertEqual(PageLoadFailure(url: nil, error: NSError(domain: "Other", code: NSURLErrorCancelled)).kind, .navigation)
    }

    func testStoppedPendingPageRetainsRetryAndItsStoreWithoutRestart() async throws {
        for privateMode in [false, true] {
            let pages = pool(), peer = tab("process.peer.\(privateMode)", "/second")
            let peerView = try await ready(pages, peer, timeout: 25)
            let current = tab("process.pending.\(privateMode)", privateMode: privateMode)
            let view = StoppedPageView(frame: window.bounds, configuration: pages.configurationForPage(for: current))
            XCTAssertTrue(pages.adopt(view, for: current))
            XCTAssertTrue(pages.activate(current) === view)
            show(view)
            let store = view.configuration.websiteDataStore, target = site.url()
            view.hidesURL = true
            pages.load(current.id, target)
            let requests = view.loadedURLs.count
            pages.webViewWebContentProcessDidTerminate(view)
            XCTAssertNil(pages.state(for: current.id).failure, "the first stop must recover the retained destination")
            XCTAssertEqual(view.loadedURLs.count, requests + 1)
            XCTAssertEqual(view.loadedURLs.last, target)
            pages.webViewWebContentProcessDidTerminate(view)
            let failure = try XCTUnwrap(pages.state(for: current.id).failure)
            XCTAssertEqual(failure.kind, .process)
            XCTAssertEqual(failure.url, target, "Retry must retain the address even when WebKit has no URL")
            guard failure.url != nil else { return }
            view.hidesURL = false
            XCTAssertTrue(pages.retryFailure(current.id, expected: failure.id))
            XCTAssertFalse(pages.retryFailure(current.id, expected: failure.id))
            try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
            XCTAssertNil(pages.state(for: current.id).failure)
            XCTAssertTrue(pages.view(for: current) === view)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertTrue(pages.view(for: peer) === peerView)
            XCTAssertEqual(peerView.title, "Second page")
        }
    }

    func testStoppedPendingPageRecoversOnForegroundWithoutRestart() async throws {
        for privateMode in [false, true] {
            let pages = pool(), current = tab("process.foreground.\(privateMode)", privateMode: privateMode)
            let view = StoppedPageView(frame: window.bounds, configuration: pages.configurationForPage(for: current))
            XCTAssertTrue(pages.adopt(view, for: current))
            _ = pages.activate(current); show(view)
            view.hidesURL = true
            pages.load(current.id, site.url())
            let requests = view.loadedURLs.count
            pages.appWillResignActive()
            pages.webViewWebContentProcessDidTerminate(view)
            XCTAssertEqual(view.loadedURLs.count, requests, "a background stop must wait for the foreground")
            pages.appDidBecomeActive()
            XCTAssertNil(pages.state(for: current.id).failure, "foreground recovery must keep the pending address")
            XCTAssertEqual(view.loadedURLs.count, requests + 1)
            XCTAssertEqual(view.loadedURLs.last, site.url())
            guard pages.state(for: current.id).failure == nil else { return }
            view.hidesURL = false
            try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        }
    }

    func testProcessRecoveryKeepsPendingDestinationInsteadOfPreviousDocument() async throws {
        let pages = pool(), current = tab("process.destination")
        let view = StoppedPageView(frame: window.bounds, configuration: pages.configurationForPage(for: current))
        XCTAssertTrue(pages.adopt(view, for: current))
        _ = pages.activate(current); show(view)
        pages.load(current.id, site.url())
        try await until(timeout: 25) { pages.painted.contains(current.id) && !view.isLoading }
        view.reportedURL = site.url()
        pages.load(current.id, site.url("/second"))
        let requests = view.loadedURLs.count
        pages.webViewWebContentProcessDidTerminate(view)
        XCTAssertNil(pages.state(for: current.id).failure, "recovery must restart the pending destination")
        XCTAssertEqual(view.loadedURLs.count, requests + 1)
        XCTAssertEqual(view.loadedURLs.last, site.url("/second"))
        guard pages.state(for: current.id).failure == nil else { return }
        view.reportedURL = nil
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Second page" && !view.isLoading }
        XCTAssertEqual(view.url, site.url("/second"))
    }

    // #350: back to a tab after a while in the background, its page had
    // stopped (iOS ends web processes of apps away), and Yab showed the error
    // pane with Retry dimmed and Refresh doing nothing. These end the real
    // WebContent process, as iOS does, not a stand-in for its callback.

    private func endProcess(_ view: WKWebView) {
        let name = NSSelectorFromString("_killWebContentProcess")
        XCTAssertTrue(view.responds(to: name), "WebKit's process kill is missing")
        _ = view.perform(name)
    }

    private func diag(_ pages: WebPool, _ id: Tab.ID, _ view: WKWebView) -> String {
        let failure = pages.state(for: id).failure
        return "url=\(view.url?.absoluteString ?? "nil") title=\(view.title ?? "nil") loading=\(view.isLoading) painted=\(pages.painted.contains(id)) failure=\(failure.map { "\($0.kind)/\($0.url?.absoluteString ?? "nil")" } ?? "none")"
    }

    func testRealProcessEndedAwayReloadsWhenBack() async throws {
        let pages = pool(), current = tab("killed.away")
        let view = try await ready(pages, current, timeout: 25)
        pages.appWillResignActive()
        endProcess(view)
        try await until(timeout: 10) { !pages.painted.contains(current.id) }
        try await Task.sleep(for: .milliseconds(300))
        let away = diag(pages, current.id, view)
        XCTAssertNil(pages.state(for: current.id).failure, "a page stopped while away must not show the error pane: \(away)")
        pages.appDidBecomeActive()
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        XCTAssertNil(pages.state(for: current.id).failure, diag(pages, current.id, view))
        XCTAssertEqual(view.url, site.url())
    }

    func testRealProcessEndedInFrontReloadsAtOnce() async throws {
        let pages = pool(), current = tab("killed.front")
        let view = try await ready(pages, current, timeout: 25)
        endProcess(view)
        try await until(timeout: 10) { !pages.painted.contains(current.id) }
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        XCTAssertNil(pages.state(for: current.id).failure, diag(pages, current.id, view))
    }

    /// iOS can end a page's process again before its reload finished (memory
    /// is still short when Yab comes back). The pane then says so, and both
    /// its Retry and the page menu's Reload load the page.
    func testRealProcessEndedTwiceKeepsRetryAndRefreshLive() async throws {
        for refresh in [false, true] {
            let pages = pool(), current = tab("killed.twice.\(refresh)")
            let view = try await ready(pages, current, timeout: 25)
            endProcess(view)
            try await until(timeout: 10) { !pages.painted.contains(current.id) }
            endProcess(view)
            try await until(timeout: 10) { pages.state(for: current.id).failure != nil || pages.painted.contains(current.id) }
            guard let failure = pages.state(for: current.id).failure else { continue }
            XCTAssertEqual(failure.kind, .process)
            XCTAssertEqual(failure.url, site.url(), "Retry must keep the address: \(diag(pages, current.id, view))")
            if refresh {
                let reloaded = await pages.reloadSelected(current.id)
                XCTAssertTrue(reloaded, "Refresh must load a stopped page: \(diag(pages, current.id, view))")
            } else {
                XCTAssertTrue(pages.retryFailure(current.id, expected: failure.id), "Retry must load: \(diag(pages, current.id, view))")
            }
            try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
            XCTAssertNil(pages.state(for: current.id).failure, diag(pages, current.id, view))
        }
    }

    /// Stopped while away, and stopped again while away before Yab came back
    /// (the reload of an earlier stop never finished): still a reload on return.
    func testRealProcessEndedAfterUnfinishedRecoveryReloadsWhenBack() async throws {
        let pages = pool(), current = tab("killed.unfinished")
        let view = try await ready(pages, current, timeout: 25)
        endProcess(view)
        try await until(timeout: 10) { !pages.painted.contains(current.id) }
        // The recovery's reload is under way; Yab goes away and iOS ends it.
        pages.appWillResignActive()
        endProcess(view)
        try await Task.sleep(for: .milliseconds(800))
        let away = diag(pages, current.id, view)
        pages.appDidBecomeActive()
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        XCTAssertNil(pages.state(for: current.id).failure, "away: \(away); now: \(diag(pages, current.id, view))")
    }

    /// Only the page in front loads as Yab comes back; a tab
    /// behind it whose process stopped too loads once it is shown.
    func testRealProcessEndedAwayBehindLoadsWhenShown() async throws {
        let pages = pool(), behind = tab("killed.behind", "/second"), current = tab("killed.current")
        let behindView = try await ready(pages, behind, timeout: 25)
        let view = try await ready(pages, current, timeout: 25)
        XCTAssertTrue(pages.isLive(behind.id))
        pages.appWillResignActive()
        endProcess(view); endProcess(behindView)
        try await until(timeout: 10) { !pages.painted.contains(current.id) && !pages.painted.contains(behind.id) }
        let requests = site.count("/second")
        pages.appDidBecomeActive()
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        try await Task.sleep(for: .milliseconds(800))
        // WebKit may answer a stopped page's load from its cache: its title says.
        XCTAssertEqual(site.count("/second"), requests, "a tab not shown must wait to be shown")
        XCTAssertTrue(behindView.title?.isEmpty != false && !behindView.isLoading,
                      "a tab not shown must wait to be shown: \(diag(pages, behind.id, behindView))")
        XCTAssertNil(pages.state(for: behind.id).failure)
        XCTAssertTrue(pages.activate(behind) === behindView); show(behindView)
        try await until(timeout: 25) { pages.painted.contains(behind.id) && behindView.title == "Second page" && !behindView.isLoading }
        XCTAssertNil(pages.state(for: behind.id).failure, diag(pages, behind.id, behindView))
        XCTAssertEqual(behindView.url, site.url("/second"))
    }

    /// A tab behind the one in front, stopped while Yab is in use, loads when
    /// it is shown, not at once.
    func testRealProcessEndedBehindWhileInUseLoadsWhenShown() async throws {
        let pages = pool(), behind = tab("killed.behind.use", "/second"), current = tab("killed.current.use")
        let behindView = try await ready(pages, behind, timeout: 25)
        let view = try await ready(pages, current, timeout: 25)
        let requests = site.count("/second")
        endProcess(behindView)
        try await until(timeout: 10) { !pages.painted.contains(behind.id) }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(site.count("/second"), requests, "a tab not shown must wait to be shown")
        XCTAssertTrue(behindView.title?.isEmpty != false && !behindView.isLoading,
                      "a tab not shown must wait to be shown: \(diag(pages, behind.id, behindView))")
        XCTAssertNil(pages.state(for: behind.id).failure)
        // Two pages can share a process; the one in front then loads again.
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
        XCTAssertTrue(pages.activate(behind) === behindView); show(behindView)
        try await until(timeout: 25) { pages.painted.contains(behind.id) && behindView.title == "Second page" && !behindView.isLoading }
        XCTAssertNil(pages.state(for: behind.id).failure, diag(pages, behind.id, behindView))
    }

    /// Back with the page dead and nothing said about it yet (WebKit tells of
    /// the stop only later): Refresh still loads the page it showed.
    func testRefreshLoadsAPageWhoseProcessEndedUnannounced() async throws {
        let pages = pool(), current = tab("killed.silent")
        let view = try await ready(pages, current, timeout: 25)
        let delegate = view.navigationDelegate
        view.navigationDelegate = nil
        endProcess(view)
        try await until(timeout: 10) { view.url == nil || view.title?.isEmpty != false }
        view.navigationDelegate = delegate
        let reloaded = await pages.reloadSelected(current.id)
        XCTAssertTrue(reloaded, "Refresh must load: \(diag(pages, current.id, view))")
        try await until(timeout: 25) { pages.painted.contains(current.id) && view.title == "Owned dialog page" && !view.isLoading }
    }

    func testActualConfirmCancelsOnceOnSelectionAndBackgroundPageCannotPrompt() async throws {
        let pages = pool(), first = tab("dialog.first"), second = tab("dialog.second","/second")
        let view = try await ready(pages, first)
        let answer = Task { @MainActor in try await view.evaluateJavaScript("confirm('Owned confirm')") }
        try await until { pages.javaScriptDialog != nil && self.window.rootViewController?.presentedViewController is UIAlertController }
        let controller = try XCTUnwrap(pages.javaScriptDialog?.controller)
        XCTAssertEqual(controller.title, "127.0.0.1:\(site.port)")
        _ = try await ready(pages, second)
        let actualAnswer = try await answer.value
        XCTAssertEqual(actualAnswer as? Bool, false)
        XCTAssertNil(pages.javaScriptDialog)
        let hidden = try await view.evaluateJavaScript("prompt('Hidden prompt','private draft')")
        XCTAssertTrue(hidden is NSNull)
        XCTAssertNil(pages.javaScriptDialog, "a warmed background page must not present a dialog")
    }

    func testActualPromptCancelsOnPrivateCoverAndStoreRenewalWithoutRetargeting() async throws {
        let pages = pool(), privateTab = tab("dialog.private", privateMode: true)
        let view = try await ready(pages, privateTab)
        let originalStore = view.configuration.websiteDataStore
        let prompt = Task { @MainActor in try await view.evaluateJavaScript("prompt('Private prompt','Seed')") }
        try await until { pages.javaScriptDialog?.controller.textFields?.first?.text == "Seed" }
        pages.setPageInteractionsEnabled(false)
        let cancelled = try await prompt.value
        XCTAssertTrue(cancelled is NSNull)
        XCTAssertNil(pages.javaScriptDialog)
        let covered = try await view.evaluateJavaScript("confirm('Covered private page')")
        XCTAssertEqual(covered as? Bool, false)
        pages.setPageInteractionsEnabled(true)
        let pending = Task { @MainActor in try await view.evaluateJavaScript("confirm('Renewed private store')") }
        try await until { pages.javaScriptDialog != nil }
        pages.renewPrivateStore()
        let renewedAnswer = try await pending.value
        XCTAssertEqual(renewedAnswer as? Bool, false)
        XCTAssertTrue(view.configuration.websiteDataStore === originalStore)
        XCTAssertFalse(pages.privateStore === originalStore)
        XCTAssertNil(pages.javaScriptDialog)
        let retired = try await view.evaluateJavaScript("confirm('Old private jar')")
        XCTAssertEqual(retired as? Bool,false)
        XCTAssertNil(pages.javaScriptDialog)
    }

    func testActualAlertCompletesOnBackgroundAndClosedPageCancelsItsCallback() async throws {
        let pages = pool(), first = tab("dialog.closed")
        let view = try await ready(pages, first)
        let alert = Task { @MainActor in try await view.evaluateJavaScript("alert('Owned alert');'dismissed'") }
        try await until { pages.javaScriptDialog != nil }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let alertAnswer = try await alert.value
        XCTAssertEqual(alertAnswer as? String, "dismissed")
        XCTAssertNil(pages.javaScriptDialog)
        let prompt = Task { @MainActor in try await view.evaluateJavaScript("prompt('Closing page','Seed')") }
        try await until { pages.javaScriptDialog != nil }
        pages.forget(first.id)
        let response = try await prompt.value
        XCTAssertTrue(response is NSNull)
        XCTAssertNil(pages.javaScriptDialog)
        XCTAssertFalse(pages.isLive(first.id))
    }

    func testNewNativeNavigationCancelsPromptAndRejectsItsLateReply() async throws {
        let pages = pool(), current = tab("dialog.navigation")
        let view = try await ready(pages,current)
        let answer = Task { @MainActor in try await view.evaluateJavaScript("prompt('Old document','Seed')") }
        try await until { pages.javaScriptDialog != nil }
        let old = try XCTUnwrap(pages.javaScriptDialog)
        pages.load(current.id,site.url("/second"))
        let cancelled = try await answer.value
        XCTAssertTrue(cancelled is NSNull)
        try await until { pages.painted.contains(current.id) && view.title == "Second page" }
        old.resolve("Late stale reply",animated:false)
        XCTAssertNil(pages.javaScriptDialog)
        XCTAssertEqual(view.url,site.url("/second"))
        XCTAssertEqual(pages.front,current.id)
    }

    func testActualIncompleteResponseRetryKeepsHistoryURLAndPublicOrPrivateJar() async throws {
        let pages = pool()
        var publicView: WKWebView?
        for privateMode in [false,true] {
            site.failResponse()
            let current = tab(privateMode ? "error.private" : "error.public", privateMode: privateMode)
            let view = try await ready(pages,current)
            let marker = privateMode ? "private-owned" : "public-owned"
            _ = try await view.evaluateJavaScript("localStorage.setItem('owned','\(marker)');document.cookie='owned=\(marker);path=/'")
            let store = view.configuration.websiteDataStore
            let url = site.url("/abort?q=a%2Bb#part")
            pages.load(current.id,url)
            try await until { pages.state(for: current.id).failure != nil }
            let failure = try XCTUnwrap(pages.state(for: current.id).failure)
            let before = try XCTUnwrap(pages.navigationState(for: current.id))
            XCTAssertEqual(failure.url,url)
            XCTAssertTrue(pages.represents(PageFixtures.liveTab(for: url,id: current.id,isPrivate: privateMode)))
            var visible = false
            pages.pageVisibility = { _ in visible }
            XCTAssertFalse(pages.retryFailure(current.id,expected:failure.id), "read the current gate before any new render")
            visible = true
            pages.setPageInteractionsEnabled(false)
            XCTAssertFalse(pages.retryFailure(current.id,expected:failure.id))
            pages.setPageInteractionsEnabled(true)
            site.allowResponse()
            XCTAssertTrue(pages.retryFailure(current.id,expected:failure.id))
            XCTAssertNil(pages.state(for: current.id).failure, "clear the old error synchronously before Retry loads")
            try await until { pages.painted.contains(current.id) && !view.isLoading && view.title == "Recovered page" }
            XCTAssertEqual(view.url,url)
            XCTAssertEqual(pages.front,current.id)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            if privateMode {
                XCTAssertFalse(store === publicView?.configuration.websiteDataStore)
                let publicValue = try await publicView!.evaluateJavaScript("localStorage.getItem('owned')") as? String
                XCTAssertEqual(publicValue,"public-owned")
            } else { publicView = view }
            let stored = try await view.evaluateJavaScript("localStorage.getItem('owned')") as? String
            let cookies = try await view.evaluateJavaScript("document.cookie") as? String
            XCTAssertEqual(stored,marker)
            XCTAssertTrue(cookies?.contains("owned=\(marker)") == true)
            let after = try XCTUnwrap(pages.navigationState(for: current.id))
            XCTAssertEqual(after.entries.map(\.url),before.entries.map(\.url))
            XCTAssertEqual(after.index,before.index)
            XCTAssertFalse(pages.retryFailure(current.id,expected:failure.id))
        }
    }

    func testNativeTLSFailureStaleCancellationAndBackKeepAnIntactDocument() async throws {
        let pages = pool(), current = tab("error.tls")
        let view = try await ready(pages,current)
        _ = try await view.evaluateJavaScript("document.getElementById('result').textContent='Original document kept'")
        let before = try XCTUnwrap(pages.navigationState(for:current.id))
        let tls = URL(string:"https://127.0.0.1:\(site.port)/tls")!
        let old = try XCTUnwrap(view.load(URLRequest(url:tls)))
        try await until { pages.state(for:current.id).failure != nil }
        let failure = try XCTUnwrap(pages.state(for:current.id).failure)
        XCTAssertEqual(failure.url,tls)
        XCTAssertEqual(failure.kind,.secureConnection)
        XCTAssertTrue(pages.state(for:current.id).canGoBack)
        let restored = await pages.backFailure(current.id,expected:failure.id)
        XCTAssertTrue(restored)
        XCTAssertNil(pages.state(for:current.id).failure)
        XCTAssertEqual(view.url,site.url())
        let originalText = try await view.evaluateJavaScript("document.getElementById('result').textContent") as? String
        XCTAssertEqual(originalText,"Original document kept")
        XCTAssertEqual(pages.navigationState(for:current.id)?.entries.map(\.url),before.entries.map(\.url))
        pages.load(current.id,site.url("/second"))
        try await until { pages.painted.contains(current.id) && view.title == "Second page" }
        pages.webView(view,didFailProvisionalNavigation:old,withError:NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet))
        XCTAssertNil(pages.state(for:current.id).failure, "an old actual native token must not replace the successful page")
        XCTAssertFalse(pages.retryFailure(current.id,expected:failure.id))
        pages.forget(current.id)
        XCTAssertFalse(pages.retryFailure(current.id,expected:failure.id))
    }

    func testRetiredNativePageHostCannotCancelTheCurrentHostsDialog() async throws {
        let pages = pool(), current = tab("dialog.host")
        let view = try await ready(pages,current)
        let old = PageContainer(frame:window.bounds), new = PageContainer(frame:window.bounds)
        let parent = window.rootViewController!.view!
        old.pool = pages; old.fixturesEnabled = false; parent.addSubview(old); old.show(view)
        pages.bindPageInteractions(to:old,enabled:true,visibility:{ _ in true })
        new.pool = pages; new.fixturesEnabled = false; parent.addSubview(new); new.show(view)
        pages.bindPageInteractions(to:new,enabled:true,visibility:{ _ in true })
        let prompt = Task { @MainActor in try await view.evaluateJavaScript("prompt('Current host','Seed')") }
        try await until { pages.javaScriptDialog != nil }
        pages.releasePageInteractions(from:old)
        XCTAssertNotNil(pages.javaScriptDialog)
        pages.releasePageInteractions(from:new)
        let value = try await prompt.value
        XCTAssertTrue(value is NSNull)
        XCTAssertNil(pages.javaScriptDialog)
    }

    func testRetiredNativePageHostCannotRevealTheCurrentHostsFailedPage() async throws {
        let pages = pool(), current = tab("error.host")
        let view = try await ready(pages,current)
        let old = PageContainer(frame:window.bounds), new = PageContainer(frame:window.bounds)
        let parent = window.rootViewController!.view!
        old.pool = pages; old.fixturesEnabled = false; parent.addSubview(old); old.show(view)
        pages.bindPageInteractions(to:old,enabled:true,visibility:{ _ in true })
        new.pool = pages; new.fixturesEnabled = false; parent.addSubview(new); new.show(view)
        pages.bindPageInteractions(to:new,enabled:true,visibility:{ _ in true })
        XCTAssertTrue(view.superview === new)
        pages.load(current.id,site.url("/abort"))
        try await until { pages.state(for:current.id).failure != nil }
        let failure = try XCTUnwrap(pages.state(for:current.id).failure)
        new.showFailure(failure,tab:current.id)
        XCTAssertTrue(view.accessibilityElementsHidden)
        // SwiftUI may dismantle the old host after the current WKWebView has
        // already moved underneath the new host's actual failure pane.
        old.showFailure(nil,tab:"")
        XCTAssertTrue(view.accessibilityElementsHidden, "the retired host cannot reveal another host's failed page")
        pages.releasePageInteractions(from:old)
        old.show(nil)
        XCTAssertTrue(view.superview === new)
        XCTAssertTrue(view.accessibilityElementsHidden)
        site.allowResponse()
        XCTAssertTrue(pages.retryFailure(current.id,expected:failure.id))
        try await until { pages.painted.contains(current.id) && !view.isLoading && view.title == "Recovered page" }
        new.showFailure(nil,tab:current.id)
        XCTAssertFalse(view.accessibilityElementsHidden, "the real owner reveals only the successfully retried page")
        XCTAssertEqual(view.url,site.url("/abort"))
        XCTAssertEqual(pages.front,current.id)
    }

    func testDialogCompletionIsConsumedOnlyOnce() {
        let view = WKWebView(frame:window.bounds,configuration:pool().configurationForPage())
        var answers:[String?] = []
        let dialog = PageJavaScriptDialog(tab:"owned",webView:view,document:UUID(),privateSession:nil,
            site:"127.0.0.1",message:"Owned",kind:.prompt,defaultText:"Seed") { answers.append($0) }
        dialog.resolve(nil,animated:false); dialog.resolve("Late stale answer",animated:false)
        XCTAssertEqual(answers.count,1)
        XCTAssertNil(answers[0])
    }
}

/// Control the native state lost at process death; real loopback loads still finish.
@MainActor
private final class StoppedPageView: WKWebView {
    var hidesURL = false
    var reportedURL: URL?
    private(set) var loadedURLs: [URL] = []
    override var url: URL? { hidesURL ? nil : (reportedURL ?? super.url) }
    override func reload() -> WKNavigation? { nil }
    override func load(_ request: URLRequest) -> WKNavigation? {
        if let url = request.url { loadedURLs.append(url) }
        return super.load(request)
    }
}

/// Only this test owns the listener, requests and connections. No dev server.
private final class FeedbackSite: @unchecked Sendable {
    private let queue = DispatchQueue(label: "owned-browser-feedback-http")
    private let listener: NWListener
    private var ready: ((Result<Void, Error>) -> Void)?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    private var aborts = true
    private var counts: [String: Int] = [:]
    var port: UInt16 { listener.port!.rawValue }
    func url(_ path: String = "/page") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func count(_ path: String) -> Int { queue.sync { counts[path, default: 0] } }
    func allowResponse() { queue.sync { aborts = false } }
    func failResponse() { queue.sync { aborts = true } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(_ completed: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            self.ready = completed
            self.listener.stateUpdateHandler = { [weak self] state in
                guard let self, let callback = self.ready else { return }
                switch state {
                case .ready: self.ready = nil; callback(.success(()))
                case let .failed(error): self.ready = nil; callback(.failure(error))
                case .cancelled: self.ready = nil; callback(.failure(NSError(domain: "FeedbackSite", code: 2)))
                default: break
                }
            }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, Data())
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let callback = self.ready else { return }
                self.ready = nil; self.listener.cancel()
                callback(.failure(NSError(domain: "FeedbackSite", code: 1)))
            }
        }
    }
    func stop() {
        queue.sync {
            stopped = true
            let callback = ready; ready = nil
            callback?(.failure(NSError(domain: "FeedbackSite", code: 2)))
            listener.cancel()
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = previous; if let data { bytes.append(data) }
            guard !self.stopped, error == nil, bytes.count <= 16_384 else { self.close(connection); return }
            // The TLS test connects to this owned TCP port. Send a real fatal
            // handshake alert, never an accepted certificate or a trust bypass.
            if bytes.first == 0x16 {
                self.send(Data([0x15,0x03,0x03,0x00,0x02,0x02,0x28]), to: connection)
                return
            }
            guard let header = String(data: bytes, encoding: .utf8), header.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, bytes) }
                return
            }
            let target = header.components(separatedBy: " ").dropFirst().first ?? "/page"
            let route = target.components(separatedBy: "?").first ?? target
            self.counts[route, default: 0] += 1
            if route == "/abort", self.aborts {
                // The native engine commits real bytes, then observes an
                // incomplete response body and FIN. No injected failure callback.
                let partial = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n<!doctype html><title>Interrupted response</title><p>Interrupted response</p>"
                self.send(Data(partial.utf8), to: connection)
                return
            }
            let title = route == "/abort" ? "Recovered page" : route == "/second" ? "Second page" : "Owned dialog page"
            let body = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>\(title)</title><link rel=icon href=data:,>
            <style>body{margin:0;padding:20px;font:20px system-ui;background:linear-gradient(120deg,#c2fbff,#ffd0a0);min-height:100vh}button,a{display:block;margin:14px 0;padding:14px;font:inherit}output{display:block;min-height:44px}</style></head><body>
            <h1>\(title)</h1><button onclick="alert('Owned alert');document.getElementById('result').textContent='Alert dismissed'">Show alert</button>
            <button onclick="document.getElementById('result').textContent='Confirm '+confirm('Owned confirmation')">Show confirm</button>
            <button onclick="let v=prompt('Owned prompt','Seed');document.getElementById('result').textContent=v===null?'Prompt cancelled':'Prompt '+v">Show prompt</button>
            <button onclick="window.actions=(window.actions||0)+1;document.getElementById('result').textContent='Page action '+window.actions">Page action</button>
            <output id=result>Ready for dialogs</output><a href="/abort">Open interrupted response</a><a href="/second">Open second page</a></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.send(Data(response.utf8), to: connection)
        }
    }
    private func send(_ bytes: Data, to connection: NWConnection) {
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            guard let self else { connection.cancel(); return }
            self.queue.async { self.close(connection) }
        })
    }
    private func close(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}
