import Foundation
import Testing
@testable import Fast

@MainActor
struct GeminiSelectionTests {
    @Test func catalogOffersOnlyLevelsAcceptedByTheInstalledGeminiCLI() {
        let rows = GeminiModels.rows("gemini-3.8-flash-high  Gemini Flash High\ngemini-3.8-flash-low  Gemini Flash Low")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.efforts == ["low", "medium", "high"] })
    }

    @Test(arguments: ["xhigh", "max", "future-effort"])
    func unsupportedSavedEffortFailsBeforeCreatingAProfile(effort: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsupported-gemini-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = GeminiRunnerTests.config(root: root, model: "gemini-3.8-flash-high")
        config.effort = effort
        #expect(throws: GeminiStream.Failure.self) { try config.prepare() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func explicitEffortKeepsTheSelectedFamilyWithoutContradictoryCLIFlags() {
        // agy 1.4.4 init: base+medium and pinned-high+high accepted;
        // pinned-high+medium rejected. The selected effort must survive.
        let cases: [(String?, String?, String?)] = [
            ("gemini-3.8-flash-high", "medium", "gemini-3.8-flash"),
            ("gemini-3.8-flash-medium", "high", "gemini-3.8-flash"),
            ("gemini-3.8-flash-high", "high", "gemini-3.8-flash-high"),
            ("gemini-3.8-flash-high", nil, "gemini-3.8-flash-high"),
            ("gemini-3.8-flash", "medium", "gemini-3.8-flash"),
            (nil, "medium", nil),
            ("gemini-3.8-flash-preview", "high", "gemini-3.8-flash-preview"),
            ("gemini-3.8-flash-high", "future-effort", "gemini-3.8-flash-high"),
        ]
        for (selected, effort, launched) in cases {
            var config = GeminiRunnerTests.config(root: FileManager.default.temporaryDirectory, model: selected)
            config.effort = effort
            let arguments = config.arguments
            let modelFlag = arguments.firstIndex(of: "--model").map { arguments[$0 + 1] }
            let effortFlag = arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] }
            #expect(modelFlag == launched)
            #expect(effortFlag == effort)
            #expect(config.model == selected, "The stored user choice is unchanged")
        }
    }

    @Test func theProcessValidatesTheNormalizedInitModelExactly() async throws {
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("login/Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        try #"""
        #!/usr/bin/python3
        import json, sys
        def emit(event): print(json.dumps(event), flush=True)
        emit({'event':'init','conversation_id':'G1','init':{'model':'gemini-3.8-flash','tools':[],'permission_mode':'request-review'}})
        request=json.loads(sys.stdin.readline())
        emit({'event':'result','result':{'conversation_id':'G1','status':'SUCCESS','response':'MODEL_OK'}})
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var events: [GeminiStream.Event] = []
        var exited = false
        let runner = GeminiRunner { events.append($0) }
        runner.exited = { _ in exited = true }
        defer { runner.stop() }
        var config = GeminiRunner.Configuration(binary: binary.path, profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent("workspace"), model: "gemini-3.8-flash-high", conversation: nil,
            command: "", mcpArgs: nil, environment: ["HOME": root.appendingPathComponent("login").path, "PATH": "/usr/bin:/bin"])
        config.effort = "medium"
        try runner.start(config, permit: consent.consent.permit("gemini"))
        try runner.send("Reply")
        runner.close()
        try await GeminiRunnerTests.until { exited }
        #expect(events.contains { if case .result(let result) = $0 { return result.succeeded }; return false })
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
    }
}
