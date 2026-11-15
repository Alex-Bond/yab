import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageShareTests {
    private final class Listener: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var finished = false
        var frame: PageFrame?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { frame = PageFrame(message.frameInfo) }
        }
    }

    private func fixture(tab: Bool) async throws -> (WKWebView, PageFrame) {
        let config = WKWebViewConfiguration(), listener = Listener()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(listener, contentWorld: PageWorld.yab.contentWorld, name: "pageShareFixture")
        let view = tab ? PageView(frame: .zero, configuration: config) : WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = listener
        view.loadHTMLString("<p>A share endpoint</p>", baseURL: URL(string: "https://seam.invalid:8443"))
        for _ in 0..<300 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        view.navigationDelegate = nil
        let target: any PageScriptTarget = view
        _ = try await target.run("window.webkit.messageHandlers.pageShareFixture.postMessage({}); true", in: .yab)
        for _ in 0..<300 where listener.frame == nil { try await Task.sleep(for: .milliseconds(20)) }
        let frame = try #require(listener.frame)
        config.userContentController.removeScriptMessageHandler(forName: "pageShareFixture", contentWorld: PageWorld.yab.contentWorld)
        #expect(frame.origin == PageOrigin(scheme: "https", host: "seam.invalid", port: 8443))
        return (view, frame)
    }

    @Test(arguments: [false, true])
    func shareEndUsesBothWorldsOnTabAndStandaloneEndpoints(tab: Bool) async throws {
        let (view, frame) = try await fixture(tab: tab)
        let target: any PageScriptTarget = view
        let id = UUID().uuidString, token = "native-request"
        defer { Share.shared.end(id, tellPage: false); view.stopLoading() }
        _ = try await target.run("""
        MediaDevices.prototype[Symbol.for('yab.share')] = {
          end: function (id, token) { window.shareEnded = id + ':' + token; return true; }
        };
        true
        """)
        _ = try await target.run("""
        window[Symbol.for('yab.share.worker')] = {
          end: function (id) { window.transportEnded = id; return true; }
        };
        true
        """, in: .yab)
        let session = Share.Session(id: id, caller: nil, browser: nil, frame: frame, source: .tab(UUID()), token: token, page: target)
        #expect(session.consumer === view)
        if let page = view as? PageView {
            #expect(page.committedURL == view.backForwardList.currentItem?.url)
        }
        Share.shared.add(session)
        Share.shared.end(id, tellPage: true)
        var ended: String?
        for _ in 0..<150 {
            ended = try await target.run("window.shareEnded || ''") as? String
            if ended == id + ":" + token { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ended == id + ":" + token)
        #expect(try await target.run("window.transportEnded", in: .yab) as? String == id)
        #expect(try await target.run("window.transportEnded === undefined") as? Bool == true)
        #expect(Share.shared.sessions[id] == nil)
    }

    @Test func aStandaloneEndpointRejectsAnotherPagesFrame() async throws {
        let (first, frame) = try await fixture(tab: true)
        let (second, _) = try await fixture(tab: false)
        defer { first.stopLoading(); second.stopLoading() }
        let target: any PageScriptTarget = second
        do {
            _ = try await target.run("window.foreignShareRan = true", frame: frame)
            Issue.record("A standalone endpoint accepted another page's frame")
        } catch PageEngineError.foreignFrame { }
        #expect(try await target.run("window.foreignShareRan === undefined") as? Bool == true)
    }

    @Test func copiedFramePolicyKeepsSameSiteChecksAndOneUseNativeInput() {
        let tab = Tab(shy: true, bench: true)
        defer { tab.close() }
        tab.setAddressOptimistically(URL(string: "https://app.example.com/top")!)
        let own = PageFrame(isMain: false, url: nil, token: NSObject(), origin: PageOrigin(scheme: "https", host: "accounts.example.com", port: 443))
        let other = PageFrame(isMain: false, url: nil, token: NSObject(), origin: PageOrigin(scheme: "https", host: "elsewhere.invalid", port: 443))
        #expect(RelayGuard.ownFrame(own, of: tab))
        #expect(!RelayGuard.ownFrame(other, of: tab))
        // Construct the real endpoint at a local blank address, never visit
        // the synthetic policy origins above.
        tab.setAddressOptimistically(URL(string: "about:blank")!)
        let page = tab.page
        let main = PageFrame(isMain: true, url: nil, token: NSObject())
        RelayGuard.vouch(page)
        #expect(RelayGuard.share(main, on: tab) == .yab)
        #expect(RelayGuard.share(main, on: tab) == nil)
    }

    /// Slack's huddle window: an about:blank popup its opener fills. Share
    /// Screen is clicked there and the opener asks for the screen; the
    /// click counts, once, and the box comes over the window clicked.
    @Test func aClickInTheWindowAPageDrawsStandsBehindItsAsk() {
        let browser = Browser(windowID: UUID())
        let opener = Tab(shy: true, bench: true), huddle = Tab(shy: true, bench: true), signIn = Tab(shy: true, bench: true)
        defer { opener.close(); huddle.close(); signIn.close() }
        opener.setAddressOptimistically(URL(string: "https://app.example.com/client")!)
        for window in [huddle, signIn] {
            window.popup = true; window.opener = opener.id; window.scripted = Date()
            browser.outside.append(window)
        }
        huddle.setAddressOptimistically(URL(string: "about:blank")!)
        signIn.setAddressOptimistically(URL(string: "https://accounts.elsewhere.invalid/")!)
        #expect(RelayGuard.drawn(huddle, by: opener))
        #expect(!RelayGuard.drawn(signIn, by: opener))
        let main = PageFrame(isMain: true, url: nil, token: NSObject())

        RelayGuard.felt(huddle.page)
        let asked = browser.shareHand(main, on: opener)
        #expect(asked?.0 == .page)
        #expect(asked?.1 === huddle)
        #expect(browser.shareHand(main, on: opener) == nil)

        // A click on another site's window is not the page's.
        RelayGuard.felt(signIn.page)
        #expect(browser.shareHand(main, on: opener) == nil)
        // Nor a window another page opened.
        huddle.opener = UUID()
        RelayGuard.felt(huddle.page)
        #expect(browser.shareHand(main, on: opener) == nil)
        // The page's own click still stands behind its own ask, on its tab.
        RelayGuard.felt(opener.page)
        let own = browser.shareHand(main, on: opener)
        #expect(own?.0 == .page)
        #expect(own?.1 == nil)
    }
}
