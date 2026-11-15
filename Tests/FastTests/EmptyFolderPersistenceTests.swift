import Foundation
import Testing
@testable import Fast

@MainActor
struct EmptyFolderPersistenceTests {
    @Test func customIconsSurviveSavingAnotherSpaceAndRelaunching() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = UUID(), second = UUID()
        let folder = Nest(name: "Work", open: true)
        folder.customMark = "image:work.png"
        let folders = Folders(emptiesFile: file)
        folders.keepEmpty(folder, space: first)

        // A new owner loads the saved spaces before writing another one.
        let relaunched = Folders(emptiesFile: file)
        let other = Nest(name: "Reading", open: false)
        other.customMark = "book"
        relaunched.keepEmpty(other, space: second)
        let restored = Folders.readEmpties(from: file)
        let work = try #require(restored[first]?.first)
        #expect(work.id == folder.id && work.name == "Work" && work.open)
        #expect(work.customMark == "image:work.png")
        #expect(restored[second]?.first?.customMark == "book")
        #expect(restored[second]?.first?.open == false)
    }

    @Test func foldersSavedBeforeCustomIconsStillLoad() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let space = UUID(), folder = UUID()
        let data = try JSONSerialization.data(withJSONObject: [space.uuidString: [
            ["id": folder.uuidString, "name": "Older folder", "open": true]
        ]])
        try data.write(to: file)
        let restored = try #require(Folders.readEmpties(from: file)[space]?.first)
        #expect(restored.id == folder && restored.name == "Older folder" && restored.open)
        #expect(restored.customMark == nil)
    }
}
