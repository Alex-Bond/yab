import Foundation
import Testing
@testable import Fast

/// These same public-behavior checks compile on the unmodified base commit.
@MainActor
struct AgentLaunchRegressionTests {
    @Test func nvmFallbackExistsWithoutTheShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.15.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentCopies.places("claude", home: root.path).contains(bin.appendingPathComponent("claude").path))
    }

    @Test func npmCLICanStartItsSiblingNodeWithAGuiPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.15.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = bin.appendingPathComponent("claude"), node = bin.appendingPathComponent("node")
        try "#!/usr/bin/env node\nprintf 'sibling-runtime'\n".write(to: cli, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(to: node, atomically: true, encoding: .utf8)
        for file in [cli, node] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        let ran = await Shell.timed(cli.path, [], env: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        #expect(ran.code == 0 && ran.output == "sibling-runtime")
    }

    @Test func geminiProfileUsesTheExistingLoginKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try GeminiRunnerTests.config(root: root, inherited: ["HOME": root.path, "PATH": "/usr/bin:/bin"]).prepare()
        let link = URL(fileURLWithPath: try #require(prepared.env["HOME"])).appendingPathComponent("Library/Keychains")
        #expect(link.resolvingSymlinksInPath().path == root.appendingPathComponent("Library/Keychains").resolvingSymlinksInPath().path)
    }

    @Test func earlyGeminiExitShowsItsStderr() throws {
        var stream = GeminiStream()
        _ = try stream.prompt("Hello")
        stream.diagnostic("Error: fixture CLI cannot start\n")
        guard case .failed(let message) = stream.end(code: 3).first else { Issue.record("No failure"); return }
        #expect(message.contains("fixture CLI cannot start"))
        #expect(message.contains("exit code 3"))
    }

    @Test func aDeniedBuiltInCanRecoverThroughYab() throws {
        func line(_ object: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10); return data
        }
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read this tab")
        _ = stream.receive(try line(["event": "init", "conversation_id": "G1", "init": ["tools": [], "permission_mode": "request-review"]]))
        _ = stream.receive(try line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": "read_url_content",
            "tool_info": ["error": ["type": "permission_denied", "message": "Yab gives Gemini only its own browser tools."]]]]))
        #expect(!stream.broken)
        let events = stream.receive(try line(["event": "result", "result": ["conversation_id": "G1", "status": "SUCCESS", "response": "Used Yab instead"]]))
        #expect(events.contains { if case .result(let result) = $0 { return result.succeeded }; return false })
    }
}
