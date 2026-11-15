import Foundation
import Testing
import YabStore

/// Calls the production helper only with files in a fresh temporary folder.
/// Store.folder, settings, AppKit and the user's profile are never accessed.
struct StoreQuarantineTests {
    private func inFolder(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func copies(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session.unreadable-") }
    }

    @Test func missingFileDoesNotCreateAnArchive() throws {
        try inFolder { root in
            Store.quarantine(root.appendingPathComponent("session.json"))
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(files.isEmpty)
        }
    }

    @Test func unreadableBytesSurviveTheNextNormalSave() throws {
        try inFolder { root in
            let file = root.appendingPathComponent("session.json")
            let sibling = root.appendingPathComponent("bookmarks.json")
            let previous = root.appendingPathComponent("session.unreadable-0.json")
            let damaged = Data([0x7B, 0x00, 0xFF, 0x0A])
            let older = Data("older unreadable version".utf8)
            let bookmark = Data("keep sibling bytes".utf8)
            try damaged.write(to: file)
            try older.write(to: previous)
            try bookmark.write(to: sibling)

            Store.quarantine(file)

            #expect(!FileManager.default.fileExists(atPath: file.path))
            let archives = try copies(in: root)
            #expect(archives.count == 2)
            #expect(try Data(contentsOf: previous) == older)
            // Enumeration URLs can carry a different base/directory hint.
            // These entries share a folder; identify the older file by name.
            let saved = try #require(archives.first { $0.lastPathComponent != previous.lastPathComponent })
            #expect(saved.lastPathComponent != previous.lastPathComponent)
            #expect(try Data(contentsOf: saved) == damaged)
            try Data("{\"tabs\":[]}".utf8).write(to: file, options: .atomic)
            #expect(try Data(contentsOf: saved) == damaged)
            #expect(try Data(contentsOf: previous) == older)
            #expect(try Data(contentsOf: sibling) == bookmark)
        }
    }

    @Test func everyUnreadableVersionOfTheSameFileIsRetained() throws {
        try inFolder { root in
            let file = root.appendingPathComponent("session.json")
            let versions = (0..<32).map { Data("malformed version \($0)".utf8) }
            for bytes in versions {
                try bytes.write(to: file)
                Store.quarantine(file)
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }

            let archives = try copies(in: root)
            #expect(archives.count == versions.count)
            let actual = try Set(archives.map { try Data(contentsOf: $0) })
            #expect(actual == Set(versions))
        }
    }

    @Test func filesWithTheSameStemKeepIndependentCopies() throws {
        try inFolder { root in
            let first = root.appendingPathComponent("session.json")
            let second = root.appendingPathComponent("session.backup")
            let bytes = [Data("first malformed file".utf8), Data("second malformed file".utf8)]
            try bytes[0].write(to: first)
            try bytes[1].write(to: second)

            Store.quarantine(first)
            Store.quarantine(second)

            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: second.path))
            let archives = try copies(in: root)
            #expect(archives.count == 2)
            #expect(try Set(archives.map { try Data(contentsOf: $0) }) == Set(bytes))
        }
    }
}
