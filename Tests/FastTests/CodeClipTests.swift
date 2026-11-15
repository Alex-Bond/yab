import AppKit
import MailCore
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct CodeClipTests {
    @Test func onlyCodeCharactersAndPrivateTypes() {
        let board = NSPasteboard(name: .init("code-test-\(UUID())"))
        let clip = CodeClip(board: board)
        clip.put(MailCodeRead(code: "GQX41T", shown: "GQX-41T"), id: "one")
        #expect(board.string(forType: .string) == "GQX41T")
        #expect(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        #expect(board.types?.contains(.init("org.nspasteboard.TransientType")) == true)
        board.releaseGlobally()
    }

    @Test func expiryNeverErasesANewerCopy() {
        let now = Date(timeIntervalSince1970: 1000)
        let board = NSPasteboard(name: .init("code-test-\(UUID())"))
        let clip = CodeClip(board: board)
        let read = MailCodeRead(code: "481902", shown: "481 902")
        clip.put(read, id: "one", expires: now.addingTimeInterval(10), now: now)
        clip.tick(now: now.addingTimeInterval(9))
        #expect(board.string(forType: .string) == read.code)
        clip.tick(now: now.addingTimeInterval(10))
        #expect(board.string(forType: .string) == nil)
        clip.put(read, id: "two", expires: now.addingTimeInterval(10), now: now)
        board.clearContents(); board.setString("my next copy", forType: .string)
        clip.tick(now: now.addingTimeInterval(11))
        #expect(board.string(forType: .string) == "my next copy")
        board.releaseGlobally()
    }

    @Test func anAcceptedPasteConsumesOnlyTheOwnedCode() {
        let board = NSPasteboard(name: .init("code-test-\(UUID())"))
        let clip = CodeClip(board: board)
        clip.put(MailCodeRead(code: "481902", shown: "481 902"), id: "one")
        #expect(!clip.consumed("999999", site: "brex.com"))
        #expect(clip.consumed("481902", site: "brex.com"))
        #expect(board.string(forType: .string) == nil)
        #expect(!clip.consumed("481902", site: "brex.com"))
        board.releaseGlobally()
    }
    @Test func resendClearsTheOwnedCodeBeforeItsOriginalDeadline() {
        let board = NSPasteboard(name: .init("code-test-\(UUID())"))
        var valid = true
        let clip = CodeClip(board: board, canKeep: { _ in valid })
        let sent = SentCode(id: "old", code: "481902", from: "Brex", at: .now, source: .mail, mine: true)
        clip.put(MailCodeRead(code: sent.code, shown: "481 902"), id: sent.id, sent: sent)
        valid = false
        clip.tick()
        #expect(board.string(forType: .string) == nil)
        board.releaseGlobally()
    }

}
