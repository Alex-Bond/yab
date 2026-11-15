import Foundation
import Testing
@testable import Fast

struct CodexProbeTests {
    private func workspace() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func account(_ folder: URL, name: String) throws -> URL {
        let source = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("fake-auth-\(name)".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("model = \"fake-model\"\n".utf8).write(to: source.appendingPathComponent("config.toml"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data("user-history".utf8).write(to: source.appendingPathComponent("sessions/user.jsonl"))
        try Data("user-index".utf8).write(to: source.appendingPathComponent("state_5.sqlite"))
        return source
    }

    @Test func separatesProbeHistoryAndCopiesConfig() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try account(folder, name: "user")
        let root = folder.appendingPathComponent("probe", isDirectory: true)
        let env = try CodexProbe.environment(base: ["KEEP": "yes", "CODEX_HOME": source.path], root: root, source: source)
        let home = CodexProbe.home(root: root, source: source)
        #expect(env["CODEX_HOME"] == home.path)
        #expect(env["KEEP"] == "yes")
        #expect(home != source)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent("auth.json").path) == source.appendingPathComponent("auth.json").path)
        for name in ["sessions", "archived_sessions"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(name).path) == root.appendingPathComponent(name).path)
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions/user.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("state_5.sqlite").path))
        let config = home.appendingPathComponent("config.toml")
        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: config) == Data(contentsOf: source.appendingPathComponent("config.toml")))
        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)
        for directory in [root, home, root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")] {
            #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        }
        try Data("probe-history".utf8).write(to: home.appendingPathComponent("sessions/probe.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("sessions/probe.jsonl").path))
        try Data("probe-config".utf8).write(to: config)
        #expect(try String(contentsOf: source.appendingPathComponent("config.toml"), encoding: .utf8) == "model = \"fake-model\"\n")
    }

    @Test func accountsShareOnlyProbeSessionsAndWorldsStaySeparate() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try account(folder, name: "first")
        let second = try account(folder, name: "second")
        let root = folder.appendingPathComponent("probe", isDirectory: true)
        let a = try CodexProbe.environment(base: [:], root: root, source: first)
        let b = try CodexProbe.environment(base: [:], root: root, source: second)
        let firstHome = CodexProbe.home(root: root, source: first)
        let secondHome = CodexProbe.home(root: root, source: second)
        #expect(a["CODEX_HOME"] != b["CODEX_HOME"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: firstHome.appendingPathComponent("auth.json").path) == first.appendingPathComponent("auth.json").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: secondHome.appendingPathComponent("auth.json").path) == second.appendingPathComponent("auth.json").path)
        try Data("probe-index".utf8).write(to: firstHome.appendingPathComponent("state_5.sqlite"))
        #expect(!FileManager.default.fileExists(atPath: secondHome.appendingPathComponent("state_5.sqlite").path))
        try Data("probe-history".utf8).write(to: firstHome.appendingPathComponent("sessions/probe.jsonl"))
        #expect(try String(contentsOf: secondHome.appendingPathComponent("sessions/probe.jsonl"), encoding: .utf8) == "probe-history")
        let again = try CodexProbe.environment(base: [:], root: root, source: first)
        #expect(again["CODEX_HOME"] == a["CODEX_HOME"])
        let otherWorld = folder.appendingPathComponent("other-probe", isDirectory: true)
        _ = try CodexProbe.environment(base: [:], root: otherWorld, source: first)
        #expect(!FileManager.default.fileExists(atPath: CodexProbe.home(root: otherWorld, source: first).appendingPathComponent("sessions/probe.jsonl").path))
    }

    @Test func refusesHistoryLinkOutsideProbeWorld() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try account(folder, name: "user")
        let root = folder.appendingPathComponent("probe", isDirectory: true)
        let home = CodexProbe.home(root: root, source: source)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("sessions"), withDestinationURL: source.appendingPathComponent("sessions"))
        #expect(throws: CodexProbe.SetupError.self) {
            try CodexProbe.environment(base: [:], root: root, source: source)
        }
        #expect(try String(contentsOf: source.appendingPathComponent("sessions/user.jsonl"), encoding: .utf8) == "user-history")
    }

    @Test func missingFileSignInNeverUsesTheOriginalHome() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("keyring-account", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = folder.appendingPathComponent("probe", isDirectory: true)
        #expect(throws: CodexProbe.SetupError.self) {
            try CodexProbe.environment(base: ["CODEX_HOME": source.path], root: root, source: source)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
