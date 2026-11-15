import Foundation
import Testing
@testable import Fast

struct SpaceRecoveryTests {
    private func profile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("space-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func row(_ id: UUID, in folder: URL) throws {
        let name = id == Space.firstID ? "session.json" : "session-\(id.uuidString).json"
        try JSONEncoder().encode(Session.Shape(tabs: [.init(url: "https://saved.test/", title: "Saved")], active: 0))
            .write(to: folder.appendingPathComponent(name))
    }

    @Test func oneMalformedLookDoesNotHideTwelveSpaces() throws {
        try profile { folder in
            let spaces = (0..<12).map { Space(id: $0 == 0 ? Space.firstID : UUID(), name: "Space \($0)", icon: "folder", ownSignIns: $0 % 2 == 0) }
            var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spaces)) as! [[String: Any]]
            raw[7]["paint"] = ["grain": "not a boolean"]
            let damaged = try JSONSerialization.data(withJSONObject: raw)
            let file = folder.appendingPathComponent("spaces.json")
            try damaged.write(to: file)
            let restored = SpaceRecovery.read(at: file)
            #expect(restored == spaces)
            #expect(try JSONDecoder().decode([Space].self, from: Data(contentsOf: file)) == spaces)
            let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("spaces.unreadable-") }
            #expect(backups.count == 1)
            #expect(try Data(contentsOf: #require(backups.first)) == damaged)
        }
    }

    @Test func truncatedIndexRecoversHealthyRowsWithoutBorrowingSignIns() throws {
        try profile { folder in
            let id = UUID(), deleted = UUID(), virtual = UUID()
            for key in [Space.firstID, id, deleted, virtual] { try row(key, in: folder) }
            try Data("{broken".utf8).write(to: folder.appendingPathComponent("spaces.json"))
            try Data("not a session".utf8).write(to: folder.appendingPathComponent("session-\(UUID()).json"))
            let window = folder.appendingPathComponent("session-window-\(UUID()).json")
            try JSONEncoder().encode(Session.Shape(tabs: [.init(url: "https://window.test/", title: "Window")], active: 0)).write(to: window)
            let empty = folder.appendingPathComponent("session-\(UUID()).json")
            try JSONEncoder().encode(Session.Shape(tabs: [], active: 0)).write(to: empty)
            let restored = try #require(SpaceRecovery.read(at: folder.appendingPathComponent("spaces.json"), excluding: [deleted, virtual]))
            #expect(Set(restored.map(\.id)) == [Space.firstID, id])
            #expect(restored.first { $0.id == id }?.ownSignIns == true)
            #expect(restored.first { $0.id == Space.firstID }?.ownSignIns == false)
            // Personal keeps the icon a new Mac gives it, the others a folder's.
            #expect(restored.first { $0.id == Space.firstID }?.icon == "🏠")
            #expect(restored.first { $0.id == id }?.icon == "📁")
        }
    }

    @Test func aValidListDoesNotResurrectOrphanedOrDeletedSpaces() throws {
        try profile { folder in
            let kept = Space(id: Space.firstID, name: "Personal", icon: "folder", ownSignIns: false)
            let file = folder.appendingPathComponent("spaces.json")
            try JSONEncoder().encode([kept]).write(to: file)
            try row(UUID(), in: folder)
            #expect(SpaceRecovery.read(at: file) == [kept])
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
        }
    }

    @Test func anIntentionallyEmptyListStaysEmpty() throws {
        try profile { folder in
            let file = folder.appendingPathComponent("spaces.json")
            try Data("[]".utf8).write(to: file)
            try row(UUID(), in: folder)
            #expect(SpaceRecovery.read(at: file) == [])
        }
    }

    @Test func anUnrecoverableIndexIsKeptByteForByte() throws {
        try profile { folder in
            let damaged = Data("[truncated".utf8)
            let file = folder.appendingPathComponent("spaces.json")
            try damaged.write(to: file)
            #expect(SpaceRecovery.read(at: file) == nil)
            let backup = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("spaces.unreadable-") })
            #expect(try Data(contentsOf: backup) == damaged)
            #expect(try Data(contentsOf: file) == damaged)
        }
    }

    @Test func aMissingIndexRecoversRowsAndAnEmptyProfileStaysEmpty() throws {
        try profile { folder in
            let file = folder.appendingPathComponent("spaces.json")
            #expect(SpaceRecovery.read(at: file) == nil)
            let id = UUID()
            try row(id, in: folder)
            #expect(SpaceRecovery.read(at: file)?.map(\.id) == [id])
        }
    }
}
