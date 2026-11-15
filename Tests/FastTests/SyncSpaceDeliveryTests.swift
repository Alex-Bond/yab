import Foundation
import Testing
import SyncKit
@testable import Fast

/// Catch-up is paged by record sequence, not by space: tabs and their
/// folders can arrive before the space they belong to (a renamed space
/// has a newer sequence). Exercise the real journal-to-session delivery.
@MainActor
@Suite(.serialized)
struct SyncSpaceDeliveryTests {
    init() { SyncShapes.register() }

    private func lateSpace(joining: Bool) throws {
        #expect(Store.testing)
        let original = Spaces.read()
        let space = Space(id: UUID(), name: "Other Mac", icon: "M", ownSignIns: false)
        defer {
            Spaces.write(original)
            try? FileManager.default.removeItem(at: Store.file("session-\(space.id.uuidString).json"))
        }
        let a = try Journal(path: nil, device: "mac-a")
        let b = try Journal(path: nil, device: "mac-b")
        let center = SyncCenter()
        let one = UUID().uuidString, two = UUID().uuidString, folder = UUID().uuidString
        let row = Session.Shape(tabs: [
            .init(url: "https://delivery.test/one", title: "One", kept: true,
                  folder: folder, folderName: "Reading", id: one),
            .init(url: "https://delivery.test/two", title: "Two", kept: true,
                  folder: folder, folderName: "Reading", id: two),
        ], active: 0, pairs: [.init(first: 0, second: 1, share: 0.4)])
        let out = SyncShapes.rows([space.id: row], orders: [:], device: "mac-a")
        try a.reconcile(SyncShapes.tab, out.tabs)
        try a.reconcile(SyncShapes.folder, out.folders)
        try a.reconcile(SyncShapes.pair, out.pairs)
        try a.reconcile(SyncShapes.space, SyncShapes.spaces(original + [space], orders: [:]))

        // Existing local spaces are known, but the remote space is not.
        let known = a.living(SyncShapes.space).filter { $0.id != space.id.uuidString }
        _ = try b.receive(known.map { ($0, 1) })
        let local = Dictionary(uniqueKeysWithValues: original.map { ($0.id, Session.Shape(tabs: [], active: 0)) })
        let first = [SyncShapes.tab, SyncShapes.folder, SyncShapes.pair].flatMap { a.all($0) }
        let changed = try SyncCenter.receive(first.map { ($0, 2) }, into: b, localRows: joining ? nil : local, device: "mac-b")
        center.adopt(changed, from: b)
        #expect(!Spaces.read().contains { $0.id == space.id })

        // The next page contains only the space, no repeated tab records.
        let last = a.living(SyncShapes.space).filter { $0.id == space.id.uuidString }
        let parent = try SyncCenter.receive(last.map { ($0, 3) }, into: b, localRows: joining ? nil : local, device: "mac-b")
        center.adopt(parent, from: b)
        #expect(Spaces.read().contains { $0.id == space.id })
        let shown = Session.read(space: space.id)
        #expect(shown.tabs.compactMap(\.id) == [one, two])
        #expect(shown.tabs.compactMap(\.folder) == [folder, folder])
        #expect(shown.pairs?.first?.share == 0.4)
        for record in first {
            #expect(b.record(record.key)?.alive() == true)
        }
        // A subsequent save must not send deletions back to the first Mac.
        _ = try SyncCenter.receive([], into: b, localRows: local.merging([space.id: shown]) { _, incoming in incoming }, device: "mac-b")
        _ = try a.receive(b.pending().map { ($0.record, 4) })
        #expect(a.living(SyncShapes.tab).count == 2)
        #expect(a.living(SyncShapes.folder).count == 1)
        #expect(a.living(SyncShapes.pair).count == 1)
    }

    @Test func joiningShowsTabsDeliveredBeforeTheirSpace() throws {
        try lateSpace(joining: true)
    }

    @Test func reconnectingDoesNotDeleteTabsWhoseSpaceHasNotArrivedYet() throws {
        try lateSpace(joining: false)
    }

    @Test func aDeletedSpaceStillRemovesItsTabsFoldersAndPairs() throws {
        let space = UUID()
        let a = try Journal(path: nil, device: "mac-a")
        let b = try Journal(path: nil, device: "mac-b")
        let parent = Record.Key(collection: SyncShapes.space, id: space.uuidString)
        let row = Session.Shape(tabs: [
            .init(url: "https://delivery.test/one", title: "One", kept: true,
                  folder: "folder", folderName: "Reading", id: "one"),
            .init(url: "https://delivery.test/two", title: "Two", kept: true,
                  folder: "folder", folderName: "Reading", id: "two"),
        ], active: 0, pairs: [.init(first: 0, second: 1, share: 0.5)])
        let out = SyncShapes.rows([space: row], orders: [:])
        try a.reconcile(SyncShapes.tab, out.tabs)
        try a.reconcile(SyncShapes.folder, out.folders)
        try a.reconcile(SyncShapes.pair, out.pairs)
        _ = try b.receive([SyncShapes.tab, SyncShapes.folder, SyncShapes.pair].flatMap { a.all($0) }.map { ($0, 1) })
        _ = try SyncCenter.receive([], into: b, localRows: [:], device: "mac-b")
        #expect(b.living(SyncShapes.tab).count == 2)
        try a.change(parent, SyncSpace(id: space.uuidString, name: "Gone", icon: "M", ownSignIns: false).fields)
        try a.remove(parent)
        _ = try b.receive([(try #require(a.record(parent)), 2)])
        _ = try SyncCenter.receive([], into: b, localRows: [:], device: "mac-b")
        #expect(b.living(SyncShapes.tab).isEmpty)
        #expect(b.living(SyncShapes.folder).isEmpty)
        #expect(b.living(SyncShapes.pair).isEmpty)
    }
}
