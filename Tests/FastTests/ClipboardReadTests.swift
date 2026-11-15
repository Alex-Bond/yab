import AppKit
import Testing
@testable import Fast

@MainActor
struct ClipboardReadTests {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("clipboard-read-\(UUID())"))
        board.clearContents()
        board.setString("first copy", forType: .string)
        return board
    }

    @Test func anUnchangedExternalCopyIsAccepted() {
        let board = board()
        defer { board.releaseGlobally() }
        let change = Clips.Change(count: board.changeCount, own: false)
        #expect(board.string(forType: .string) == "first copy")
        #expect(change.matches(board.changeCount, own: false))
    }

    @Test func aLaterCopyRejectsTheEarlierRead() {
        let board = board()
        defer { board.releaseGlobally() }
        let change = Clips.Change(count: board.changeCount, own: false)
        let fetched = board.string(forType: .string)
        // The earlier read completes after another app copies again.
        board.clearContents()
        board.setString("second copy", forType: .string)
        #expect(fetched == "first copy")
        #expect(!change.matches(board.changeCount, own: false))
        let next = Clips.Change(count: board.changeCount, own: false)
        #expect(next.matches(board.changeCount, own: false))
        #expect(board.string(forType: .string) == "second copy")
    }

    @Test func aPageCopyRejectsTheEarlierExternalRead() {
        let board = board()
        defer { board.releaseGlobally() }
        let change = Clips.Change(count: board.changeCount, own: false)
        board.clearContents()
        board.setString("page copy", forType: .string)
        #expect(!change.matches(board.changeCount, own: true))
    }

    @Test func ownershipMustStillMatchEvenWithTheSameCount() {
        let board = board()
        defer { board.releaseGlobally() }
        let external = Clips.Change(count: board.changeCount, own: false)
        #expect(!external.matches(board.changeCount, own: true))
        let page = Clips.Change(count: board.changeCount, own: true)
        #expect(page.matches(board.changeCount, own: true))
        #expect(!page.matches(board.changeCount, own: false))
    }
}
