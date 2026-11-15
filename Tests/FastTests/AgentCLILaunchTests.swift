import Foundation
import Testing
@testable import Fast

/// GUI launches have no terminal PATH. Every fixture lives in a private HOME;
/// no provider, credentials or configuration from the test Mac is used.
@MainActor
struct AgentCLILaunchTests {
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        return root
    }

    private func executable(_ path: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    @Test(arguments: [".nvm/versions/node/v22.15.0/bin", ".npm-global/bin", ".local/bin", ".bun/bin", ".volta/bin", ".asdf/shims", ".local/share/mise/shims"])
    func fallbackFindsTerminalInstalls(folder: String) throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["claude", "agy"] {
            let binary = root.appendingPathComponent(folder + "/" + name)
            try executable(binary, "#!/bin/sh\nexit 0\n")
            #expect(AgentCopies.places(name, home: root.path).contains(binary.path))
        }
    }

    @Test func npmPrefixFromUserConfig() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        try "prefix=${HOME}/custom npm\n".write(to: root.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("custom npm/bin/claude")
        try executable(binary, "#!/bin/sh\nexit 0\n")
        #expect(AgentCopies.places("claude", home: root.path).contains(binary.path))
    }

    @Test func selectedNvmCLIGetsItsOwnNodeEvenWithAnotherNodeOnPath() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.15.0/bin")
        let binary = bin.appendingPathComponent("claude")
        try executable(binary, "#!/usr/bin/env node\nprintf 'selected-node'\n")
        try executable(bin.appendingPathComponent("node"), "#!/bin/sh\nexec /bin/sh \"$@\"\n")
        let wrong = root.appendingPathComponent("wrong")
        try executable(wrong.appendingPathComponent("node"), "#!/bin/sh\nexit 97\n")
        let ran = await Shell.timed(binary.path, [], env: ["HOME": root.path, "PATH": wrong.path + ":/usr/bin:/bin"])
        #expect(ran.code == 0)
        #expect(ran.output == "selected-node")
    }

    @Test func geminiProfileRetainsLoginKeychainAndSelectedRuntime() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.15.0/bin")
        let binary = bin.appendingPathComponent("agy")
        try executable(binary, "#!/usr/bin/env node\nprintf 'gemini-node'\n")
        try executable(bin.appendingPathComponent("node"), "#!/bin/sh\nexec /bin/sh \"$@\"\n")
        let config = GeminiRunnerTests.config(root: root, binary: binary.path, inherited: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        let prepared = try config.prepare()
        let linked = URL(fileURLWithPath: try #require(prepared.env["HOME"])).appendingPathComponent("Library/Keychains")
        #expect(linked.resolvingSymlinksInPath().path == root.appendingPathComponent("Library/Keychains").resolvingSymlinksInPath().path)
        let child = Process(), output = Pipe()
        child.executableURL = binary; child.environment = prepared.env
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "gemini-node")
    }

    @Test func geminiExitShowsProcessCodeAndDiagnostic() throws {
        var stream = GeminiStream()
        _ = try stream.prompt("Hello")
        stream.diagnostic("Error: node is unavailable\n")
        guard case .failed(let message) = stream.end(code: 3).first else { Issue.record("Missing visible error"); return }
        #expect(message.contains("exit code 3"))
        #expect(message.contains("node is unavailable"))
        #expect(!message.contains("transport close"))
        #expect(!ChatProblem(message, agent: "Gemini").diagnostics.isEmpty)
    }

    @Test func claudeLaunchErrorUsesExistingFailureCardAndKeepsWhatWasTried() {
        let message = AgentCopies.launchFailure("Claude", binary: "/fixture/.nvm/bin/claude",
            env: ["PATH": "/fixture/.nvm/bin:/usr/bin:/bin", "SECRET": "must-not-appear"],
            reason: "stopped before returning an answer (exit code 0).")
        let problem = ChatProblem(message, agent: "Claude")
        #expect(problem.kind == .stopped)
        #expect(problem.title == "Claude stopped before it finished.")
        #expect(problem.detail.contains("stopped before returning an answer"))
        #expect(problem.diagnostics.contains("Tried: /fixture/.nvm/bin/claude"))
        #expect(problem.diagnostics.contains("PATH: /fixture/.nvm/bin:/usr/bin:/bin"))
        #expect(!problem.diagnostics.contains("must-not-appear"))
    }

    @Test func signInProbeKeepsStartupErrorsSeparateFromJSON() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("claude")
        try executable(binary, "#!/bin/sh\nprintf '{\"loggedIn\":true}'\nprintf 'fixture diagnostic' >&2\nexit 3\n")
        let ran = await Shell.timed(binary.path, ["auth", "status"], env: ["HOME": root.path, "PATH": "/usr/bin:/bin"], captureErrors: true)
        #expect(ran.code == 3)
        #expect(ran.output == "{\"loggedIn\":true}")
        #expect(ran.diagnostic == "fixture diagnostic")
        let missing = await Shell.timed(root.appendingPathComponent("missing").path, [], env: [:], captureErrors: true)
        #expect(missing.code == -1 && !missing.diagnostic.isEmpty)
    }
}
