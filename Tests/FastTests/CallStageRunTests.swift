import Foundation
import Testing
import WebKit
@testable import Fast

// CallStage.run hands a page its stage script once, not with every verb:
// the call window asks twice a second, and each 100 KB copy was parsed and
// left as the page's garbage, 28 MB a minute in a call out in the window
// (feedback #284, evals/feedback-284).
@MainActor
struct CallStageRunTests {
    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    static func load(_ web: WKWebView, _ html: String) async {
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { go in
            loaded.done = go
            web.loadHTMLString(html, baseURL: URL(string: "https://call.example/room"))
        }
        web.navigationDelegate = nil
    }

    static func run(_ verb: String, on web: WKWebView) async -> Any? {
        await withCheckedContinuation { go in
            CallStage.run(verb, on: web) { go.resume(returning: $0) }
        }
    }

    @Test func scriptGoesInOncePerDocument() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        await Self.load(web, "<p>A call</p>")
        let script = CallStage.source.utf8.count
        let start = CallStage.sent
        for _ in 0..<8 {
            #expect(await Self.run("who", on: web) is [Any])
        }
        let eight = CallStage.sent - start
        // One copy of the script and eight short calls, not eight copies.
        #expect(eight >= script)
        #expect(eight < script + 8 * 200)

        // A new document has no stage: the next verb puts it in again.
        await Self.load(web, "<p>Another page</p>")
        let before = CallStage.sent
        #expect(await Self.run("who", on: web) is [Any])
        #expect(CallStage.sent - before >= script)
        let again = CallStage.sent
        #expect(await Self.run("news", on: web) is [String: Any])
        #expect(CallStage.sent - again < 200)
    }
}
