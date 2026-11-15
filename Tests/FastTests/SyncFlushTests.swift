import Foundation
import Testing
import SyncKit
@testable import Fast

/// A flush's journal work off the main thread (SyncCenter.flush,
/// docs/main-thread-budget.md): what the main thread read is told to the
/// journal the same as when it was done there, a move keeps every other
/// order, the chats failing stops what comes after them, and flushes on
/// their queue never interleave.
struct SyncFlushTests {
    init() { SyncShapes.register() }

    private let spaces = [
        Space(id: Space.firstID, name: "Home", icon: "🏠", ownSignIns: false),
        Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: true, origin: "Arc:1"),
    ]

    @Test func spacesAndBookmarksReadOnTheMainThreadReachTheJournal() throws {
        let journal = try Journal(path: nil, device: "a")
        var read = SyncCenter.Flush(collections: [SyncShapes.space, SyncShapes.bookmark])
        read.spaces = spaces
        read.bookmarks = [.site("A", URL(string: "https://a.test")!, added: nil)]
        try SyncCenter.tell(read, into: journal)
        #expect(SyncShapes.spaces(from: journal.all(SyncShapes.space)) == spaces)
        #expect(SyncShapes.bookmarks(from: journal.all(SyncShapes.bookmark)).map(\.title) == ["A"])
        #expect(!journal.pending().isEmpty)
    }

    @Test func aSecondFlushKeepsTheOrdersItFound() throws {
        let journal = try Journal(path: nil, device: "a")
        var read = SyncCenter.Flush(collections: [SyncShapes.space])
        read.spaces = spaces
        try SyncCenter.tell(read, into: journal)
        let first = Dictionary(uniqueKeysWithValues: journal.all(SyncShapes.space).map { ($0.id, $0["order"]?.string) })
        try SyncCenter.tell(read, into: journal)
        let second = Dictionary(uniqueKeysWithValues: journal.all(SyncShapes.space).map { ($0.id, $0["order"]?.string) })
        #expect(first == second)
    }

    @Test func chatsFailingStopWhatComesAfterThem() throws {
        struct Broke: Error {}
        let journal = try Journal(path: nil, device: "a")
        var read = SyncCenter.Flush(collections: [SyncShapes.space, SyncShapes.answer])
        read.spaces = spaces
        read.failed = Broke()
        try SyncCenter.tell(read, into: journal)
        // What came before the chats is told; the answers after them are not.
        #expect(journal.all(SyncShapes.space).count == 2)
        #expect(journal.all(SyncShapes.answer).isEmpty)
    }

    @Test func aDeliveryFetchesOnlyWhatItsRecordsTouch() throws {
        let journal = try Journal(path: nil, device: "a")
        let space = UUID().uuidString
        try journal.reconcile(SyncShapes.tab, ["t1": ["parent": .string(space), "order": "1", "url": "https://fetch.test/1", "title": "1"]])
        var read = SyncCenter.Flush(collections: [SyncShapes.space])
        read.spaces = spaces
        try SyncCenter.tell(read, into: journal)
        let tabs = SyncCenter.fetch(for: journal.all(SyncShapes.tab), from: journal)
        #expect(tabs.tabs?.map(\.id) == ["t1"])
        #expect(tabs.folders != nil && tabs.pairs != nil)
        #expect(tabs.spaces == nil && tabs.bookmarks == nil)
        let both = SyncCenter.fetch(for: journal.all(SyncShapes.space), from: journal)
        #expect(both.spaces?.count == 2)
        // A space can arrive after its tabs in a later catch-up page.
        #expect(both.tabs?.map(\.id) == ["t1"])
        #expect(both.folders != nil && both.pairs != nil)
    }

    @Test func flushesOnOneQueueTellTheJournalInTurn() async throws {
        let journal = try Journal(path: nil, device: "a")
        let queue = DispatchQueue(label: "test.sync.flush")
        // Each flush names the spaces it read; the last one asked wins.
        for n in 0..<30 {
            var read = SyncCenter.Flush(collections: [SyncShapes.space])
            read.spaces = [Space(id: Space.firstID, name: "Home \(n)", icon: "🏠", ownSignIns: false)]
            let frozen = read
            queue.async { try? SyncCenter.tell(frozen, into: journal) }
        }
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(SyncShapes.spaces(from: journal.living(SyncShapes.space)).map(\.name) == ["Home 29"])
    }
}
