import Foundation
import Testing
@testable import Fast

struct ExtensionPageCaptureTests {
    @Test func aWebArchiveBecomesMultipartRelatedWithEveryPartsAddress() throws {
        let archive: [String: Any] = [
            "WebMainResource": ["WebResourceURL": "https://site.test/page.html", "WebResourceMIMEType": "text/html",
                                "WebResourceTextEncodingName": "UTF-8", "WebResourceData": Data("<p>hi</p>".utf8)],
            "WebSubresources": [["WebResourceURL": "https://site.test/a.png", "WebResourceMIMEType": "image/png",
                                 "WebResourceData": Data([0x89, 0x50, 0x4e, 0x47])]],
            "WebSubframeArchives": [[
                "WebMainResource": ["WebResourceURL": "https://other.test/frame.html", "WebResourceMIMEType": "text/html",
                                    "WebResourceData": Data("<p>frame</p>".utf8)],
                "WebSubresources": [["WebResourceURL": "https://site.test/a.png", "WebResourceMIMEType": "image/png",
                                     "WebResourceData": Data([0x89])]],
            ]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let made = try #require(ExtensionPageCapture.mhtml(fromArchive: data, title: "Café menu"))
        let text = String(decoding: made, as: UTF8.self)
        #expect(text.contains("Snapshot-Content-Location: https://site.test/page.html"))
        #expect(text.contains("Content-Type: multipart/related;"))
        #expect(text.contains("Subject: =?utf-8?B?"))
        // Each address once, the page first.
        #expect(text.components(separatedBy: "Content-Location: https://site.test/a.png").count == 2)
        #expect(text.contains("Content-Location: https://other.test/frame.html"))
        let first = try #require(text.range(of: "Content-Location: "))
        #expect(text[first.upperBound...].hasPrefix("https://site.test/page.html"))
        #expect(text.contains("Content-Type: text/html;charset=UTF-8"))
    }

    @Test func notAnArchiveIsNothing() {
        #expect(ExtensionPageCapture.mhtml(fromArchive: Data("nope".utf8), title: "") == nil)
    }
}
