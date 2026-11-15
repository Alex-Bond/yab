import AppKit
import Testing
import YabCoreClient
@testable import Fast

/// What a dragging pasteboard turns into for Chromium's Input.DragData.
@MainActor
struct ChromiumDragDataTests {
    private func strings(_ data: [String: JSONValue], _ key: String) -> [JSONValue] {
        if case .array(let list)? = data[key] { return list }
        return []
    }

    @Test func filesGoAsPathsWithNothingElse() throws {
        let board = NSPasteboard(name: .init("yab.test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        let file = URL(fileURLWithPath: "/tmp/one.txt")
        board.writeObjects([file as NSURL])
        let data = ChromiumPage.dragData(board, mask: [.copy, .move])
        #expect(strings(data, "files") == [.string("/tmp/one.txt")])
        #expect(strings(data, "items").isEmpty)
        #expect(data["dragOperationsMask"] == .number(17))
    }

    @Test func wordsAndLinksGoAsTheirKinds() throws {
        let board = NSPasteboard(name: .init("yab.test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.declareTypes([.string, .html], owner: nil)
        board.setString("some words", forType: .string)
        board.setString("<b>some words</b>", forType: .html)
        let data = ChromiumPage.dragData(board, mask: .copy)
        #expect(strings(data, "files").isEmpty)
        let items = strings(data, "items").compactMap(\.object)
        #expect(items.contains { $0["mimeType"] == .string("text/plain") && $0["data"] == .string("some words") })
        #expect(items.contains { $0["mimeType"] == .string("text/html") && $0["data"] == .string("<b>some words</b>") })
    }
}
