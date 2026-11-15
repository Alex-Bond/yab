import AppKit
import Network
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct ImageDownloadTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    @Test func aFastNativeImageMenuPickWaitsForTheContentProcessReceipt() async throws {
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        web.loadHTMLString("<!doctype html><title>Image receipt</title>", baseURL: nil)
        var ready = false
        for _ in 0..<1000 where !ready {
            ready = (try? await web.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(ready)
        defer { web.stopLoading(); web.onImage = nil }
        var calls = 0
        web.onImage = { action, _, _ in
            #expect(action == .download)
            calls += 1
            return calls > 1
        }
        let item = NSMenuItem(title: "Download Image", action: NSSelectorFromString("imageRow:"), keyEquivalent: "")
        item.representedObject = ImageAct.download.rawValue
        _ = web.perform(NSSelectorFromString("imageRow:"), with: item)
        for _ in 0..<1000 where calls < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls == 2, "A missing early receipt is retried after the page round trip")
    }

    private final class Server: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "image-download-server")
        let bytes: Data
        var port: UInt16 = 0
        init(_ bytes: Data) throws {
            self.bytes = bytes
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: 0)!)
            listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state { case .ready, .failed: ready.signal(); default: break }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: queue)
                read(connection, Data())
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 10) == .success, let assigned = listener.port else { throw URLError(.cannotConnectToHost) }
            port = assigned.rawValue
        }
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)" + path)! }
        func read(_ connection: NWConnection, _ prior: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, done, error in
                guard let self else { return connection.cancel() }
                let data = prior + (bytes ?? Data())
                guard let end = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
                    if !done && error == nil { read(connection, data) } else { connection.cancel() }
                    return
                }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body: Data, fields: String, status: String
                switch path {
                case "/page":
                    body = Data("<!doctype html><script>window.ready=true</script>".utf8)
                    fields = "Content-Type: text/html\r\nSet-Cookie: image-fixture=owned; Path=/; HttpOnly\r\n"
                    status = "200 OK"
                case "/redirect":
                    body = Data(); fields = "Location: /image.png\r\n"; status = "302 Found"
                default:
                    let allowed = head.lowercased().contains("cookie: image-fixture=owned")
                        && head.contains("Referer: " + url("/page").absoluteString)
                    body = allowed ? self.bytes : Data("Access denied".utf8)
                    fields = "Content-Type: \(allowed ? "image/png" : "text/html")\r\n"
                    status = allowed ? "200 OK" : "403 Forbidden"
                }
                let response = Data("HTTP/1.1 \(status)\r\n\(fields)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private final class Frame: NSObject, WKScriptMessageHandler {
        var frame: WKFrameInfo?
        var url: URL?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            frame = message.frameInfo
            url = (message.body as? String).flatMap(URL.init(string:))
        }
    }

    private final class Sink: PageDownloadEvents {
        let folder: URL
        var file: URL?
        var failed: Error?
        var finished = false
        init(_ folder: URL) { self.folder = folder }
        func download(_ download: any PageDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
            let target = folder.appendingPathComponent(suggestedFilename)
            file = target; completionHandler(target)
        }
        func downloadDidFinish(_ download: any PageDownload) { finished = true }
        func download(_ download: any PageDownload, didFailWithError error: Error, resumeData: Data?) { failed = error }
    }

    @Test(arguments: ["data", "blob", "blob-untyped", "frame-blob"])
    func actualImageBytesFromInlineAndTheOwningBlobFrameReachDisk(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = WKWebViewConfiguration(), receipt = Frame()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(receipt, name: "imageFixture")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "imageFixture"); try? FileManager.default.removeItem(at: root) }
        let encoded = Self.png.base64EncodedString()
        let script = """
        const bytes = Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0));
        const source = window.URL.createObjectURL(new Blob([bytes], {type: '\(kind == "blob-untyped" ? "" : "image/png")'}));
        window.webkit.messageHandlers.imageFixture.postMessage(source);
        """
        let content = kind == "frame-blob"
            ? "<iframe srcdoc=\"<script>\(script.replacingOccurrences(of: "\"", with: "&quot;"))</script>\"></iframe>"
            : "<script>\(script)</script>"
        web.loadHTMLString("<!doctype html>" + content, baseURL: URL(string: "https://image-fixture.invalid/"))
        for _ in 0..<1500 where receipt.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let blob = try #require(receipt.url)
        if kind == "frame-blob" { #expect(receipt.frame?.isMainFrame == false) }
        let url = kind == "data" ? URL(string: "data:image/png;base64," + encoded)! : blob
        let download = ImageDownload(url: url, page: web, frame: receipt.frame), sink = Sink(root)
        download.downloadEvents = sink
        download.start()
        for _ in 0..<1500 where !sink.finished && sink.failed == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sink.failed == nil && sink.finished)
        let file = try #require(sink.file)
        #expect(file.pathExtension == "png")
        #expect(try Data(contentsOf: file) == Self.png)
        #expect(download.progress.completedUnitCount == Int64(Self.png.count))
        #expect(NSImage(contentsOf: file) != nil)
    }

    @Test(arguments: ["/image.png", "/redirect"])
    func browserImageDownloadRetainsThePageCookiesAndReferrerAndPublishesThePNG(path: String) async throws {
        try #require(Store.testing)
        let server = try Server(Self.png)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-image-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let browser = Browser(windowID: UUID())
        browser.dropSpare(); browser.lay([])
        let old = (browser.prefs.downloads, browser.prefs.asksWhereToSave, browser.prefs.tidyDownloads)
        browser.prefs.downloads = root; browser.prefs.asksWhereToSave = false; browser.prefs.tidyDownloads = false
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: config)
        browser.lay([tab]); browser.activeID = tab.id
        tab.go(to: server.url("/page"))
        let web = try #require(tab.built)
        defer {
            server.listener.cancel(); browser.discardUnfinishedDownloads()
            for fetch in browser.hoard.fetches { browser.hoard.dismiss(fetch) }
            tab.close(); browser.dropSpare(); browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.downloads = old.0; browser.prefs.asksWhereToSave = old.1; browser.prefs.tidyDownloads = old.2
            try? FileManager.default.removeItem(at: root)
        }
        var ready = false
        for _ in 0..<1500 where !ready {
            ready = (try? await web.evaluateJavaScript("window.ready === true")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(20)) }
        }
        try #require(ready)
        browser.imageAct(.download, server.url(path), in: tab)
        for _ in 0..<1500 where browser.completedDownloadIDs.isEmpty && browser.failedDownloadIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(browser.failedDownloadIDs.isEmpty && browser.completedDownloadIDs.count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let written = try Data(contentsOf: file)
        #expect(files.count == 1 && written == Self.png)
        #expect(NSImage(contentsOf: file) != nil)
        #expect(browser.downloadParts.isEmpty && browser.downloading.isEmpty)
    }
}
