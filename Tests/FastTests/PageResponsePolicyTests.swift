import Foundation
import Testing
@testable import Fast

struct PageResponsePolicyTests {
    private let url = URL(string: "https://example.test/page")!

    // URLResponse's initializer supplies application/octet-stream for nil,
    // so override the getter to represent WebKit's unclassified response.
    private final class UntypedResponse: URLResponse, @unchecked Sendable {
        override var mimeType: String? { nil }
    }

    @Test func unclassifiedResponseDoesNotTurnAnUnfinishedPageIntoADownload() {
        let response = UntypedResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
        #expect(PageResponsePolicy.decide(response, canShowMIMEType: false) == .allow)
    }

    @Test func processHandoffPlaceholderDoesNotBecomeADownload() throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 0, httpVersion: nil,
                                                   headerFields: ["Content-Type": "application/octet-stream"]))
        #expect(PageResponsePolicy.decide(response, canShowMIMEType: false) == .allow)
    }

    @Test func redirectsAreFollowedEvenWithAnUnsupportedType() throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                                   headerFields: ["Content-Type": "application/octet-stream", "Location": "/next"]))
        #expect(PageResponsePolicy.decide(response, canShowMIMEType: false) == .allow)
    }

    @Test func explicitAttachmentsStillDownloadWithoutAType() throws {
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Content-Disposition": " attachment; filename=report.pdf"]))
        #expect(PageResponsePolicy.decide(response, canShowMIMEType: true) == .download)
    }

    @Test func knownDocumentsRenderAndUnsupportedFilesDownload() {
        let html = URLResponse(url: url, mimeType: "text/html", expectedContentLength: 100, textEncodingName: "utf-8")
        let archive = URLResponse(url: url, mimeType: "application/zip", expectedContentLength: 100, textEncodingName: nil)
        #expect(PageResponsePolicy.decide(html, canShowMIMEType: true) == .allow)
        #expect(PageResponsePolicy.decide(archive, canShowMIMEType: false) == .download)
    }
}
