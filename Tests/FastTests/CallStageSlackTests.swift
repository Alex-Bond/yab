import Foundation
import Testing
import WebKit
@testable import Fast

// A Slack huddle, told Chrome (SiteAgent): its tab keeps only a bar with
// Leave, its own window has the switches. CallStage finds Leave in both;
// CallRelay reads the window's microphone and camera by Slack's labels.
@MainActor
struct CallStageSlackTests {
    static let snapshots = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evals/calls/slack/snapshots")
    static let address = URL(string: "https://app.slack.com/client/T01/C02")!

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    final class Heard: NSObject, WKScriptMessageHandler {
        var said: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { said.append(body) }
        }
    }

    static func page(_ state: String, heard: Heard? = nil) async throws -> WKWebView {
        let html = try String(contentsOf: snapshots.appendingPathComponent(state + ".html"), encoding: .utf8)
        let config = WKWebViewConfiguration()
        if let heard {
            config.userContentController.add(heard, contentWorld: Web.world, name: CallRelay.name)
            config.userContentController.addUserScript(WKUserScript(source: CallRelay.script, injectionTime: .atDocumentEnd,
                                                                     forMainFrameOnly: true, in: Web.world))
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { go in
            loaded.done = go
            web.loadHTMLString(html, baseURL: address)
        }
        _ = loaded
        return web
    }

    static func heard(_ web: WKWebView) async throws -> [String: Any] {
        let got = try await web.callAsyncJavaScript(CallStage.source + "\nreturn window.__yabCall.heard();",
                                                    arguments: [:], in: nil, contentWorld: CallStage.world)
        return try #require(got as? [String: Any])
    }

    @Test func tabBarHasLeave() async throws {
        let heard = try await Self.heard(try await Self.page("huddle-tab-bar"))
        #expect(heard["leave"] as? Bool == true)
    }

    @Test func windowHasItsControls() async throws {
        let heard = try await Self.heard(try await Self.page("huddle-window"))
        #expect(heard["leave"] as? Bool == true)
        #expect(heard["share"] as? Bool == true)
        #expect(heard["canHand"] as? Bool == true)
        #expect(heard["canChat"] as? Bool == true)
        #expect(heard["canReact"] as? Bool == true)
    }

    /// The window's switches as Slack labels them: unmuted, camera off.
    @Test func relayReadsTheWindow() async throws {
        let heard = Heard()
        let web = try await Self.page("huddle-window", heard: heard)
        for _ in 0..<30 where heard.said.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let last = try #require(heard.said.last)
        #expect(last["mic"] as? Bool == false)
        #expect(last["camera"] as? Bool == true)
        // Pressed through Slack's own button: its label turns over.
        _ = try await web.callAsyncJavaScript("""
            document.querySelector('[data-qa="segmented-mute-button-main"]').addEventListener('click', function () {
              this.setAttribute('aria-label', 'Unmute microphone');
            });
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await web.callAsyncJavaScript("return window.__yabCall.press('mic');", arguments: [:], in: nil, contentWorld: Web.world)
        for _ in 0..<30 where heard.said.last?["mic"] as? Bool != true { try await Task.sleep(for: .milliseconds(100)) }
        #expect(heard.said.last?["mic"] as? Bool == true)
    }
}
