import AppKit
import Testing
import WebKit
@testable import Fast

struct FilePickerPageTests {
    @MainActor
    private static func page(_ body: String) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: DropFrame.ground + "\n" + WalletRelay.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world
        ))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        web.loadHTMLString("""
        <html><body>\(body)
        <script>
        // Exercise the page's click handlers without opening a system panel.
        document.addEventListener('click', e => {
            if (e.target.type === 'file') e.preventDefault();
        }, true);
        </script></body></html>
        """, baseURL: URL(string: "https://example.test/upload"))
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript("return !!window.__yabForm", contentWorld: Web.world)) as? Bool == true {
                return web
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CocoaError(.fileReadUnknown)
    }

    @MainActor
    private static func spot(_ web: WKWebView) async throws -> [String: Any]? {
        try await web.callAsyncJavaScript("return window.__yabForm.fileSpot()", contentWorld: Web.world) as? [String: Any]
    }

    @Test @MainActor func removedUploadMenuKeepsHiddenFileMetadata() async throws {
        let accept = "image/jpeg,image/png,image/webp,image/gif,video/mp4,video/quicktime"
        let web = try await Self.page("""
        <input id=file type=file accept="\(accept)" multiple
               style="width:0.1px;height:0.1px;opacity:0;position:absolute;z-index:-1">
        <div id=menu><button role=menuitem onclick="document.getElementById('file').click(); document.getElementById('menu').remove()">Upload</button></div>
        """)
        _ = try await web.evaluateJavaScript("document.querySelector('[role=menuitem]').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('menu') === null") as? Bool == true)
        let info = try #require(try await Self.spot(web))
        #expect(info["accept"] as? String == accept)
        #expect(info["multiple"] as? Bool == true)
        #expect(info["rect"] is NSNull)
        // There is no visible target to highlight, but Files can still open.
        #expect(try await web.evaluateJavaScript("document.querySelector('yab-marks') === null") as? Bool == true)
    }

    @Test @MainActor func hiddenSingleFileKeepsItsLabelAndFilter() async throws {
        let web = try await Self.page("<input id=file type=file accept=.pdf aria-label=Receipt hidden>")
        _ = try await web.evaluateJavaScript("document.getElementById('file').click()")
        let info = try #require(try await Self.spot(web))
        #expect(info["accept"] as? String == ".pdf")
        #expect(info["label"] as? String == "Receipt")
        #expect(info["multiple"] as? Bool == false)
        #expect(info["rect"] is NSNull)
        _ = try await web.callAsyncJavaScript("window.__yabForm.fileDone()", contentWorld: Web.world)
    }

    @Test @MainActor func visibleLabelStillGetsHighlighted() async throws {
        let web = try await Self.page("""
        <label for=file style="display:inline-block;padding:12px">Receipt</label>
        <input id=file type=file accept=.pdf hidden>
        """)
        _ = try await web.evaluateJavaScript("document.getElementById('file').click()")
        let info = try #require(try await Self.spot(web))
        let rect = try #require(info["rect"] as? [String: Any])
        #expect((rect["w"] as? Double ?? 0) > 8)
        #expect(info["label"] as? String == "Receipt")
        #expect(try await web.evaluateJavaScript("document.querySelector('yab-marks') !== null") as? Bool == true)
        _ = try await web.callAsyncJavaScript("window.__yabForm.fileDone()", contentWorld: Web.world)
    }

    @Test @MainActor func unrelatedHiddenInputDoesNotBecomeARequest() async throws {
        let web = try await Self.page("<input type=file accept=.pdf hidden>")
        #expect(try await Self.spot(web) == nil)
    }
}
