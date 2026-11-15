import Foundation
import Testing
@testable import Fast

/// A file that can't go with the words is said by name before sending, and
/// a failed turn names the one its error is about (ChatAttachment.trouble).
struct ChatAttachmentTroubleTests {
    private func file(_ name: String, bytes: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-trouble-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test func readableFileHasNoTrouble() throws {
        let url = try file("notes.txt", bytes: 10)
        #expect(ChatAttachment.file(url).trouble() == nil)
    }

    @Test func goneFileIsSaidByName() throws {
        let url = try file("report.pdf", bytes: 10)
        try FileManager.default.removeItem(at: url)
        #expect(ChatAttachment.file(url).trouble() == "\u{201C}report.pdf\u{201D} was moved or deleted.")
    }

    @Test func fileOverTheLimitIsSaidByName() throws {
        let url = try file("movie.mov", bytes: ChatAttachment.most + 1)
        #expect(ChatAttachment.file(url).trouble() == "\u{201C}movie.mov\u{201D} is over 20 MB.")
    }

    @Test func tabsAndQuotesNeverBlockSending() {
        #expect(ChatAttachment.tab(UUID()).trouble() == nil)
        #expect(ChatAttachment.quote("words").trouble() == nil)
    }

    @Test func errorNamingAFileBlamesIt() throws {
        let a = ChatAttachment.file(try file("a.png", bytes: 10))
        let b = ChatAttachment.file(try file("b.pdf", bytes: 10))
        #expect(ChatAttachment.blamed("Error reading b.pdf: permission denied", among: [a, b]) == b)
    }

    @Test func imageErrorBlamesTheOnlyPicture() throws {
        let picture = ChatAttachment.file(try file("shot.png", bytes: 10))
        let doc = ChatAttachment.file(try file("doc.pdf", bytes: 10))
        let raw = #"API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"Could not process image"}}"#
        #expect(ChatAttachment.blamed(raw, among: [doc, picture]) == picture)
        #expect(ChatAttachment.blamed("overloaded", among: [doc, picture]) == nil)
    }
}
