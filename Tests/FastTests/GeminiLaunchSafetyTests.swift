import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct GeminiLaunchSafetyTests {
    @Test func keychainLinkAndExistingProfilePathsSurviveTheMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let login = root.appendingPathComponent("login-home"), profile = root.appendingPathComponent("Yab Gemini")
        try FileManager.default.createDirectory(at: login.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = GeminiSupport.environment(["HOME": login.path, "PATH": "/usr/bin:/bin",
            "ANTIGRAVITY_GEMINI_DIR": "/foreign", "GEMINI_API_KEY": "never-inherit"], profile: profile)
        try GeminiSupport.prepareKeychain(profile: profile, loginHome: login.path)
        let linked = URL(fileURLWithPath: try #require(env["HOME"])).appendingPathComponent("Library/Keychains")
        #expect(linked.resolvingSymlinksInPath().path == login.appendingPathComponent("Library/Keychains").resolvingSymlinksInPath().path)
        #expect(env["ANTIGRAVITY_GEMINI_DIR"] == profile.appendingPathComponent("home/.gemini").path)
        #expect(env["ANTIGRAVITY_APP_DATA_DIR"] == profile.appendingPathComponent("app-data").path)
        #expect(env["GEMINI_API_KEY"] == nil)
        let script = GeminiAccount.signInScript(binary: "/fixture/nvm/bin/agy", profile: profile)
        #expect(script.contains("readlink"))
        #expect(script.contains("export PATH='/fixture/nvm/bin:"))
        #expect(script.contains("cd \"$ANTIGRAVITY_GEMINI_DIR\""))
    }

    @Test func anExistingKeychainIsNeverReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let login = root.appendingPathComponent("login"), profile = root.appendingPathComponent("profile")
        let old = profile.appendingPathComponent("home/Library/Keychains")
        for folder in [login.appendingPathComponent("Library/Keychains"), old] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = old.appendingPathComponent("keep.txt")
        try "preserve".write(to: sentinel, atomically: true, encoding: .utf8)
        #expect(throws: GeminiStream.Failure.self) { try GeminiSupport.prepareKeychain(profile: profile, loginHome: login.path) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test func staleCatalogCannotProveGoogleAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("agy")
        let body = """
        #!/bin/sh
        if [ "$1" = models ]; then
          printf 'gemini-fixture Gemini Fixture\\n'; exit 0
        fi
        printf 'Google sign-in was canceled; credentials unavailable.\\n' >&2
        exit 3
        """
        try body.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let consent = IsolatedProviderConsent("gemini")
        defer { consent.close() }
        let account = GeminiAccount(binary: binary.path)
        account.pretend(binary: binary.path, signedIn: true, models: "gemini-fixture", waiting: .signingIn)
        await account.look(fresh: true, permit: consent.consent.permit("gemini"), find: { _ in
            Shell.Found(gemini: binary.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        }, profile: root.appendingPathComponent("profile"))
        #expect(account.models.contains { $0.model == "gemini-fixture" })
        #expect(account.signedIn == false && !account.ready)
        #expect(account.lastSaid?.contains("canceled") == true)
        #expect(account.waiting == nil && account.trouble?.contains("canceled") == true)
    }

    @Test func canceledSignInClearsStaleSuccessAndKeepsFailure() {
        let account = GeminiAccount(binary: "/fixture/agy")
        account.pretend(binary: "/fixture/agy", signedIn: true, models: "gemini-fixture", waiting: .signingIn)
        account.cancel()
        #expect(account.waiting == nil && account.signedIn == false)
        #expect(account.trouble?.contains("canceled") == true)
    }

    @Test func quotaCheckRejectsEmptyTimeoutAndKeychainCancellation() {
        #expect(GeminiAccount.authenticated(Shell.Ran(code: 0, output: "Gemini quota: 90% remaining", late: false)))
        for ran in [Shell.Ran(code: 0, output: "", late: false),
                    Shell.Ran(code: 3, output: "cached models", late: false),
                    Shell.Ran(code: 0, output: "cached quota", late: true),
                    Shell.Ran(code: 0, output: "cached quota", late: false, diagnostic: "Keychain access canceled"),
                    Shell.Ran(code: 0, output: "Error: authentication required", late: false)] {
            #expect(!GeminiAccount.authenticated(ran))
        }
    }

    @Test(arguments: ["view_file", "read_url_content", "write_to_file"])
    func deniedNativeToolDoesNotKillTheBrowserRun(tool: String) throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read this page through Yab")
        _ = try GeminiRunnerTests.initialize(&stream)
        func step(_ state: String, info: [String: Any]) throws -> Data {
            try GeminiRunnerTests.line(["event": "step_update", "step_update": ["conversation_id": "G1",
                "step_index": 1, "state": state, "step_type": "tool", "tool_name": tool, "tool_info": info]])
        }
        _ = stream.receive(try step("ACTIVE", info: [:]))
        #expect(!stream.broken)
        stream.diagnostic("Tool \(tool) auto-denied by Yab's pre-tool hook.")
        _ = stream.receive(try step("DONE", info: ["error": ["type": "permission_denied", "message": "Yab gives Gemini only its own browser tools."]]))
        #expect(!stream.broken)
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == true)
        #expect(stream.end(code: 0).isEmpty)
    }

    @Test func nativeRecoveryCannotHideAnotherPermissionFailure() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read this page through Yab")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = stream.receive(try GeminiRunnerTests.line(["event": "step_update", "step_update": ["conversation_id": "G1",
            "step_index": 1, "state": "DONE", "step_type": "tool", "tool_name": "view_file",
            "tool_info": ["error": ["type": "permission_denied", "message": "Yab gives Gemini only its own browser tools."]]]]))
        stream.diagnostic("view_file auto-denied\nYab MCP tool auto-denied\n")
        #expect(try GeminiRunnerTests.result(&stream)?.succeeded == false)
    }

    @Test func unconfirmedNativeCallStillFailsClosed() throws {
        var stream = GeminiStream(yabTools: true)
        _ = try stream.prompt("Read this page")
        _ = try GeminiRunnerTests.initialize(&stream)
        _ = stream.receive(try GeminiRunnerTests.line(["event": "step_update", "step_update": ["conversation_id": "G1",
            "step_index": 1, "state": "DONE", "step_type": "tool", "tool_name": "view_file", "tool_info": ["output": "secret"]]]))
        #expect(stream.broken)
    }
}
