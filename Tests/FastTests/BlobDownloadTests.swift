import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct BlobDownloadTests {
    private final class Saver: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let file: URL
        var download: WKDownload?
        var finished = false
        var error: Error?
        var events: [String] = []

        init(file: URL) { self.file = file }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            events.append("action download=\(action.shouldPerformDownload)")
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            events.append("action became download")
            self.download = download
            download.delegate = self
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            events.append("response mime=\(response.response.mimeType ?? "") show=\(response.canShowMIMEType)")
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            events.append("response became download")
            self.download = download
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            completionHandler(file)
        }

        func downloadDidFinish(_ download: WKDownload) { finished = true }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { self.error = error }
    }

    @Test(arguments: ["anchor", "generated", "fetched", "inline"])
    func ordinaryBlobSavesWriteTheirBytesInPlainWebKit(kind: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blob-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("blob.bin")
        let saver = Saver(file: file)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
        view.navigationDelegate = saver
        defer { view.stopLoading(); view.navigationDelegate = nil; saver.download?.delegate = nil }
        let server = try DownloadPartTests.SlowServer(html: """
            <!doctype html><a id="save" download="blob.bin">Save</a>
            <button id="inline" onclick="window.scope = {type:typeof URL, documentURL:URL===document.URL};
            const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob fixture'],{type:'text/plain'}));
            a.download='blob.bin';document.body.appendChild(a);a.click()">Inline save</button>
            <script>
            window.errors = []; window.stage = "ready";
            addEventListener('unhandledrejection', event => errors.push(String(event.reason)));
            function save(blob) {
                const a = document.createElement('a');
                a.href = URL.createObjectURL(blob); a.download = 'blob.bin';
                document.body.appendChild(a); a.click();
            }
            document.getElementById('save').href = URL.createObjectURL(new Blob(['blob fixture'], {type:'text/plain'}));
            window.ready = true;
            </script>
            """)
        defer { server.stop() }
        view.load(URLRequest(url: server.url("/")))
        var ready = false
        for _ in 0..<500 where !ready {
            ready = (try? await view.evaluateJavaScript("window.ready === true")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(ready)
        let script: String
        switch kind {
        case "anchor": script = "document.getElementById('save').click(); 1"
        case "inline": script = "document.getElementById('inline').click(); 1"
        case "generated": script = "save(new Blob(['blob fixture'], {type:'text/plain'})); 1"
        default:
            // The native probe covers the real click across the fetch.
            // Here the save gets its own client evaluation after the bytes arrive.
            let size = try await view.callAsyncJavaScript("""
                const response = await fetch('/slow');
                window.fetchedBlob = await response.blob();
                return window.fetchedBlob.size;
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(size as? Int == DownloadPartTests.SlowServer.total)
            script = "save(window.fetchedBlob); window.stage='saved'; 1"
        }
        _ = try await view.evaluateJavaScript(script)
        for _ in 0..<1500 where !saver.finished && saver.error == nil { try await Task.sleep(for: .milliseconds(20)) }
        print("Blob \(kind): \(saver.events)")
        #expect(saver.error == nil)
        #expect((try await view.evaluateJavaScript("errors.length")) as? Int == 0)
        if kind == "inline" {
            #expect((try await view.evaluateJavaScript("scope.type")) as? String == "string")
            #expect((try await view.evaluateJavaScript("scope.documentURL")) as? Bool == true)
        }
        if kind == "fetched" {
            #expect((try await view.evaluateJavaScript("stage")) as? String == "saved")
        }
        try #require(saver.finished)
        let expected = kind == "fetched" ? Data(repeating: 0x5A, count: DownloadPartTests.SlowServer.total) : Data("blob fixture".utf8)
        #expect(try Data(contentsOf: file) == expected)
    }
}
