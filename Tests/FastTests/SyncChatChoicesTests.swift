import Foundation
import SyncKit
import Testing
@testable import Fast

/// What a chat's agent waits for you to pick from goes to the iPhone in its
/// head while it runs, and is cleared once picked; a chat done is written
/// as before.
struct SyncChatChoicesTests {
    @Test func choicesGoWhileItRunsAndClearOncePicked() throws {
        var head = SyncChat(id: "a:q", device: "mac", title: "Q", state: "running", answer: "", cli: "codex", started: 1, updated: 2)
        head.choices = ["New scenes 2026", "Blu-ray"]
        #expect(head.fields["choices"] == .array(["New scenes 2026", "Blu-ray"]))
        let read = try #require(SyncChat(Record(collection: "chat", id: "a:q", fields: head.fields)))
        #expect(read.choices == ["New scenes 2026", "Blu-ray"])
        head.state = "waiting"
        #expect(head.fields["choices"] == .array(["New scenes 2026", "Blu-ray"]))
        head.choices = []
        #expect(head.fields["choices"] == .null)
        head.state = "done"
        #expect(head.fields["choices"] == nil)
    }
}
