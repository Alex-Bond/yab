import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct GeminiTerminalDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_GEMINI_ONCE_FIXTURE"] == "1"))
    func aHelperNeverReturnsAnEarlyAnswerAfterALateProcessFailure() async throws {
        let out = try #require(ProcessInfo.processInfo.environment["YAB_FARM_OUT"])
        let profile = GeminiSupport.profile.standardizedFileURL
        try #require(profile.path.hasPrefix(URL(fileURLWithPath: out).standardizedFileURL.path + "/"), "Only a private farm fixture profile may run this helper check")
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let fixture = profile.deletingLastPathComponent().appendingPathComponent("once-fixture")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("login/Library/Keychains"), withIntermediateDirectories: true)
        let binary = fixture.appendingPathComponent("agy-fixture")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, sys, time
        def emit(event): print(json.dumps(event), flush=True)
        emit({'event':'init','conversation_id':'G1','init':{'tools':[],'permission_mode':'request-review'}})
        request=json.loads(sys.stdin.readline())
        emit({'event':'result','result':{'conversation_id':'G1','status':'SUCCESS','response':'EARLY_ANSWER'}})
        pathlib.Path(__file__).with_suffix('.result').write_text('result emitted')
        time.sleep(.15)
        print('headless mode cannot prompt for approval, auto-denied', file=sys.stderr, flush=True)
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let answer = await GeminiRunner.once(binary: binary.path, message: "Reply", environment: [
            "HOME": fixture.appendingPathComponent("login").path, "PATH": "/usr/bin:/bin"],
            room: "late-stderr", limit: 3, permit: consent.consent.permit("gemini"))
        #expect(FileManager.default.fileExists(atPath: binary.appendingPathExtension("result").path))
        #expect(answer.isEmpty)
    }

    @Test func aDenialAfterTheTerminalResultStillFailsTheTurn() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read the page")
        _ = try GeminiRunnerTests.initialize(&stream)
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == true)
        stream.diagnostic("headless mode cannot prompt for approval, auto-")
        stream.diagnostic("denied\n")
        let ending = stream.end(code: 0)
        #expect(ending.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func aRecoveredNativeDenialDoesNotPoisonLaterBenignDiagnostics() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read the page through Yab")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = stream.receive(try GeminiRunnerTests.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "DONE", "step_type": "tool", "tool_name": "view_file", "tool_info": ["error": ["type": "permission_denied", "message": "Yab gives Gemini only its own browser tools."]]]]))
        stream.diagnostic("view_file auto-denied by Yab's pre-tool hook.\n")
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == true)
        stream.diagnostic("CLI shutdown complete.\n")
        #expect(stream.end(code: 0).isEmpty)
    }

    @Test func aConfirmedNativeDenialMayBeReportedAfterTheResult() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read using Yab")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = stream.receive(try GeminiRunnerTests.line(["event": "step_update", "step_update": ["conversation_id": "G1", "step_index": 1,
            "state": "ERROR", "step_type": "tool", "tool_name": "list_resources", "tool_info": ["error": ["type": "TOOL_ERROR", "message": "Yab gives Gemini only its own browser tools."]]]]))
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == true)
        stream.diagnostic("list_resources auto-denied by Yab's pre-tool hook.\n")
        #expect(stream.end(code: 0).isEmpty)
    }

    @Test(arguments: [false, true])
    func theRealProcessTransportClassifiesLateDenials(recoveredNative: Bool) async throws {
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-late-stderr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("login/Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, sys, time
        def emit(event): print(json.dumps(event), flush=True)
        emit({'event':'init','conversation_id':'G1','init':{'tools':[],'permission_mode':'request-review'}})
        request = json.loads(sys.stdin.readline())
        RECOVERY_EVENTS
        emit({'event':'result','result':{'conversation_id':'G1','status':'SUCCESS','response':'PROVISIONAL_OK'}})
        time.sleep(.15)
        print('LATE_DIAGNOSTIC', file=sys.stderr, flush=True)
        """#
        let recovery = #"""
        emit({'event':'step_update','step_update':{'conversation_id':'G1','step_index':1,'state':'ERROR','step_type':'tool','tool_name':'list_resources','tool_info':{'error':{'type':'TOOL_ERROR','message':'Yab gives Gemini only its own browser tools.'}}}})
        emit({'event':'step_update','step_update':{'conversation_id':'G1','step_index':2,'state':'DONE','step_type':'tool','tool_name':'mcp_yab-browser_open','tool_info':{'output':'Page opened'}}})
        """#
        try script.replacingOccurrences(of: "RECOVERY_EVENTS", with: recoveredNative ? recovery : "")
            .replacingOccurrences(of: "LATE_DIAGNOSTIC", with: recoveredNative ? "list_resources auto-denied by Yab pre-tool hook" : "headless mode cannot prompt for approval, auto-denied")
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var events: [GeminiStream.Event] = []
        var exit: Int32?
        let runner = GeminiRunner { events.append($0) }
        runner.exited = { exit = $0 }
        defer { runner.stop() }
        let config = GeminiRunner.Configuration(binary: binary.path, profile: root.appendingPathComponent("profile"),
            workspace: root.appendingPathComponent("workspace"), model: nil, conversation: nil, command: "/fixture-yab",
            mcpArgs: recoveredNative ? ["mcp", "--socket", "/fixture", "--session", "fixture", "--inner"] : nil,
            environment: ["HOME": root.appendingPathComponent("login").path, "PATH": "/usr/bin:/bin"])
        try runner.start(config, permit: consent.consent.permit("gemini"))
        try runner.send("Reply")
        runner.close()
        try await GeminiRunnerTests.until { exit != nil }
        #expect(events.contains { if case .result(let result) = $0 { return result.succeeded }; return false }, "Fixture must actually deliver the early result")
        let failed = events.contains { if case .failed = $0 { return true }; return false }
        #expect(failed == !recoveredNative, "Only a confirmed native hook denial may recover; a real late denial must fail")
    }
}
