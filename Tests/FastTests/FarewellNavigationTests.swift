import AppKit
import Testing
import WebKit
@testable import Fast

/// Engine-created actions are captured by a rejecting delegate, then handed
/// directly to the retiring view's actual delegate. No sentinel is ever
/// navigated with missing policy, even on the failing baseline.
@MainActor @Suite(.serialized)
struct FarewellNavigationTests {
    init() throws {
        try #require(Store.testing && Store.world != nil)
        try #require(Store.settings !== UserDefaults.standard)
        _ = NSApplication.shared
    }

    private final class Capture: NSObject, WKNavigationDelegate {
        var action: WKNavigationAction?
        var finished = false
        var reject = true

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            self.action = action
            decisionHandler(reject ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }

    private func configuration() -> WKWebViewConfiguration {
        let made = WKWebViewConfiguration()
        made.websiteDataStore = .nonPersistent()
        return made
    }

    private func actions(_ addresses: [String]) async throws -> [WKNavigationAction] {
        let view = PageView(frame: .zero, configuration: configuration()), capture = Capture()
        view.navigationDelegate = capture
        defer { view.stopLoading(); view.navigationDelegate = nil; Tab.end(view) }
        var result: [WKNavigationAction] = []
        for address in addresses {
            capture.action = nil
            view.load(URLRequest(url: try #require(URL(string: address))))
            for _ in 0..<200 where capture.action == nil { try await Task.sleep(for: .milliseconds(20)) }
            let action = try #require(capture.action, "WebKit must actually ask the controlled policy delegate")
            #expect(Self.same(action.nativeRequest?.url, address), "\(String(describing: action.nativeRequest?.url)) is \(address)")
            result.append(action)
        }
        return result
    }

    /// The asked-about address is the loaded one as WebKit spells it: it
    /// lowercases the scheme (case-insensitive, RFC 3986) and may escape
    /// about:blank's # (about:blank%23goodbye). The rest stays exact.
    private static func same(_ url: URL?, _ address: String) -> Bool {
        guard let seen = url?.absoluteString.removingPercentEncoding,
              let a = seen.firstIndex(of: ":"), let b = address.firstIndex(of: ":") else { return false }
        return seen[..<a].lowercased() == address[..<b].lowercased() && seen[a...] == address[b...]
    }

    private func answers(_ view: WKWebView, _ action: WKNavigationAction) throws -> [WKNavigationActionPolicy] {
        let delegate = try #require(view.navigationDelegate as? Farewell)
        // An absent optional policy callback yields no answer, which fails
        // baseline without letting WebKit's external-open fallback execute.
        let native: any WKNavigationDelegate = delegate
        var replies: [WKNavigationActionPolicy] = []
        native.webView?(view, decidePolicyFor: action) { replies.append($0) }
        return replies
    }

    private func ended(_ view: WKWebView) async throws {
        for _ in 0..<250 where view.navigationDelegate != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.navigationDelegate == nil, "Goodbye must finish or reach its existing deadline")
        #expect(view.superview == nil)
        let selector = NSSelectorFromString("_isClosed")
        if view.responds(to: selector) { #expect(view.value(forKey: "_isClosed") as? Bool == true) }
    }

    @Test func theRealRetirementDelegateRejectsTheWholeMaskedSchemeOnce() async throws {
        let masked = try await actions([
            "webkit-masked-url://hidden/#appTheme=light",
            "WEBKIT-MASKED-URL://hidden/?language=en#appTheme=dark",
            "webkit-masked-url://different/path?query=kept#fragment",
            "webkit-masked-url:opaque"
        ])
        let view = PageView(frame: .zero, configuration: configuration())
        defer { Tab.end(view) }
        view.retire(call: false, pictureInPicture: false)
        for action in masked { #expect(try answers(view, action) == [.cancel]) }
        try await ended(view)
    }

    @Test func retirementKeepsOrdinaryURLsAndTheBlankGoodbyePolicy() async throws {
        let ordinary = try await actions([
            "about:blank", "about:blank#goodbye",
            "https://farewell.fixture.invalid/call-leave",
            "mailto:fixture@example.invalid", "webkit-masked-url-like://control/"
        ])
        let view = PageView(frame: .zero, configuration: configuration())
        defer { Tab.end(view) }
        view.retire(call: false, pictureInPicture: false)
        for action in ordinary { #expect(try answers(view, action) == [.allow]) }
        try await ended(view)
    }

    @Test(arguments: ["close", "sleep", "call-close"])
    func actualTabTeardownOwnsPolicyImmediatelyIncludingTheCallWait(mode: String) async throws {
        let action = try #require(try await actions(["webkit-masked-url://hidden/#appTheme=light"]).first)
        let tab = Tab(shy: true, bench: true, configuration: configuration(), factory: .webKitOnly)
        tab.setAddressOptimistically(URL(string: "about:blank#farewell-tab")!)
        let view = requireNativeWebKitFixture(tab, "FarewellNavigationTests")
        defer { tab.close(); Tab.end(view) }
        #expect(!tab.store.isPersistent)
        if mode == "call-close" { tab.pretendCall(true) }
        if mode == "sleep" { tab.sleep(picture: nil) } else { tab.close() }
        // No await between retirement and this check: call Leave has not
        // answered its asynchronous JavaScript request yet.
        #expect(tab.builtPage == nil)
        #expect(try answers(view, action) == [.cancel])
        #expect(mode == "sleep" ? !tab.gone && tab.pending == tab.address : tab.gone)
        try await ended(view)
    }

    private final class Left: NSObject, WKScriptMessageHandler {
        var calls = 0
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "leave" { calls += 1 }
        }
    }

    @Test func theExistingCallLeaveStillRunsAndThePageEnds() async throws {
        let view = PageView(frame: .zero, configuration: configuration()), capture = Capture(), left = Left()
        capture.reject = false
        view.navigationDelegate = capture
        let world = PageWorld.named("call").contentWorld
        view.configuration.userContentController.add(left, contentWorld: world, name: "farewellProbe")
        defer {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "farewellProbe", contentWorld: world)
            Tab.end(view)
        }
        let oldNavigation = try #require(view.loadHTMLString("<!doctype html><title>Owned farewell call</title>", baseURL: nil))
        for _ in 0..<200 where !capture.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(capture.finished)
        let installed = try await view.run("""
            window.__yabCall = { leave: async function() {
              window.webkit.messageHandlers.farewellProbe.postMessage('leave');
              await new Promise(resolve => { window.__finishFarewell = resolve; });
              return false;
            }};
            true;
            """, in: .named("call"))
        try #require(installed as? Bool == true)
        view.retire(call: true, pictureInPicture: false)
        let farewell = try #require(view.navigationDelegate as? Farewell)
        // These are terminal callbacks for the old document, before the
        // held Leave has answered. Installing policy earlier must not let
        // them close the view ahead of the existing call-leave boundary.
        farewell.webView(view, didFinish: oldNavigation)
        let oldError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        farewell.webView(view, didFail: oldNavigation, withError: oldError)
        farewell.webView(view, didFailProvisionalNavigation: oldNavigation, withError: oldError)
        #expect(view.navigationDelegate === farewell)
        for _ in 0..<200 where left.calls == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(left.calls == 1, "The real CallStage leave must still invoke the owned page's Leave")
        #expect(view.navigationDelegate === farewell)
        #expect(try await view.run("document.title") as? String == "Owned farewell call")
        #expect(try await view.run("window.__finishFarewell(); true;", in: .named("call")) as? Bool == true)
        try await ended(view)
    }
}
