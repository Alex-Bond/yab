import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumDownloadsTests {
    private final class Listener: PageDownloadEvents {
        var finished = 0, failures = 0
        var resumeData: Data?
        func download(_ download: any PageDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) { completionHandler(nil) }
        func downloadDidFinish(_ download: any PageDownload) { finished += 1 }
        func download(_ download: any PageDownload, didFailWithError error: Error, resumeData: Data?) { failures += 1; self.resumeData = resumeData }
    }
    @Test func terminalResultIsDeliveredOnlyOnce() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let download = ChromiumDownload(page: page, id: "fixture", tab: "fixture-tab")
        download.downloadEvents = listener
        download.receive(["received": .number(40), "total": .number(100)])
        #expect(download.progress.completedUnitCount == 40)
        #expect(download.progress.totalUnitCount == 100)
        download.receive(["received": .number(100), "total": .number(100), "complete": .bool(true), "path": .string("/tmp/fixture.txt")])
        download.receive(["canceled": .bool(true)])
        #expect(listener.finished == 1)
        #expect(listener.failures == 0)
        #expect(download.progress.fileURL?.path == "/tmp/fixture.txt")
    }
    @Test func unsupportedRequestMetadataIsNotInvented() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let download = ChromiumDownload(page: page, id: "fixture", tab: "fixture-tab")
        #expect(download.originalRequest == nil)
        #expect(download.isUserInitiated == false)
        var called = false
        download.restartDownload(from: nil, fallback: page) { #expect($0 == nil); called = true }
        #expect(called)
        #expect(page.remoteID == nil)
    }
    @Test func interruptionCannotLaterBecomeSuccess() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let download = ChromiumDownload(page: page, id: "fixture", tab: "fixture-tab")
        download.downloadEvents = listener
        download.receive(["interrupted": .bool(true), "reason": .number(30)])
        download.receive(["complete": .bool(true)])
        #expect(listener.failures == 1)
        #expect(listener.finished == 0)
    }
    @Test func nativeProvenanceAndResumeAreOnlyWhatChromiumSaid() {
        _ = NSApplication.shared
        let tab = Tab(shy: true), listener = Listener()
        let page = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        let source = URL(string: "https://files.example/report.csv")!
        let download = ChromiumDownload(page: page, id: "fixture", tab: "fixture-tab", source: source)
        #expect(download.originalRequest?.url == source)
        #expect(download.isUserInitiated == false)
        download.downloadEvents = listener
        // Not resumable: no resume data, so Try Again cannot replay it.
        download.receive(["interrupted": .bool(true), "reason": .number(2)])
        #expect(listener.resumeData == nil)
        var called = false
        download.restartDownload(from: ChromiumDownload.resumeMark, fallback: page) { #expect($0 == nil); called = true }
        #expect(called)
        let resumable = ChromiumDownload(page: page, id: "fixture-2", tab: "fixture-tab", source: source)
        resumable.downloadEvents = listener
        resumable.receive(["interrupted": .bool(true), "resumable": .bool(true), "reason": .number(20)])
        #expect(listener.resumeData == ChromiumDownload.resumeMark)
        var foreign = false
        resumable.restartDownload(from: Data("webkit".utf8), fallback: page) { #expect($0 == nil); foreign = true }
        #expect(foreign)
    }
    @Test func onlyYabsOwnRequestCountsAsUserInitiated() {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab), other = ChromiumPage(tab: tab)
        defer { page.retire(call: false, pictureInPicture: false); other.retire(call: false, pictureInPicture: false); tab.close() }
        let url = URL(string: "https://files.example/picture.png")!
        ChromiumDownload.ask(url, on: page)
        #expect(!ChromiumDownload.wasAsked([url], on: other))
        #expect(ChromiumDownload.wasAsked([URL(string: "https://elsewhere.example/")!, url], on: page))
        #expect(!ChromiumDownload.wasAsked([url], on: page))
    }
    @Test func unrepresentableWireCountsDoNotOverflow() {
        // Int64.max rounds upward to 2^63 in wire v1's Double representation.
        #expect(ChromiumDownload.byteCount(.number(Double(Int64.max)), unknown: -1) == -1)
        #expect(ChromiumDownload.byteCount(.number(.infinity), unknown: 0) == 0)
        #expect(ChromiumDownload.byteCount(.number(-8), unknown: 0) == 0)
        #expect(ChromiumDownload.byteCount(.number(12345), unknown: -1) == 12345)
        #expect(ChromiumDownload.nativeIdentifier(.number(1)) == 1)
        for value in [0.0, -1, 1.5, .infinity, Double(UInt32.max) + 1] {
            #expect(ChromiumDownload.nativeIdentifier(.number(value)) == nil)
        }
    }

}
