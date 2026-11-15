import Foundation
import Testing
@testable import Fast

struct DownloadRequestTests {
    @Test func requestKeepsReferrerPolicyAndNeverLeaksCredentialsOrFragments() throws {
        let source = try #require(URL(string: "https://user:secret@images.example/results?q=map#selected"))
        let same = try #require(URL(string: "https://images.example/map.png"))
        let other = try #require(URL(string: "https://cdn.example/map.png"))
        let plain = try #require(URL(string: "http://cdn.example/map.png"))
        #expect(DownloadRequest.resource(same, from: source).value(forHTTPHeaderField: "Referer") == "https://images.example/results?q=map")
        #expect(DownloadRequest.resource(other, from: source).value(forHTTPHeaderField: "Referer") == "https://images.example/")
        #expect(DownloadRequest.resource(plain, from: source).value(forHTTPHeaderField: "Referer") == nil)
        #expect(DownloadRequest.referrer(from: source, to: same, policy: "no-referrer") == nil)
        #expect(DownloadRequest.referrer(from: source, to: other, policy: "same-origin") == nil)
        #expect(DownloadRequest.referrer(from: source, to: same, policy: "origin") == "https://images.example/")
        #expect(DownloadRequest.referrer(from: URL(string: "file:///secret"), to: same) == nil)
    }

    @Test(arguments: ["../../outside.bin", "/tmp/outside.bin", "..\\outside.bin", "outside.bin\u{0000}"])
    func serverFilenamesCannotEscapeTheChosenFolder(name: String) {
        #expect(DownloadRequest.filename(name) == "outside.bin")
    }

    @Test(arguments: ["", ".", "..", "\n\t"])
    func invalidNamesHaveAnActualFilename(name: String) { #expect(DownloadRequest.filename(name) == "download") }

    @Test func longUnicodeNamesFitTheFilesystemAndKeepTheExtension() {
        let name = DownloadRequest.filename(String(repeating: "界", count: 200) + ".png")
        #expect(name.utf8.count <= 240 && name.hasSuffix(".png"))
    }

    @Test func dataImagesDecodeBothBase64AndPercentEncodedBinary() throws {
        #expect(try ImageDownload.inline(URL(string: "data:image/png;base64,%2FwAB")!).data == Data([255, 0, 1]))
        #expect(try ImageDownload.inline(URL(string: "data:image/png,%FF%00%01")!).data == Data([255, 0, 1]))
        #expect(try ImageDownload.inline(URL(string: "data:image/png;base64,%2Fw%0AAB#fragment")!).data == Data([255, 0, 1]))
        let svg = try ImageDownload.inline(URL(string: "data:image/svg+xml,%3Csvg%3E%2B%3C/svg%3E")!)
        #expect(svg.mime == "image/svg+xml" && svg.data == Data("<svg>+</svg>".utf8))
        let untypedSVG = try ImageDownload.inline(URL(string: "data:application/octet-stream,%3Csvg%20xmlns='http://www.w3.org/2000/svg'/%3E")!, inferImageType: true)
        #expect(untypedSVG.mime == "image/svg+xml")
    }

    @Test(arguments: ["data:text/html;base64,SGk=", "data:image/png;base64,%25%25%25", "data:image/png;base64,", "https://example.com/image.png"])
    func invalidInlineImagesFailInsteadOfSavingAnEmptyOrHTMLFile(text: String) {
        #expect(throws: (any Error).self) { try ImageDownload.inline(URL(string: text)!) }
    }
}
