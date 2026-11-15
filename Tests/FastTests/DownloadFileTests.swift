import Foundation
import Testing
@testable import Fast

struct DownloadFileTests {
    @Test func cancelledStagingCannotBePublishedByALateEngineCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-late-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("file.bin")
        let file = try DownloadFile(destination: target, root: root.appendingPathComponent("parts"))
        file.discard()
        // A late writer recreates its old path. Its completion token is
        // still cancelled and cannot publish that file into Downloads.
        try FileManager.default.createDirectory(at: file.staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("late".utf8).write(to: file.staging)
        #expect(throws: (any Error).self) { try file.publish() }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
    @Test func assembledMediaUsesTheSameExclusivePublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-publish-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("owned-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = workspace.appendingPathComponent("assembled.mp4"), target = root.appendingPathComponent("video.mp4")
        try Data("assembled bytes".utf8).write(to: source)
        #expect(try DownloadFile(destination: target, ownedStaging: source).publish() == target)
        #expect(try Data(contentsOf: target) == Data("assembled bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }
    @Test func completedBytesAppearOnlyAfterPublishAndDiscardCannotTouchTheDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("photo.png")
        let file = try DownloadFile(destination: target, root: root.appendingPathComponent("parts"))
        try Data([1, 2, 3]).write(to: file.staging)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try file.publish() == target)
        file.discard()
        #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    }

    @Test func collisionNeverOverwritesOrDeletesAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-collision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("photo.png")
        let file = try DownloadFile(destination: target, root: root.appendingPathComponent("parts"))
        try Data("new".utf8).write(to: file.staging)
        try Data("mine".utf8).write(to: target)
        #expect(throws: (any Error).self) { try file.publish() }
        file.discard()
        #expect(try Data(contentsOf: target) == Data("mine".utf8))
    }

    @Test @MainActor func simultaneousWindowsCannotReserveTheSameNonexistentFilename() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = UUID(), second = UUID()
        defer { DownloadDestinations.release(first); DownloadDestinations.release(second) }
        #expect(DownloadDestinations.reserve("file.bin", in: root, for: first) == root.appendingPathComponent("file.bin"))
        #expect(DownloadDestinations.reserve("file.bin", in: root, for: second) == root.appendingPathComponent("file 2.bin"))
    }
}
