import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor
struct ChromiumDragPasteboardTests {
    @Test func customAndEmptyDragsHaveANativeWriterAndDropType() {
        let custom: [String: JSONValue] = ["items": .array([.object([
            "mimeType": .string("application/x-jira-issue"), "data": .string("JIRA-1669")])])]
        for data in [custom, ["items": .array([])], [:]] {
            let writer = ChromiumPage.draggingPasteboard(data)
            #expect(writer.types.contains(ChromiumPage.pageDragType))
            #expect(ChromiumPage.draggedTypes.contains(ChromiumPage.pageDragType))
            #expect(writer.string(forType: .string) == nil)
            #expect(writer.string(forType: .URL) == nil)
        }
    }
    @Test func standardFormatsRemainAvailableToNativeDestinations() {
        let data: [String: JSONValue] = ["items": .array([
            .object(["mimeType": .string("text/plain"), "data": .string("Ticket")]),
            .object(["mimeType": .string("text/html"), "data": .string("<b>Ticket</b>")]),
            .object(["mimeType": .string("text/uri-list"), "data": .string("#comment\r\nhttps://example.com/ticket\r\n")])])]
        let writer = ChromiumPage.draggingPasteboard(data)
        #expect(writer.string(forType: .string) == "Ticket")
        #expect(writer.string(forType: .html) == "<b>Ticket</b>")
        #expect(writer.string(forType: .URL) == "https://example.com/ticket")
    }
}
