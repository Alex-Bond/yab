import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct HoardDownloadFailureTests {
    private final class Download: PageDownload {
        let downloadID = UUID()
        let originalRequest: URLRequest? = URLRequest(url: URL(string: "https://download.invalid/file.bin")!)
        let isUserInitiated = true
        let progress = Progress(totalUnitCount: 100)
        var page: (any PageHandle)? { nil }
        let source = NSView(frame: .zero)
        var sourceView: NSView? { source }
        var pageURL: URL? { nil }
        var pageTitle: String? { nil }
        weak var downloadEvents: (any PageDownloadEvents)?
        var retries = 0
        var receivedResume: Data?
        func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) { done(nil) }
        func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                             done: @escaping @MainActor ((any PageDownload)?) -> Void) {
            retries += 1
            receivedResume = resumeData
            done(nil)
        }
    }

    private func flight(_ body: (Hoard, Download) async throws -> Void) async throws {
        _ = NSApplication.shared
        try #require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "The fixture exercises the animated arrival path")
        let sky = HoardSkyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hoard = Hoard(), download = Download()
        hoard.sky = sky
        defer { hoard.finish(download) }
        hoard.notePress(at: CGPoint(x: 200, y: 300))
        hoard.expect(download)
        hoard.begin(download, name: "file.bin", from: "download.invalid")
        try #require(hoard.airborne == 1 && hoard.fetches.isEmpty, "The real row must still be in flight")
        try await body(hoard, download)
    }

    @Test(arguments: [false, true])
    func failureBeforeArrivalKeepsItsRowAndRetryState(resumable: Bool) async throws {
        try await flight { hoard, download in
            hoard.fail(download, resumeData: resumable ? Data("resume fixture".utf8) : nil)
            for _ in 0..<150 where hoard.airborne != 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(hoard.airborne == 0)
            let fetch = try #require(hoard.fetches.first)
            #expect(fetch.id == ObjectIdentifier(download) && fetch.name == "file.bin" && fetch.failed)
            #expect(hoard.going.isEmpty && hoard.unseen && hoard.calling)
            hoard.retry(fetch)
            #expect(download.retries == 1)
            #expect(download.receivedResume == (resumable ? Data("resume fixture".utf8) : nil))
            hoard.dismiss(fetch)
            #expect(hoard.fetches.isEmpty)
        }
    }

    @Test func completionBeforeArrivalDoesNotResurrectTheRow() async throws {
        try await flight { hoard, download in
            hoard.finish(download)
            for _ in 0..<150 where hoard.airborne != 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(hoard.airborne == 0 && hoard.fetches.isEmpty && !hoard.unseen)
        }
    }
}
