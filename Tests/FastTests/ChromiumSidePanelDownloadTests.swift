import AppKit
import Testing
import WebKit
@testable import Fast

/// A side panel is outside Browser.tabs, but its files still belong to the
/// window's download pipeline. Exercise its actual PageEvents witness.
@MainActor @Suite(.serialized)
struct ChromiumSidePanelDownloadTests {
    private final class Download: PageDownload {
        let downloadID = UUID()
        let originalRequest: URLRequest? = URLRequest(url: URL(string: "https://download.invalid/image.png")!)
        let isUserInitiated = true
        let progress = Progress(totalUnitCount: 5)
        var page: (any PageHandle)? { nil }
        var sourceView: NSView? { nil }
        var pageURL: URL? { nil }
        var pageTitle: String? { nil }
        weak var downloadEvents: (any PageDownloadEvents)?
        func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) { done(nil) }
        func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                             done: @escaping @MainActor ((any PageDownload)?) -> Void) { done(nil) }
    }

    @Test func panelDownloadGetsADestinationAndPublishesItsBytes() async throws {
        let browser = Browser(windowID: UUID())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("panel-download-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = (browser.prefs.downloads, browser.prefs.asksWhereToSave, browser.prefs.tidyDownloads)
        browser.prefs.downloads = folder
        browser.prefs.asksWhereToSave = false
        browser.prefs.tidyDownloads = false
        defer {
            browser.discardUnfinishedDownloads()
            for fetch in browser.hoard.fetches { browser.hoard.dismiss(fetch) }
            browser.dropSpare(); browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.downloads = old.0
            browser.prefs.asksWhereToSave = old.1
            browser.prefs.tidyDownloads = old.2
            try? FileManager.default.removeItem(at: folder)
        }
        let events = ChromiumSidePanel.Events()
        events.browser = browser
        let page = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let download = Download()
        let listener: any PageEvents = events
        listener.page(page, became: download, isMainFrame: true)
        #expect(browser.downloading.contains { $0 === download })
        let owner = try #require(download.downloadEvents)
        #expect(owner === browser)
        // A panel must remain in the column; the browser must not treat it
        // as a transient tab opened only to fetch the file.
        #expect(browser.downloadBecame[ObjectIdentifier(download)] == nil)
        var answered = false
        var destination: URL?
        let response = HTTPURLResponse(url: download.originalRequest!.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        owner.download(download, decideDestinationUsing: response, suggestedFilename: "image.png") {
            answered = true; destination = $0
        }
        for _ in 0..<600 where !answered { try await Task.sleep(for: .milliseconds(10)) }
        let target = try #require(destination)
        let bytes = Data("image".utf8)
        try bytes.write(to: target)
        owner.downloadDidFinish(download)
        for _ in 0..<600 where !browser.completedDownloadIDs.contains(download.downloadID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(browser.completedDownloadIDs.contains(download.downloadID))
        #expect(try Data(contentsOf: folder.appendingPathComponent("image.png")) == bytes)
    }

    @Test func panelResponsesUseTheDownloadPolicy() {
        let events: any PageEvents = ChromiumSidePanel.Events()
        let page = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let response = HTTPURLResponse(url: URL(string: "https://download.invalid/images.zip")!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Disposition": "attachment; filename=images.zip"])!
        var policy: PagePolicy?
        events.page(page, decide: PageDocumentResponse(response: response, isMainFrame: true, canShowMIMEType: false)) { policy = $0 }
        #expect(policy == .download)
    }
}
