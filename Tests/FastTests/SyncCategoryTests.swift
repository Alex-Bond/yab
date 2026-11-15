import Foundation
import Testing
@testable import SyncKit
@testable import Fast

struct SyncCategoryTests {
    init() { SyncCollection.register() }

    private func client(_ server: MemoryServer, _ seal: Seal, _ device: String) throws -> SyncClient {
        SyncClient(base: URL(string: "https://sync.test")!, journal: try Journal(path: nil, device: device),
                   seal: seal, device: .init(id: device, name: device, model: "test"), transport: server)
    }

    private func until(_ client: SyncClient, _ done: @escaping () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if client.queue.sync(execute: done) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test func categoriesIncludeTheirDependentRecordsAndStayDeviceLocal() {
        #expect(SyncCategory.tabs.collections == ["tab", "folder", "pair"])
        #expect(SyncCategory.files.collections == ["file", "icon", "answer"])
        #expect(SyncCategory.chats.collections == ["chat", "chatitem", "project"])
        #expect(!SyncShapes.syncs(SyncCategory.preferenceKey))
        #expect(!SyncShapes.syncs(SyncCategory.replayKey))
        #expect(SyncCategory.excluded(by: []).isEmpty)
        #expect(SyncCategory.excluded(by: [.tabs, .bookmarks]) == ["tab", "folder", "pair", "bookmark"])
    }

    @Test func aDisabledBacklogDoesNotStarveOtherCategoriesOrLosePendingChanges() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        defer { a.stop(); b.stop() }
        for n in 0..<250 {
            try a.journal.change(.init(collection: "bookmark", id: "\(n)"), ["title": "Private"])
        }
        let other = Record.Key(collection: "setting", id: "theme")
        try a.journal.change(other, ["value": "dark"])
        a.setExcludedCollections(["bookmark"])
        a.start(); b.start()
        #expect(await until(b) { b.journal.record(other)?["value"] == "dark" })
        #expect(await until(a) { a.journal.pending(excluding: ["bookmark"]).isEmpty })
        #expect(a.journal.pending().count == 250)
        #expect(b.journal.all("bookmark").isEmpty)
        a.setExcludedCollections([])
        #expect(await until(b) { b.journal.all("bookmark").count == 250 })
        #expect(await until(a) { a.journal.pending().isEmpty })
    }

    @Test func reenableReplaysRecordsMissedBeforeAnAdvancedCursorAndMergesLocalEdits() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        defer { a.stop(); b.stop() }
        let key = Record.Key(collection: "bookmark", id: "page")
        try a.journal.change(key, ["title": "Before", "url": "https://before.test"])
        a.start(); b.start()
        #expect(await until(b) { b.journal.record(key)?["title"] == "Before" })
        b.setExcludedCollections(["bookmark"])
        b.queue.sync {}
        let cursor = b.journal.cursor
        try a.journal.change(key, ["title": "Remote title"])
        try a.journal.change(.init(collection: "setting", id: "barrier"), ["value": true])
        a.kick()
        #expect(await until(b) { b.journal.record(.init(collection: "setting", id: "barrier")) != nil && b.journal.cursor > cursor })
        #expect(b.journal.record(key)?["title"] == "Before")
        // This is the app's flush on reenable, before starting catch-up.
        try b.journal.change(key, ["url": "https://local.test"])
        b.setExcludedCollections([])
        #expect(await until(b) { b.journal.record(key)?["title"] == "Remote title" && b.journal.record(key)?["url"] == "https://local.test" })
        #expect(await until(a) { a.journal.record(key)?["url"] == "https://local.test" })
    }

    @Test func remoteDeletionIsDeferredAndReplayedWithoutDeletingLocalDataOnDisable() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        defer { a.stop(); b.stop() }
        let key = Record.Key(collection: "bookmark", id: "deleted")
        try a.journal.change(key, ["title": "Keep while off"])
        a.start(); b.start()
        #expect(await until(b) { b.journal.record(key)?.alive() == true })
        b.setExcludedCollections(["bookmark"])
        b.queue.sync {}
        try a.journal.remove(key)
        try a.journal.change(.init(collection: "setting", id: "barrier"), ["value": true])
        a.kick()
        #expect(await until(b) { b.journal.record(.init(collection: "setting", id: "barrier")) != nil })
        #expect(b.journal.record(key)?.alive() == true)
        b.setExcludedCollections([])
        #expect(await until(b) { b.journal.record(key)?.alive() == false })
    }

    @Test func disabledIncomingRecordsNeverReachTheAppDeliveryCallback() async throws {
        let server = MemoryServer(), seal = Seal.make()
        let a = try client(server, seal, "a"), b = try client(server, seal, "b")
        defer { a.stop(); b.stop() }
        b.setExcludedCollections(SyncCategory.tabs.collections)
        b.deliver = { items in
            #expect(items.allSatisfy { !SyncCategory.tabs.collections.contains($0.record.collection) })
            _ = try? b.journal.receive(items)
        }
        for collection in ["tab", "folder", "pair", "setting"] {
            try a.journal.change(.init(collection: collection, id: "record"), ["value": true])
        }
        a.start(); b.start()
        #expect(await until(b) { b.journal.record(.init(collection: "setting", id: "record")) != nil })
        #expect(b.journal.all("tab").isEmpty && b.journal.all("folder").isEmpty && b.journal.all("pair").isEmpty)
    }
}
