import Foundation
import Testing
@testable import Fast

@MainActor
struct AgentWorkingFolderTests {
    @Test func codexChatsShareOneProject() {
        let first = Agents.workingFolder(cli: "codex", id: "4317e2", full: false, folder: nil)
        let second = Agents.workingFolder(cli: "codex", id: "6bb2de", full: false, folder: nil)
        #expect(first == second)
        #expect(first == Store.file("agent/Yab"))
        #expect(Agents.workingFolder(cli: "codex", id: "e4d473", full: true, folder: nil) == first)
    }

    @Test func explicitFolderNeedsFullAccess() {
        let folder = FileManager.default.temporaryDirectory
        #expect(Agents.workingFolder(cli: "codex", id: "first", full: true, folder: folder.path).path == folder.path)
        #expect(Agents.workingFolder(cli: "codex", id: "second", full: false, folder: folder.path) == Store.file("agent/Yab"))
    }

    @Test func invalidFolderFallsBackToSharedProject() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(Agents.workingFolder(cli: "codex", id: "first", full: true, folder: file.path) == Store.file("agent/Yab"))
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Agents.workingFolder(cli: "codex", id: "second", full: true, folder: file.path) == Store.file("agent/Yab"))
    }

    @Test func claudeKeepsItsResumeFolder() {
        #expect(Agents.workingFolder(cli: "claude", id: "4317e2", full: false, folder: nil) == Store.file("agent/4317e2"))
        let folder = FileManager.default.temporaryDirectory
        #expect(Agents.workingFolder(cli: "claude", id: "4317e2", full: true, folder: folder.path).path == folder.path)
    }
}
