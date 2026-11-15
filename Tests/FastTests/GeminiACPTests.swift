import Foundation
import Darwin
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct GeminiACPTests {
    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gemini acp " + UUID().uuidString)
        let consent = IsolatedProviderConsent("gemini")
        let client = GeminiACP()
        var binary: URL { root.appendingPathComponent("agy") }
        var page: URL { root.appendingPathComponent("page") }
        init(_ mode: String) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("evals/gemini-acp/fake_agy.py")
            try FileManager.default.copyItem(at: source, to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let browser = root.appendingPathComponent("browser")
            try GeminiLogin.browserScript.write(to: browser, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browser.path)
        }
        func start(switching: Bool = false, limit: TimeInterval = 3) throws {
            try client.start(binary: binary.path, environment: ["PATH": "/usr/bin:/bin", "HOME": root.path,
                "BROWSER": root.appendingPathComponent("browser").path, "YAB_GEMINI_PAGE": page.path],
                cwd: root, page: page, switching: switching, permit: try #require(consent.consent.permit("gemini")), openingLimit: limit)
        }
        func close() {
            client.stop(); consent.close()
            if let text = try? String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8),
               let pid = Int32(text), pid > 1 { kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(at: root)
        }
        var calls: [[String: Any]] {
            let text = (try? String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        var methods: [String] { calls.compactMap { $0["method"] as? String } }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @Test func launcherURLAndPendingConsentNeverCountAsSuccess() async throws {
        let fixture = try Fixture("pending"); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.url != nil })
        #expect(fixture.client.state == .authenticating)
        #expect(fixture.methods == ["initialize", "authenticate"])
        let request = try #require(fixture.calls.first { $0["method"] as? String == "initialize" })
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? Int == 1)
        let capabilities = try #require(params["clientCapabilities"] as? [String: Any])
        #expect((capabilities["fs"] as? [String: Bool]) == ["readTextFile": false, "writeTextFile": false])
        #expect(fixture.client.url?.query?.contains("state=fixture%2Bstate") == true)
    }

    @Test(arguments: ["success", "success-exit", "fragmented", "server-request"])
    func successRequiresTheMatchingAuthenticateReply(mode: String) async throws {
        let fixture = try Fixture(mode); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.state == .authenticated })
        #expect(fixture.client.url != nil)
        // Exit may arrive after the complete response; it cannot reverse it.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.client.state == .authenticated)
    }

    @Test func anUnrelatedRPCReplyCannotCompleteAuthentication() async throws {
        let fixture = try Fixture("misleading-success"); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.url != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.client.state == .authenticating)
    }

    @Test func aSuccessfulExistingLoginNeedsNoBrowserChallenge() async throws {
        let fixture = try Fixture("already-signed-in"); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.state == .authenticated })
        #expect(fixture.client.url == nil)
    }

    @Test func switchLogsOutBeforeAuthenticatingAndDoesNotUseTheTUI() async throws {
        let fixture = try Fixture("success"); defer { fixture.close() }
        try Data().write(to: fixture.root.appendingPathComponent("completed"))
        try fixture.start(switching: true)
        #expect(await until { fixture.client.state == .authenticated })
        #expect(fixture.methods == ["initialize", "logout", "authenticate"])
        #expect(fixture.calls.compactMap { $0["argv"] as? [String] } == [["acp"]])
    }

    @Test(arguments: ["error", "logout-error", "early-exit", "exit-with-child", "no-url", "long-diagnostic", "no-logout"])
    func failureEndsTheWaitWithoutFallingBack(mode: String) async throws {
        let fixture = try Fixture(mode); defer { fixture.close() }
        try fixture.start(switching: ["logout-error", "no-logout"].contains(mode), limit: 0.8)
        #expect(await until { if case .failed = fixture.client.state { return true }; return false })
        if case .failed(let message) = fixture.client.state { #expect(message.lowercased().contains("try again.")) }
        if ["logout-error", "no-logout"].contains(mode) { #expect(!fixture.methods.contains("authenticate")) }
        #expect(fixture.client.state != .unsupported)
        #expect(fixture.calls.compactMap { $0["argv"] as? [String] } == [["acp"]])
        #expect(FeedbackDiagnostics.shared.events().contains { $0.kind == .geminiRequestFailed && $0.reason?.hasPrefix("signin.") == true })
        if mode == "error" { #expect(fixture.client.stderr.contains("Authentication refused")) }
        if mode == "long-diagnostic" { #expect(!fixture.client.stderr.contains("SENSITIVE_LONG_TOKEN")) }
    }

    @Test(arguments: ["unsupported", "initialize-error", "initialize-null", "initialize-no-newline"])
    func onlyInitializeFailureAllowsOldCLIFallback(mode: String) async throws {
        let fixture = try Fixture(mode); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.state == .unsupported })
        #expect(!fixture.methods.contains("authenticate"))
    }

    @Test func cancelIgnoresTheLateCallback() async throws {
        let fixture = try Fixture("controlled"); defer { fixture.close() }
        try fixture.start()
        #expect(await until { fixture.client.url != nil })
        fixture.client.stop()
        try Data().write(to: fixture.root.appendingPathComponent("complete"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fixture.client.state == .stopped)
    }

    @Test func confirmationReportsThisProbeRatherThanCachedReadiness() async throws {
        let fixture = try Fixture("success"); defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Library/Keychains"), withIntermediateDirectories: true)
        let account = GeminiAccount(binary: fixture.binary.path)
        account.pretend(binary: fixture.binary.path, signedIn: true, models: "gemini-fixture Gemini Fixture")
        var proof: Bool?
        let find: (Bool) async -> Shell.Found = { _ in
            Shell.Found(gemini: fixture.binary.path, env: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"])
        }
        let permit = try #require(fixture.consent.consent.permit("gemini"))
        await account.look(fresh: true, permit: permit, find: find, profile: fixture.root.appendingPathComponent("Yab Gemini"),
                           confirmed: { proof = $0 })
        #expect(proof == false && !account.ready)
        try Data().write(to: fixture.root.appendingPathComponent("completed"))
        await account.look(fresh: true, permit: permit, find: find, profile: fixture.root.appendingPathComponent("Yab Gemini"),
                           confirmed: { proof = $0 })
        #expect(proof == true && account.ready)
    }

    @Test func feedbackIncludesOnlyRecentRedactedSignInLogsAndHonorsItsToggle() throws {
        let log = GeminiSignInLog.shared
        log.begin()
        defer { log.begin() }
        log.append("keychain locked name@example.com https://accounts.google.com/auth?code=private access_token=secret")
        let site = try #require(URL(string: "https://example.test"))
        var draft = FeedbackSheet.Draft()
        draft.message = "Cannot connect Gemini"
        let request = FeedbackSheet.request(draft, site: site, diagnostics: "{}")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("gemini-signin-diagnostics.txt") && body.contains("keychain locked"))
        #expect(!body.contains("secret") && !body.contains("example.com") && !body.contains("code=private"))
        draft.includeDiagnostics = false
        let without = String(decoding: try #require(FeedbackSheet.request(draft, site: site, diagnostics: "{}").httpBody), as: UTF8.self)
        #expect(!without.contains("keychain locked") && !without.contains("gemini-signin-diagnostics.txt"))
        var now = Date()
        let expiring = GeminiSignInLog(clock: { now })
        expiring.append("failure")
        #expect(expiring.recent != nil)
        now = now.addingTimeInterval(301)
        #expect(expiring.recent == nil)
    }

    @Test func diagnosticsOmitOAuthSecretsAndEmailAddresses() {
        let text = GeminiACP.redacted("keychain error for name@example.com https://accounts.google.com/auth?state=secret access_token=secret bearer hidden")
        #expect(text.contains("keychain error"))
        #expect(!text.contains("secret") && !text.contains("example.com") && !text.contains("hidden"))
    }
}
