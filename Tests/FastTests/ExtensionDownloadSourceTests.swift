import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor
struct ExtensionDownloadSourceTests {
    @Test func sameURLDownloadsKeepTheirOwnExtensionIdentity() async throws {
        let server = try DownloadPartTests.SlowServer()
        defer { server.stop() }
        let web = WKWebView(frame: .zero)
        let first = await web.startDownload(using: URLRequest(url: server.url("/slow")))
        let second = await web.startDownload(using: URLRequest(url: server.url("/slow")))
        ExtensionDownloads.asking(first, by: "first-extension")
        ExtensionDownloads.asking(second, by: "second-extension")
        // Reverse creation order: a URL-keyed handoff gives the first one
        // the other caller's identity, and leaves the second unowned.
        ExtensionDownloads.created(second); ExtensionDownloads.created(first)
        let a = try #require(ExtensionDownloads.started(first, by: "first-extension"))
        let b = try #require(ExtensionDownloads.started(second, by: "second-extension"))
        #expect(a != b)
        #expect(ExtensionDownloads.item(a)?.byExtension == "first-extension")
        #expect(ExtensionDownloads.item(b)?.byExtension == "second-extension")
        await first.cancel(); await second.cancel()
    }
    @Test func singleFileBlobUsesItsOffscreenDocument() throws {
        let blob = try #require(URL(string: "blob:chrome-extension://mpiodijhokgodhhofbcjdecpffjipkle/123"))
        #expect(ExtensionShims.downloadsFromOffscreen(blob, extensionID: "mpiodijhokgodhhofbcjdecpffjipkle"))
    }

    @Test func otherDownloadsKeepTheirPage() throws {
        let blob = try #require(URL(string: "blob:https://example.com/123"))
        let page = try #require(URL(string: "https://example.com/file.html"))
        #expect(!ExtensionShims.downloadsFromOffscreen(blob, extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn"))
        #expect(!ExtensionShims.downloadsFromOffscreen(page, extensionID: "mpiodijhokgodhhofbcjdecpffjipkle"))
    }
}
