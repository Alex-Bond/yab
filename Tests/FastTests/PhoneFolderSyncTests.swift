import Foundation
import Testing
import SyncKit
@testable import Fast

@MainActor
struct PhoneFolderSyncTests {
    @Test func phoneNamesAndNestedFolderDeletionRoundTripThroughMacRows() throws {
        SyncShapes.register()
        let sid = UUID(), parent = UUID().uuidString, child = UUID().uuidString, tid = UUID().uuidString
        let journal = try Journal(path: nil, device: "phone")
        let folders = [SyncFolder(id: parent, space: sid.uuidString, order: "A", name: "Research"),
                       SyncFolder(id: child, space: sid.uuidString, order: "B", name: "Sources", folder: parent)]
        for folder in folders { try journal.change(.init(collection: "folder", id: folder.id), folder.fields) }
        let tab = SyncTab(id: tid, space: sid.uuidString, order: "B", url: "https://example.com/", title: "Page title",
                          name: "My reference", kept: true, folder: child)
        try journal.change(.init(collection: "tab", id: tid), tab.fields)
        func read(_ here: Session.Shape = Session.Shape(tabs: [], active: 0)) -> Session.Shape {
            SyncShapes.row(sid, tabs: journal.all("tab"), folders: journal.all("folder"), pairs: [], here: here)
        }
        let row = read()
        #expect(row.tabs.count == 1)
        #expect(row.tabs.first?.name == "My reference" && row.tabs.first?.title == "Page title")
        #expect(row.tabs.first?.folderPath?.map(\.id) == [parent])
        let echoed = SyncShapes.rows([sid: row], orders: [:])
        #expect(echoed.folders[child]?["folder"]?.string == parent)
        #expect(echoed.tabs[tid]?["name"]?.string == "My reference")
        try journal.change(.init(collection: "tab", id: tid), ["name": .null])
        try journal.change(.init(collection: "folder", id: child), ["parent": .string(sid.uuidString), "order": "B", "folder": .null])
        try journal.remove(.init(collection: "folder", id: parent))
        let promoted = read(row)
        #expect(promoted.tabs.first?.folder == child && promoted.tabs.first?.folderPath == nil)
        #expect(promoted.tabs.first?.name == nil && promoted.tabs.first?.title == "Page title")
        try journal.change(.init(collection: "tab", id: tid), ["folder": .null])
        try journal.remove(.init(collection: "folder", id: child))
        let dissolved = read(promoted)
        #expect(dissolved.tabs.count == 1 && dissolved.tabs.first?.folder == nil)
    }
}
