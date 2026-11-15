import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageDownloadEventsTests {
    private final class Listener: NSObject, PageDownloadEvents, PageEvents {
        var download: (any PageDownload)?
        var response: URLResponse?
        var name: String?
        var destination: (@MainActor (URL?) -> Void)?
        var finished = false
        var failed: Error?
        var resumeData: Data?
        var became: (any PageDownload)?
        var mainFrame: Bool?
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.download) }
        func page(_ page: any PageHandle, became download: any PageDownload, isMainFrame: Bool) {
            became = download; mainFrame = isMainFrame; download.downloadEvents = self
        }
        func download(_ download: any PageDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
            self.download = download; self.response = response; name = suggestedFilename; destination = completionHandler
        }
        func downloadDidFinish(_ download: any PageDownload) { finished = true }
        func download(_ download: any PageDownload, didFailWithError error: Error, resumeData: Data?) {
            failed = error; self.resumeData = resumeData
        }
    }

    @Test(arguments: [false, true])
    func realDownloadWaitsForDestinationAndTransfersFutureLifecycle(cut: Bool) async throws {
        let server = try DownloadPartTests.SlowServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { server.stop(); try? FileManager.default.removeItem(at: folder) }
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let listener = Listener(), next = Listener()
        let raw: WKDownload = await withCheckedContinuation { done in
            view.startDownload(using: URLRequest(url: server.url(cut ? "/cut" : "/slow"))) { download in
                MainActor.assumeIsolated { download.downloadEvents = listener }
                done.resume(returning: download)
            }
        }
        let download: any PageDownload = raw
        defer { download.downloadEvents = nil; view.stopLoading() }
        for _ in 0..<1500 where listener.destination == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reply = try #require(listener.destination), file = folder.appendingPathComponent("part.bin")
        #expect(listener.name == "part.bin" && listener.response?.url == download.originalRequest?.url)
        #expect(download.page === view && download.downloadID == raw.downloadID)
        #expect(ObjectIdentifier(download) == ObjectIdentifier(raw))
        #expect(raw.delegate is WebKitDownloadEvents)
        #expect(!FileManager.default.fileExists(atPath: file.path) && !listener.finished && listener.failed == nil)
        download.downloadEvents = next
        reply(file); reply(folder.appendingPathComponent("ignored.bin"))
        for _ in 0..<1500 where !next.finished && next.failed == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!listener.finished && listener.failed == nil && next.destination == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("ignored.bin").path))
        if cut {
            #expect(next.failed != nil && !next.finished && next.resumeData == nil)
        } else {
            #expect(next.finished && next.failed == nil)
            #expect(try Data(contentsOf: file).count == DownloadPartTests.SlowServer.total)
        }
    }

    @Test func aRealNavigationBecomesAnOwnedDownloadBeforeAskingForDestination() async throws {
        let server = try DownloadPartTests.SlowServer(), listener = Listener()
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        view.events = listener
        defer { server.stop(); view.stopLoading(); view.events = nil }
        view.navigate(to: URLRequest(url: server.url("/slow")))
        for _ in 0..<1500 where listener.destination == nil { try await Task.sleep(for: .milliseconds(20)) }
        let download = try #require(listener.became), reply = try #require(listener.destination)
        #expect(listener.mainFrame == true && listener.download === download)
        #expect(download.page === view && download.downloadEvents === listener)
        reply(nil); reply(URL(fileURLWithPath: "/tmp/ignored-page-download"))
        for _ in 0..<300 where listener.failed == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(listener.failed != nil && !listener.finished)
    }

    @Test func browserRetainsTheDownloadAndInstallsAWeakAdapterListener() async throws {
        let server = try DownloadPartTests.SlowServer()
        defer { server.stop() }
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let raw = await view.startDownload(using: URLRequest(url: server.url("/slow")))
        var browser: Browser? = Browser(windowID: UUID())
        weak var weakBrowser = browser
        browser?.page(view, became: raw, isMainFrame: true)
        #expect(browser?.downloading.count == 1 && browser?.downloading.first === raw)
        #expect(raw.downloadEvents === browser)
        #expect(raw.delegate !== browser)
        #expect(browser?.downloadBecame[ObjectIdentifier(raw)]?() === view)
        browser = nil
        #expect(weakBrowser == nil && raw.downloadEvents == nil)
        // With its owner gone, a destination question is refused rather
        // than waiting forever for a download UI that no longer exists.
        var answers: [URL?] = []
        (raw.delegate as? WebKitDownloadEvents)?.download(raw, decideDestinationUsing: URLResponse(), suggestedFilename: "part.bin") {
            answers.append($0)
        }
        #expect(answers.count == 1 && answers[0] == nil)
        await raw.cancel()
    }
}
