import Foundation
import Testing
@testable import Fast

// A conversation carried between two accounts' folders, laid out as Claude
// Code 2.1.287 and Codex 0.157.0 lay them out.
struct AgentCarryTests {
    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-carry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @Test func claudesSlugIsTheRealPathWithEveryOtherCharacterADash() {
        #expect(AgentCarry.slug("/Users/me/Documents/GitHub/fast") == "-Users-me-Documents-GitHub-fast")
        #expect(AgentCarry.slug("/Users/me/my.app_x") == "-Users-me-my-app-x")
    }

    @Test func linkedFoldersShareTheTranscript() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let usual = root.appendingPathComponent("usual"), extra = root.appendingPathComponent("extra")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = AgentCarry.claudeFile(home: usual, folder: work.path, session: "s1")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: extra.appendingPathComponent("projects"), withDestinationURL: usual.appendingPathComponent("projects"))
        #expect(AgentCarry.ensure(cli: "claude", session: "s1", folder: work.path, from: usual, to: extra) == .shared)
    }

    @Test func anUnlinkedFolderGetsACopyWithItsToolResults() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let usual = root.appendingPathComponent("usual"), extra = root.appendingPathComponent("extra")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = AgentCarry.claudeFile(home: usual, folder: work.path, session: "s2")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: file)
        let results = file.deletingPathExtension().appendingPathComponent("tool-results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try Data("long".utf8).write(to: results.appendingPathComponent("a.txt"))
        #expect(AgentCarry.ensure(cli: "claude", session: "s2", folder: work.path, from: usual, to: extra) == .copied)
        let there = AgentCarry.claudeFile(home: extra, folder: work.path, session: "s2")
        #expect(try String(contentsOf: there, encoding: .utf8) == "{\"type\":\"user\"}\n")
        #expect(FileManager.default.fileExists(atPath: there.deletingPathExtension().appendingPathComponent("tool-results/a.txt").path))
        // Again: already there, nothing written.
        #expect(AgentCarry.ensure(cli: "claude", session: "s2", folder: work.path, from: usual, to: extra) == .present)
    }

    @Test func aLongerTranscriptReplacesAnOlderCopy() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), work = root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let old = AgentCarry.claudeFile(home: b, folder: work.path, session: "s")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: old)
        let new = AgentCarry.claudeFile(home: a, folder: work.path, session: "s")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n2\n3\n".utf8).write(to: new)
        #expect(AgentCarry.ensure(cli: "claude", session: "s", folder: work.path, from: a, to: b) == .copied)
        #expect(try String(contentsOf: old, encoding: .utf8) == "1\n2\n3\n")
    }

    @Test func noTranscriptIsSaid() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentCarry.ensure(cli: "claude", session: "none", folder: root.path, from: root.appendingPathComponent("a"), to: root.appendingPathComponent("b")) == .missing)
        #expect(AgentCarry.ensure(cli: "codex", session: "none", folder: root.path, from: root.appendingPathComponent("a"), to: root.appendingPathComponent("b")) == .missing)
    }

    @Test func codexRolloutsKeepTheirDayFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let usual = root.appendingPathComponent("usual"), extra = root.appendingPathComponent("extra")
        let day = usual.appendingPathComponent("sessions/2026/10/04")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let id = "01a0fa90-22c1-7431-b7cc-fa67363bf297"
        try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: day.appendingPathComponent("rollout-2026-10-04T20-02-25-\(id).jsonl"))
        #expect(AgentCarry.codexFile(home: usual, thread: id) != nil)
        #expect(AgentCarry.ensure(cli: "codex", session: id, folder: "/", from: usual, to: extra) == .copied)
        let there = extra.appendingPathComponent("sessions/2026/10/04/rollout-2026-10-04T20-02-25-\(id).jsonl")
        #expect(FileManager.default.fileExists(atPath: there.path))
        #expect(AgentCarry.codexFile(home: extra, thread: id) != nil)
    }

    @Test func codexWithLinkedSessionsIsShared() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let usual = root.appendingPathComponent("usual"), extra = root.appendingPathComponent("extra")
        let day = usual.appendingPathComponent("sessions/2026/10/04")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: day.appendingPathComponent("rollout-2026-10-04T01-00-00-t9.jsonl"))
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: extra.appendingPathComponent("sessions"), withDestinationURL: usual.appendingPathComponent("sessions"))
        #expect(AgentCarry.ensure(cli: "codex", session: "t9", folder: "/", from: usual, to: extra) == .shared)
    }

    @Test func anAccountsHomeIsItsOwnFolderOrTheUsualOne() {
        let user = URL(fileURLWithPath: "/Users/me")
        #expect(AgentCarry.home(nil, cli: "claude", user: user).path == "/Users/me/.claude")
        #expect(AgentCarry.home(nil, cli: "codex", user: user).path == "/Users/me/.codex")
        let extra = PlanAccount(id: "claude.x", cli: "claude", home: "/tmp/plans/claude.x")
        #expect(AgentCarry.home(extra, cli: "claude", user: user).path == "/tmp/plans/claude.x")
    }
}
